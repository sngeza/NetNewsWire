//
//  SuggestedFeed.swift
//  NetNewsWire
//
//  Created by Simon on 10/19/26.
//

#if os(macOS)
import AppKit
#else
import Foundation
#endif
import RSCore
import Account
import Articles
import ArticlesDatabase
import Images

extension Notification.Name {
	/// Posted when the set of articles in the Suggested feed changes.
	static let suggestedFeedDidChange = Notification.Name("SuggestedFeedDidChangeNotification")
}

/// Unread articles, from all feeds, that the person is likely to open.
///
/// Scoring is asynchronous, but the sidebar fetches synchronously when this feed is
/// selected. So the feed keeps the current set of suggested article IDs and refreshes it
/// in the background whenever unread counts or the model change.
@MainActor final class SuggestedFeed: PseudoFeed {

	var account: Account?

	public var defaultReadFilterType: ReadFilterType {
		return .alwaysRead
	}

	var sidebarItemID: SidebarItemIdentifier? {
		return SidebarItemIdentifier.smartFeed(String(describing: SuggestedFeed.self))
	}

	let nameForDisplay = NSLocalizedString("Suggested", comment: "Suggested pseudo-feed title: unread articles you’re likely to open")
	private let fetchType = FetchType.unread(nil)

	var unreadCount = 0 {
		didSet {
			if unreadCount != oldValue {
				postUnreadCountDidChangeNotification()
			}
		}
	}

	var smallIcon: IconImage? {
		Assets.Images.suggestedFeed
	}

	#if os(macOS)
	var pasteboardWriter: NSPasteboardWriting {
		return SmartFeedPasteboardWriter(smartFeed: self)
	}
	#endif

	private var suggestedArticleIDs = Set<String>()
	private var isRefreshing = false
	private var needsRefresh = false

	init() {
		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: AccountManager.shared)
		NotificationCenter.default.addObserver(self, selector: #selector(suggestionScoresDidChange(_:)), name: .suggestionScoresDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidBecomeActive(_:)), name: .appDidBecomeActive, object: nil)
		queueRefresh()
	}

	@objc func unreadCountDidChange(_ note: Notification) {
		queueRefresh()
	}

	@objc func suggestionScoresDidChange(_ note: Notification) {
		// Notifications with article IDs come from scoring visible cells with the same model,
		// so they don’t change which articles belong here. No userInfo means the model
		// or the setting changed.
		if note.userInfo == nil {
			queueRefresh()
		}
	}

	@objc func handleAppDidBecomeActive(_ note: Notification) {
		queueRefresh()
	}

	@objc func refresh() {
		// Unread counts change continuously during a refresh. Only one round
		// is in flight at a time, and one more is queued afterward if needed.
		if isRefreshing {
			needsRefresh = true
			return
		}

		isRefreshing = true
		Task { @MainActor in
			let unreadArticles = await AccountManager.shared.fetchArticlesAsync(fetchType)
			let updatedArticleIDs = await SuggestionsManager.shared.suggestedArticleIDs(in: unreadArticles)

			if updatedArticleIDs != suggestedArticleIDs {
				suggestedArticleIDs = updatedArticleIDs
				NotificationCenter.default.post(name: .suggestedFeedDidChange, object: self)
			}
			unreadCount = updatedArticleIDs.count

			isRefreshing = false
			if needsRefresh {
				needsRefresh = false
				queueRefresh()
			}
		}
	}
}

@MainActor extension SuggestedFeed: ArticleFetcher {

	func fetchArticles() -> Set<Article> {
		fetchUnreadArticles()
	}

	func fetchArticlesAsync() async -> Set<Article> {
		await fetchUnreadArticlesAsync()
	}

	func fetchUnreadArticles() -> Set<Article> {
		filteredArticles(AccountManager.shared.fetchArticles(fetchType))
	}

	func fetchUnreadArticlesAsync() async -> Set<Article> {
		filteredArticles(await AccountManager.shared.fetchArticlesAsync(fetchType))
	}
}

private extension SuggestedFeed {

	func queueRefresh() {
		CoalescingQueue.standard.add(self, #selector(refresh))
	}

	func filteredArticles(_ articles: Set<Article>) -> Set<Article> {
		articles.filter { suggestedArticleIDs.contains($0.articleID) }
	}
}
