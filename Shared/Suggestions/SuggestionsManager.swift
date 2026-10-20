//
//  SuggestionsManager.swift
//  NetNewsWire
//
//  Created by Simon on 10/19/26.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Articles
import Account
import RSCore
import Suggestions

extension Notification.Name {
	/// userInfo has `articleIDs` when only some scores changed. With no userInfo, every score may have changed.
	static let suggestionScoresDidChange = Notification.Name("SuggestionScoresDidChangeNotification")
	static let suggestionsSettingDidChange = Notification.Name("SuggestionsSettingDidChangeNotification")
	static let suggestionsSyncSettingDidChange = Notification.Name("SuggestionsSyncSettingDidChangeNotification")
}

/// Records what the person reads and provides “likely to open” scores for the timeline.
///
/// Platform code calls the `article…` methods from its UI hooks and asks for
/// `displayScore(for:)` when configuring cells.
@MainActor final class SuggestionsManager {

	static let shared = SuggestionsManager()

	struct UserInfoKey {
		static let articleIDs = "articleIDs"
	}

	/// Scores below this aren’t shown. Training balances opened and skipped articles,
	/// so 0.5 means “about average”.
	static let displayThreshold: Float = 0.65

	/// Longer stretches are capped, since the article was probably left on screen.
	private static let maximumDwellSegment: TimeInterval = 10 * 60

	/// Pushes bring other devices’ changes sooner. This catches anything missed and uploads this device’s.
	private static let syncInterval: TimeInterval = 15 * 60

	private let engine: SuggestionEngine
	private var isReady = false
	private var scores = [String: Float]()
	private var pendingScoreInputs = [String: SuggestionInput]()
	private var scoringTask: Task<Void, Never>?
	/// Incremented when the model changes, so scores from the old model are dropped.
	private var scoreGeneration = 0
	private var impressionArticleIDs = Set<String>()
	private var pendingImpressions = [SuggestionInput]()
	private var impressionsTask: Task<Void, Never>?

	private var currentArticleID: String?
	private var dwellStartDate: Date?

	private var cloudSync: SuggestionsCloudSync?
	private var syncTimer: Timer?

	private var isEnabled: Bool {
		AppDefaults.shared.showSuggestions
	}

	private var isSyncEnabled: Bool {
		isEnabled && AppDefaults.shared.syncSuggestionsWithiCloud
	}

