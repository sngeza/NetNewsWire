//
//  SuggestionEngine.swift
//  Suggestions
//
//  Created by Simon on 10/19/26.
//

import Foundation
import os

/// Logs reading events, trains the model, and scores articles.
///
/// Everything stays on this device; nothing here is synced.
public actor SuggestionEngine {

	public nonisolated let databasePath: String
	public nonisolated let modelPath: String

	private let log: InteractionLog
	private let extractor = FeatureExtractor()
	private let negativeDelay: TimeInterval
	private var model: SuggestionModel
	private var labeledEventsSinceTraining = 0

	/// Retrain after this many opens, browser opens, or star changes.
	static let labeledEventsBetweenTraining = 25

	static let retentionInterval: TimeInterval = 180 * 24 * 60 * 60

	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Suggestions", category: "Suggestions")

	/// `negativeDelay` is how long an article must have been shown, unopened,
	/// before it counts as not interesting.
	public init(databasePath: String, modelPath: String, negativeDelay: TimeInterval = 5*60) { // 48 * 60 * 60) {
		self.databasePath = databasePath
		self.modelPath = modelPath
		self.negativeDelay = negativeDelay
		self.log = InteractionLog(databasePath: databasePath)

		if let data = try? Data(contentsOf: URL(fileURLWithPath: modelPath)), let model = SuggestionModel(data: data) {
			self.model = model
		} else {
			self.model = SuggestionModel()
		}
	}

	public var isReady: Bool {
		model.isReady
	}

	public var exampleCounts: (positives: Int, negatives: Int) {
		(model.positiveCount, model.negativeCount)
	}

	/// Records an event. Returns true if it caused the model to retrain.
	@discardableResult
	public func record(_ kind: InteractionKind, input: SuggestionInput, value: Double = 0, date: Date = Date()) -> Bool {
		log.addItem(input, date: date)
		log.addEvent(kind, articleID: input.articleID, date: date, value: value)

		return noteEvents(kind, count: 1, date: date)
	}

	/// Records an event for articles that may not have a stored snapshot yet,
	/// such as a star change that arrives only as article IDs.
	/// Returns true if it caused the model to retrain.
	@discardableResult
	public func record(_ kind: InteractionKind, articleIDs: Set<String>, value: Double = 0, date: Date = Date()) -> Bool {
		log.addEvent(kind, articleIDs: articleIDs, date: date, value: value)
		return noteEvents(kind, count: articleIDs.count, date: date)
	}

	/// Records an impression for each article not already shown before.
	public func recordImpressions(_ inputs: [SuggestionInput], date: Date = Date()) {
		for input in inputs where !log.hasImpression(articleID: input.articleID) {
			log.addItem(input, date: date)
			log.addEvent(.impression, articleID: input.articleID, date: date)
		}
	}

	/// Probability, from 0 to 1, that each article will be opened.
	/// Empty until there’s enough history.
	public func scores(for inputs: [SuggestionInput]) -> [String: Float] {
		guard model.isReady else {
			return [:]
		}

		var scores = [String: Float]()
		for input in inputs {
			scores[input.articleID] = model.probability(extractor.features(for: input))
		}
		return scores
	}

	public func retrain(now: Date = Date()) {
		labeledEventsSinceTraining = 0

		let examples = log.labeledExamples(now: now, negativeDelay: negativeDelay).map {
			(features: extractor.features(for: $0.input), label: $0.label, weight: $0.weight)
		}

		var model = SuggestionModel()
		model.train(examples)
		self.model = model

		Self.logger.info("Suggestions: trained on \(model.positiveCount) positives and \(model.negativeCount) negatives")
		saveModel()
	}

	public func prune(now: Date = Date()) {
		log.prune(olderThan: now.addingTimeInterval(-Self.retentionInterval))
	}

	/// Deletes all reading history and the trained model, on this device only.
	/// `SuggestionsCloudSync.resetEverywhere` also clears it from iCloud and other devices.
	public func reset(date: Date = Date()) {
		lastResetDate = date
		log.deleteAll()
		model = SuggestionModel()
		labeledEventsSinceTraining = 0
		try? FileManager.default.removeItem(atPath: modelPath)
	}
}

// MARK: - Sync

public extension SuggestionEngine {

	var deviceID: String {
		log.deviceID
	}

	/// This device’s changes not yet in iCloud: summaries to save and article IDs whose
	/// summaries to delete. Call `didUpload` once they’re saved.
	func pendingUploads(limit: Int) -> (summaries: [SuggestionSummary], dirtyArticleIDs: [String], deletedArticleIDs: [String]) {
		let dirtyArticleIDs = log.dirtyArticleIDs(limit: limit)
		let summaries = log.localSummaries(articleIDs: dirtyArticleIDs)
		let deletedArticleIDs = log.pendingDeleteArticleIDs(limit: limit)
		return (summaries, dirtyArticleIDs, deletedArticleIDs)
	}

	func didUpload(dirtyArticleIDs: [String], deletedArticleIDs: [String]) {
		log.clearDirty(dirtyArticleIDs)
		log.clearPendingDeletes(deletedArticleIDs)
	}

	/// Applies other devices’ changes. Returns true if anything changed; the caller retrains,
	/// once per sync rather than once per page of changes.
	@discardableResult
	func applyRemoteChanges(changed: [SuggestionSummary], deleted: [(deviceID: String, articleID: String)]) -> Bool {
		let resetDate = lastResetDate
		let changedFromOtherDevices = changed.filter { summary in
			guard summary.deviceID != deviceID else {
				return false
			}
			guard let resetDate else {
				return true
			}
			return summary.firstSeen >= resetDate
		}
		let deletedFromOtherDevices = deleted.filter { $0.deviceID != deviceID }
		guard !changedFromOtherDevices.isEmpty || !deletedFromOtherDevices.isEmpty else {
			return false
		}

		log.saveRemoteSummaries(changedFromOtherDevices)
		for (deviceID, articleID) in deletedFromOtherDevices {
			log.deleteRemoteSummary(deviceID: deviceID, articleID: articleID)
		}
		return true
	}

	/// Applies a reset made on any device: forgets history from before `date`.
	/// Returns true if the reset was new here; the caller retrains.
	@discardableResult
	func applyReset(date: Date) -> Bool {
		if let lastResetDate, lastResetDate >= date {
			return false
		}
		lastResetDate = date
		log.forgetHistory(before: date)
		return true
	}

	/// The latest reset seen, from any device. Summaries first seen before it are ignored.
	private(set) var lastResetDate: Date? {
		get {
			log.infoValue("lastResetDate").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
		}
		set {
			log.setInfoValue(String(newValue?.timeIntervalSince1970 ?? 0), for: "lastResetDate")
		}
	}
}

extension SuggestionEngine {

	func eventCount(articleID: String, kind: InteractionKind) -> Int {
		log.eventCount(articleID: articleID, kind: kind)
	}

	func remoteSummaryCount() -> Int {
		log.remoteSummaries().count
	}
}

private extension SuggestionEngine {

	func noteEvents(_ kind: InteractionKind, count: Int, date: Date) -> Bool {
		switch kind {
		case .open, .browser, .star, .unstar:
			labeledEventsSinceTraining += count
		case .impression, .dwell:
			break
		}

		guard labeledEventsSinceTraining >= Self.labeledEventsBetweenTraining else {
			return false
		}
		retrain(now: date)
		return true
	}

	func saveModel() {
		do {
			try model.serialized().write(to: URL(fileURLWithPath: modelPath), options: .atomic)
		} catch {
			Self.logger.error("Suggestions: could not save model: \(error.localizedDescription)")
		}
	}
}