	private init() {
		let databasePath = AppConfig.dataFolder.appendingPathComponent("Suggestions.db").path
		let modelPath = AppConfig.dataFolder.appendingPathComponent("Suggestions.model").path
		engine = SuggestionEngine(databasePath: databasePath, modelPath: modelPath)

		NotificationCenter.default.addObserver(self, selector: #selector(statusesDidChange(_:)), name: .StatusesDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(settingDidChange(_:)), name: .suggestionsSettingDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(syncSettingDidChange(_:)), name: .suggestionsSyncSettingDidChange, object: nil)

		#if os(macOS)
		NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive(_:)), name: NSApplication.willResignActiveNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
		#else
		NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive(_:)), name: UIApplication.willResignActiveNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
		#endif
	}

	/// Call at launch: prunes old history, retrains on what’s left, and starts syncing.
	func start() {
		Task {
			await engine.prune()
			await engine.retrain()
			await modelDidChange()
			updateCloudSync()
		}
	}

	/// Pass every remote notification; ones for other zones are ignored.
	func receiveRemoteNotification(userInfo: [AnyHashable: Any]) async {
		await cloudSync?.receiveRemoteNotification(userInfo: userInfo)
	}

	// MARK: - Scores

	/// The probability that the article will be opened, or 0 if it shouldn’t be shown as suggested.
	///
	/// Scores are computed asynchronously. When one isn’t ready yet this returns 0
	/// and posts `.suggestionScoresDidChange` once it is.
	func displayScore(for article: Article) -> Float {
		guard isEnabled, isReady else {
			return 0
		}

		if let score = scores[article.articleID] {
			return score >= Self.displayThreshold ? score : 0
		}

		pendingScoreInputs[article.articleID] = Self.input(for: article)
		scheduleScoring()
		return 0
	}

	/// Splits articles using only scores already computed: those known to be suggested,
	/// and those not scored yet. For callers that can’t wait, such as a synchronous fetch.
	func cachedSuggestions(in articles: Set<Article>) -> (suggestedArticleIDs: Set<String>, unscored: Set<Article>) {
		guard isEnabled, isReady else {
			return ([], [])
		}

		var suggestedArticleIDs = Set<String>()
		var unscored = Set<Article>()
		for article in articles {
			if let score = scores[article.articleID] {
				if score >= Self.displayThreshold {
					suggestedArticleIDs.insert(article.articleID)
				}
			} else {
				unscored.insert(article)
			}
		}
		return (suggestedArticleIDs, unscored)
	}

	/// The IDs of the articles that score at or above the display threshold.
	/// Scores any article not already scored. Empty when suggestions are off or the model isn’t ready.
	func suggestedArticleIDs(in articles: Set<Article>) async -> Set<String> {
		guard isEnabled, isReady else {
			return []
		}

		let unscored = articles.filter { scores[$0.articleID] == nil }
		if !unscored.isEmpty {
			let generation = scoreGeneration
			let newScores = await engine.scores(for: unscored.map(Self.input(for:)))
			guard generation == scoreGeneration else {
				// The model changed. Callers refresh again on the resulting notification.
				return []
			}
			for article in unscored {
				scores[article.articleID] = newScores[article.articleID] ?? 0
			}
		}

		var suggestedArticleIDs = Set<String>()
		for article in articles {
			if let score = scores[article.articleID], score >= Self.displayThreshold {
				suggestedArticleIDs.insert(article.articleID)
			}
		}
		return suggestedArticleIDs
	}

	// MARK: - Recording

	/// Call when the article shown in the detail view changes. Pass nil when no single article is shown.
	func articleDidBecomeCurrent(_ article: Article?) {
		guard article?.articleID != currentArticleID else {
			return
		}

		endDwell()
		currentArticleID = nil

		guard isEnabled, let article else {
			return
		}

		currentArticleID = article.articleID
		dwellStartDate = Date()
		record(.open, article: article)
	}

	func articleOpenedInBrowser(_ article: Article) {
		guard isEnabled else {
			return
		}
		record(.browser, article: article)
	}

	/// Call when an article is shown in the timeline. Each article is logged once.
	func articleWasDisplayed(_ article: Article) {
		guard isEnabled, !impressionArticleIDs.contains(article.articleID) else {
			return
		}

		impressionArticleIDs.insert(article.articleID)
		pendingImpressions.append(Self.input(for: article))
		scheduleImpressions()
	}

	/// Deletes all reading history and the trained model. With sync on, also deletes it
	/// from iCloud, and other devices forget theirs the next time they sync.
	func reset() {
		currentArticleID = nil
		dwellStartDate = nil
		impressionArticleIDs.removeAll()
		pendingImpressions.removeAll()
		Task {
			if let cloudSync {
				await cloudSync.resetEverywhere()
			} else {
				await engine.reset()
			}
			await modelDidChange()
		}
	}

	// MARK: - Notifications

	@objc func statusesDidChange(_ note: Notification) {
		guard isEnabled,
			  let statusKey = note.userInfo?[Account.UserInfoKey.statusKey] as? ArticleStatus.Key,
			  statusKey == .starred,
			  let flag = note.userInfo?[Account.UserInfoKey.statusFlag] as? Bool,
			  let articleIDs = note.userInfo?[Account.UserInfoKey.articleIDs] as? Set<String>,
			  !articleIDs.isEmpty else {
			return
		}

		Task {
			if await engine.record(flag ? .star : .unstar, articleIDs: articleIDs) {
				await modelDidChange()
			}
		}
	}

	@objc func settingDidChange(_ note: Notification) {
		if !isEnabled {
			endDwell()
			currentArticleID = nil
		}
		postScoresDidChange(nil)
		updateCloudSync()
	}

	@objc func syncSettingDidChange(_ note: Notification) {
		updateCloudSync()
	}

	@objc func appWillResignActive(_ note: Notification) {
		endDwell()
		syncInBackground()
	}

	@objc func appDidBecomeActive(_ note: Notification) {
		if currentArticleID != nil {
			dwellStartDate = Date()
		}
		syncNow()
	}
}

private extension SuggestionsManager {

	// MARK: - iCloud

	/// Starts or stops syncing to match the settings. Turning sync off leaves the history in iCloud.
	func updateCloudSync() {
		// Tests run inside the app, which shouldn’t touch the person’s real iCloud data.
		guard isSyncEnabled, !Platform.isRunningUnitTests else {
			cloudSync = nil
			syncTimer?.invalidate()
			syncTimer = nil
			return
		}

		if cloudSync == nil {
			// The same container as the iCloud account. See CloudKitAccountDelegate.
			guard let organizationIdentifier = Bundle.main.object(forInfoDictionaryKey: "OrganizationIdentifier") as? String else {
				return
			}
			cloudSync = SuggestionsCloudSync(containerIdentifier: "iCloud.\(organizationIdentifier).NetNewsWire", engine: engine) { [weak self] in
				Task {
					await self?.modelDidChange()
				}
			}
		}

		if syncTimer == nil {
			syncTimer = Timer.scheduledTimer(withTimeInterval: Self.syncInterval, repeats: true) { _ in
				Task { @MainActor in
					SuggestionsManager.shared.syncNow()
				}
			}
		}
		syncNow()
	}

	func syncNow() {
		guard let cloudSync else {
			return
		}
		Task {
			await cloudSync.sync()
		}
	}

	/// On iOS, asks for time to finish uploading after the app leaves the foreground.
	func syncInBackground() {
		guard let cloudSync else {
			return
		}
		#if os(iOS)
		let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Sync suggestion history")
		Task {
			await cloudSync.sync()
			UIApplication.shared.endBackgroundTask(backgroundTask)
		}
		#else
		Task {
			await cloudSync.sync()
		}
		#endif
	}

	// MARK: - Helpers

	static func input(for article: Article) -> SuggestionInput {
		let authors = article.authors?.compactMap(\.name).sorted() ?? []
		let textLength = article.body?.utf8.count ?? 0
		return SuggestionInput(articleID: article.articleID, feedID: article.feedID, title: article.title ?? "", authors: authors, datePublished: article.logicalDatePublished, hasImage: article.imageLink != nil, textLength: textLength)
	}

	func record(_ kind: InteractionKind, article: Article) {
		let input = Self.input(for: article)
		Task {
			if await engine.record(kind, input: input) {
				await modelDidChange()
			}
		}
	}

	/// Records how long the current article has been on screen since the timer last started.
	func endDwell() {
		guard let currentArticleID, let dwellStartDate else {
			return
		}

		self.dwellStartDate = nil
		let seconds = min(Date().timeIntervalSince(dwellStartDate), Self.maximumDwellSegment)
		let articleIDs: Set<String> = [currentArticleID]
		Task {
			await engine.record(.dwell, articleIDs: articleIDs, value: seconds)
		}
	}

	func scheduleScoring() {
		guard scoringTask == nil else {
			return
		}

		scoringTask = Task {
			// Let a full screen of cells ask for scores before scoring them as one batch.
			await Task.yield()

			let inputs = Array(pendingScoreInputs.values)
			pendingScoreInputs.removeAll()
			let generation = scoreGeneration

			let newScores = await engine.scores(for: inputs)
			scoringTask = nil

			guard generation == scoreGeneration else {
				return
			}

			var shownArticleIDs = Set<String>()
			for input in inputs {
				let score = newScores[input.articleID] ?? 0
				scores[input.articleID] = score
				if score >= Self.displayThreshold {
					shownArticleIDs.insert(input.articleID)
				}
			}
			if !shownArticleIDs.isEmpty {
				postScoresDidChange(shownArticleIDs)
			}

			if !pendingScoreInputs.isEmpty {
				scheduleScoring()
			}
		}
	}

	func scheduleImpressions() {
		guard impressionsTask == nil else {
			return
		}

		impressionsTask = Task {
			await Task.yield()

			let inputs = pendingImpressions
			pendingImpressions.removeAll()
			await engine.recordImpressions(inputs)
			impressionsTask = nil

			if !pendingImpressions.isEmpty {
				scheduleImpressions()
			}
		}
	}

	func modelDidChange() async {
		isReady = await engine.isReady
		scoreGeneration += 1
		scores.removeAll()
		pendingScoreInputs.removeAll()
		postScoresDidChange(nil)
	}

	func postScoresDidChange(_ articleIDs: Set<String>?) {
		let userInfo: [String: Any]? = articleIDs.map { [UserInfoKey.articleIDs: $0] }
		NotificationCenter.default.post(name: .suggestionScoresDidChange, object: self, userInfo: userInfo)
	}
}
