//
//  SuggestionsTests.swift
//  Suggestions
//
//  Created by Simon on 10/19/26.
//

import Testing
import Foundation
import CloudKit
@testable import Suggestions

@Suite struct FeatureExtractorTests {

	@Test func hashIsStable() {
		// FNV-1a reference value for "a".
		#expect(FeatureExtractor.fnv1a("a") == 0xaf63dc4c8601ec8c)
		#expect(FeatureExtractor.index(for: "feed:123") == FeatureExtractor.index(for: "feed:123"))
		#expect(FeatureExtractor.index(for: "feed:123") < FeatureExtractor.dimension)
	}

	@Test func tokenizationDropsStopwordsAndShortTokens() {
		let tokens = FeatureExtractor().titleTokens("The Swift compiler is now faster than ever")
		#expect(tokens == ["swift", "compiler", "faster", "ever"])
	}

	@Test func featuresIncludeFeedAndAuthor() {
		let input = SuggestionInput(articleID: "1", feedID: "feedA", title: "Hello world", authors: ["Jane Doe"], datePublished: nil, hasImage: false, textLength: 100)
		let indexes = Set(FeatureExtractor().features(for: input).map(\.index))
		#expect(indexes.contains(FeatureExtractor.index(for: "feed:feedA")))
		#expect(indexes.contains(FeatureExtractor.index(for: "author:jane doe")))
		#expect(indexes.contains(FeatureExtractor.index(for: "word:hello")))
	}
}

@Suite struct SuggestionModelTests {

	@Test func learnsPreferredFeed() {
		let extractor = FeatureExtractor()
		var examples = [(features: [SparseFeature], label: Bool, weight: Float)]()
		for i in 0..<60 {
			let liked = SuggestionInput(articleID: "a\(i)", feedID: "A", title: "Story number \(i)", authors: [], datePublished: nil, hasImage: false, textLength: 0)
			let disliked = SuggestionInput(articleID: "b\(i)", feedID: "B", title: "Story number \(i)", authors: [], datePublished: nil, hasImage: false, textLength: 0)
			examples.append((extractor.features(for: liked), true, 1))
			examples.append((extractor.features(for: disliked), false, 1))
		}

		var model = SuggestionModel()
		model.train(examples)
		#expect(model.isReady)

		let newA = SuggestionInput(articleID: "x", feedID: "A", title: "Something else", authors: [], datePublished: nil, hasImage: false, textLength: 0)
		let newB = SuggestionInput(articleID: "y", feedID: "B", title: "Something else", authors: [], datePublished: nil, hasImage: false, textLength: 0)
		#expect(model.probability(extractor.features(for: newA)) > 0.8)
		#expect(model.probability(extractor.features(for: newB)) < 0.2)
	}

	@Test func serializationRoundTrips() throws {
		let extractor = FeatureExtractor()
		let positive = SuggestionInput(articleID: "1", feedID: "A", title: "Liked", authors: [], datePublished: nil, hasImage: false, textLength: 0)
		let negative = SuggestionInput(articleID: "2", feedID: "B", title: "Skipped", authors: [], datePublished: nil, hasImage: false, textLength: 0)
		var model = SuggestionModel()
		model.train([(extractor.features(for: positive), true, 1), (extractor.features(for: negative), false, 1)])

		let restored = try #require(SuggestionModel(data: model.serialized()))
		#expect(restored.weights == model.weights)
		#expect(restored.positiveCount == 1)
		#expect(restored.negativeCount == 1)
		#expect(SuggestionModel(data: Data([1, 2, 3])) == nil)
	}
}

@Suite struct InteractionLogTests {

	private func temporaryPath(_ ext: String) -> String {
		(NSTemporaryDirectory() as NSString).appendingPathComponent("SuggestionsTests-\(UUID().uuidString).\(ext)")
	}

	private func input(_ id: String, feedID: String = "feed") -> SuggestionInput {
		SuggestionInput(articleID: id, feedID: feedID, title: "Title \(id)", authors: ["Author One", "Author Two"], datePublished: Date(timeIntervalSince1970: 1_700_000_000), hasImage: true, textLength: 1234)
	}

	@Test func positiveWeights() {
		#expect(InteractionLog.positiveWeight(opens: 0, totalDwell: 0, browsers: 0, isStarred: false) == 0)
		#expect(InteractionLog.positiveWeight(opens: 1, totalDwell: 1, browsers: 0, isStarred: false) == 0.3)
		#expect(InteractionLog.positiveWeight(opens: 1, totalDwell: 10, browsers: 0, isStarred: false) == 1)
		#expect(InteractionLog.positiveWeight(opens: 1, totalDwell: 30, browsers: 0, isStarred: false) == 1.5)
		#expect(InteractionLog.positiveWeight(opens: 1, totalDwell: 30, browsers: 1, isStarred: true) == 4)
	}

	@Test func labelsFollowRules() throws {
		let path = temporaryPath("db")
		defer { try? FileManager.default.removeItem(atPath: path) }

		let log = InteractionLog(databasePath: path)
		let now = Date()
		let longAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)
		let recently = now.addingTimeInterval(-60 * 60)

		// Opened and read for a while.
		log.addItem(input("read"), date: longAgo)
		log.addEvent(.open, articleID: "read", date: longAgo)
		log.addEvent(.dwell, articleID: "read", date: longAgo, value: 25)

		// Shown long ago, never opened: negative.
		log.addItem(input("skipped"), date: longAgo)
		log.addEvent(.impression, articleID: "skipped", date: longAgo)

		// Shown recently, not opened yet: excluded.
		log.addItem(input("fresh"), date: recently)
		log.addEvent(.impression, articleID: "fresh", date: recently)

		// Starred then unstarred, never opened: negative.
		log.addItem(input("unstarred"), date: longAgo)
		log.addEvent(.star, articleID: "unstarred", date: longAgo)
		log.addEvent(.unstar, articleID: "unstarred", date: longAgo)

		let examples = log.labeledExamples(now: now, negativeDelay: 48 * 60 * 60)
		let byID = Dictionary(uniqueKeysWithValues: examples.map { ($0.input.articleID, $0) })

		#expect(byID.count == 3)
		#expect(byID["read"]?.label == true)
		#expect(byID["read"]?.weight == 1.5)
		#expect(byID["skipped"]?.label == false)
		#expect(byID["fresh"] == nil)
		#expect(byID["unstarred"]?.label == false)

		let restored = try #require(byID["read"]?.input)
		#expect(restored == input("read"))
	}

	@Test func pruneRemovesOldItems() {
		let path = temporaryPath("db")
		defer { try? FileManager.default.removeItem(atPath: path) }

		let log = InteractionLog(databasePath: path)
		let now = Date()
		log.addItem(input("old"), date: now.addingTimeInterval(-200 * 24 * 60 * 60))
		log.addEvent(.impression, articleID: "old", date: now.addingTimeInterval(-200 * 24 * 60 * 60))
		log.addItem(input("new"), date: now)
		log.addEvent(.impression, articleID: "new", date: now)

		log.prune(olderThan: now.addingTimeInterval(-180 * 24 * 60 * 60))

		#expect(log.eventCount(articleID: "old", kind: .impression) == 0)
		#expect(log.eventCount(articleID: "new", kind: .impression) == 1)
		#expect(log.hasImpression(articleID: "new"))
		#expect(!log.hasImpression(articleID: "old"))
	}
}

@Suite struct SuggestionEngineTests {

	@Test func becomesReadyAndScoresPreferredFeedHigher() async {
		let databasePath = (NSTemporaryDirectory() as NSString).appendingPathComponent("SuggestionsEngine-\(UUID().uuidString).db")
		let modelPath = databasePath + ".model"
		defer {
			try? FileManager.default.removeItem(atPath: databasePath)
			try? FileManager.default.removeItem(atPath: modelPath)
		}

		let engine = SuggestionEngine(databasePath: databasePath, modelPath: modelPath, negativeDelay: 0)
		let past = Date().addingTimeInterval(-60)

		func input(_ id: String, feedID: String) -> SuggestionInput {
			SuggestionInput(articleID: id, feedID: feedID, title: "Article \(id)", authors: [], datePublished: nil, hasImage: false, textLength: 0)
		}

		var impressions = [SuggestionInput]()
		for i in 0..<60 {
			impressions.append(input("b\(i)", feedID: "B"))
		}
		await engine.recordImpressions(impressions, date: past)
		for i in 0..<30 {
			await engine.record(.open, input: input("a\(i)", feedID: "A"), date: past)
			await engine.record(.dwell, input: input("a\(i)", feedID: "A"), value: 10, date: past)
		}
		await engine.retrain()

		#expect(await engine.isReady)
		let scores = await engine.scores(for: [input("newA", feedID: "A"), input("newB", feedID: "B")])
		let scoreA = scores["newA"] ?? 0
		let scoreB = scores["newB"] ?? 1
		#expect(scoreA > scoreB)

		// A fresh engine loads the saved model.
		let reloaded = SuggestionEngine(databasePath: databasePath, modelPath: modelPath)
		#expect(await reloaded.isReady)

		await engine.reset()
		#expect(await !engine.isReady)
		#expect(await engine.scores(for: [input("newA", feedID: "A")]).isEmpty)
	}
}

@Suite struct SuggestionSyncTests {

	private func temporaryPath() -> String {
		(NSTemporaryDirectory() as NSString).appendingPathComponent("SuggestionsSync-\(UUID().uuidString).db")
	}

	private func input(_ id: String, feedID: String = "feed") -> SuggestionInput {
		SuggestionInput(articleID: id, feedID: feedID, title: "Title \(id)", authors: ["Author"], datePublished: Date(timeIntervalSince1970: 1_700_000_000), hasImage: false, textLength: 10)
	}

	private func summary(_ id: String, deviceID: String, firstSeen: Date, opens: Int = 0, totalDwell: Double = 0, browsers: Int = 0, stars: Int = 0) -> SuggestionSummary {
		SuggestionSummary(deviceID: deviceID, input: input(id), firstSeen: firstSeen, opens: opens, totalDwell: totalDwell, browsers: browsers, stars: stars)
	}

	@Test func mergeCombinesDevices() {
		let early = Date(timeIntervalSince1970: 1000)
		let late = Date(timeIntervalSince1970: 2000)
		let merged = InteractionLog.merge([
			summary("a", deviceID: "mac", firstSeen: late, opens: 1, totalDwell: 10, stars: 1),
			summary("a", deviceID: "phone", firstSeen: early, opens: 2, totalDwell: 5, browsers: 1, stars: 1),
			summary("b", deviceID: "phone", firstSeen: late)
		])

		#expect(merged.count == 2)
		let a = merged[0]
		#expect(a.input.articleID == "a")
		#expect(a.firstSeen == early)
		#expect(a.opens == 3)
		#expect(a.totalDwell == 15)
		#expect(a.browsers == 1)
		// The same star synced to both devices counts once.
		#expect(a.stars == 1)
	}

	@Test func remoteOpensMakeLocalImpressionPositive() {
		let path = temporaryPath()
		defer { try? FileManager.default.removeItem(atPath: path) }
		let log = InteractionLog(databasePath: path)
		let longAgo = Date().addingTimeInterval(-3 * 24 * 60 * 60)

		// Shown here and never opened here, but read on another device.
		log.addItem(input("a"), date: longAgo)
		log.addEvent(.impression, articleID: "a", date: longAgo)
		log.saveRemoteSummaries([summary("a", deviceID: "other", firstSeen: longAgo, opens: 1, totalDwell: 30)])

		let examples = log.labeledExamples(now: Date(), negativeDelay: 48 * 60 * 60)
		#expect(examples.count == 1)
		#expect(examples.first?.label == true)
	}

	@Test func ownSummariesAreNotStoredAsRemote() {
		let path = temporaryPath()
		defer { try? FileManager.default.removeItem(atPath: path) }
		let log = InteractionLog(databasePath: path)

		log.saveRemoteSummaries([summary("a", deviceID: log.deviceID, firstSeen: Date()), summary("b", deviceID: "other", firstSeen: Date())])
		#expect(log.remoteSummaries().map(\.input.articleID) == ["b"])

		log.deleteRemoteSummary(deviceID: "other", articleID: "b")
		#expect(log.remoteSummaries().isEmpty)
	}

	@Test func existingHistoryIsMarkedForUploadOnce() {
		let path = temporaryPath()
		defer { try? FileManager.default.removeItem(atPath: path) }

		// Simulate history from before syncing: items with nothing marked for upload.
		let log = InteractionLog(databasePath: path)
		log.addItem(input("a"), date: Date())
		log.addEvent(.impression, articleID: "a", date: Date())
		log.clearDirty(["a"])
		log.deleteInfoValueForTesting("didMarkExistingHistoryForUpload")

		let reopened = InteractionLog(databasePath: path)
		#expect(reopened.dirtyArticleIDs(limit: 10) == ["a"])

		reopened.clearDirty(["a"])
		#expect(InteractionLog(databasePath: path).dirtyArticleIDs(limit: 10).isEmpty)
	}

	@Test func deviceIDPersists() {
		let path = temporaryPath()
		defer { try? FileManager.default.removeItem(atPath: path) }
		let deviceID = InteractionLog(databasePath: path).deviceID
		#expect(InteractionLog(databasePath: path).deviceID == deviceID)
	}

	@Test func eventsMarkArticlesForUpload() {
		let path = temporaryPath()
		defer { try? FileManager.default.removeItem(atPath: path) }
		let log = InteractionLog(databasePath: path)
		let now = Date()

		log.addItem(input("a"), date: now)
		log.addEvent(.open, articleID: "a", date: now)
		log.addEvent(.dwell, articleID: "a", date: now, value: 12)

		#expect(log.dirtyArticleIDs(limit: 10) == ["a"])
		let summaries = log.localSummaries(articleIDs: ["a"])
		#expect(summaries.count == 1)
		#expect(summaries.first?.opens == 1)
		#expect(summaries.first?.totalDwell == 12)
		#expect(summaries.first?.deviceID == log.deviceID)

		log.clearDirty(["a"])
		#expect(log.dirtyArticleIDs(limit: 10).isEmpty)
	}

	@Test func forgettingHistoryQueuesDeletes() {
		let path = temporaryPath()
		defer { try? FileManager.default.removeItem(atPath: path) }
		let log = InteractionLog(databasePath: path)
		let old = Date(timeIntervalSince1970: 1000)
		let recent = Date()

		log.addItem(input("old"), date: old)
		log.addEvent(.impression, articleID: "old", date: old)
		log.addItem(input("new"), date: recent)
		log.addEvent(.impression, articleID: "new", date: recent)
		log.saveRemoteSummaries([summary("remoteOld", deviceID: "other", firstSeen: old), summary("remoteNew", deviceID: "other", firstSeen: recent)])

		log.forgetHistory(before: Date(timeIntervalSince1970: 5000))

		#expect(log.localSummaries().map(\.input.articleID) == ["new"])
		#expect(log.remoteSummaries().map(\.input.articleID) == ["remoteNew"])
		#expect(log.pendingDeleteArticleIDs(limit: 10) == ["old"])
		#expect(log.dirtyArticleIDs(limit: 10) == ["new"])
	}

	@Test func engineIgnoresSummariesFromBeforeReset() async {
		let path = temporaryPath()
		let modelPath = path + ".model"
		defer {
			try? FileManager.default.removeItem(atPath: path)
			try? FileManager.default.removeItem(atPath: modelPath)
		}
		let engine = SuggestionEngine(databasePath: path, modelPath: modelPath)
		let resetDate = Date(timeIntervalSince1970: 5000)

		#expect(await engine.applyReset(date: resetDate))
		#expect(await !engine.applyReset(date: resetDate))

		let changed = [
			summary("before", deviceID: "other", firstSeen: Date(timeIntervalSince1970: 1000)),
			summary("after", deviceID: "other", firstSeen: Date(timeIntervalSince1970: 9000))
		]
		#expect(await engine.applyRemoteChanges(changed: changed, deleted: []))
		#expect(await engine.remoteSummaryCount() == 1)
	}

	@Test func recordsRoundTrip() throws {
		let zoneID = CKRecordZone.ID(zoneName: SuggestionRecords.zoneName, ownerName: CKCurrentUserDefaultName)
		let original = summary("feed|article", deviceID: "device-1", firstSeen: Date(timeIntervalSince1970: 1234), opens: 2, totalDwell: 7.5, browsers: 1, stars: 1)

		let record = SuggestionRecords.record(for: original, zoneID: zoneID)
		#expect(record.recordID.recordName == "device-1|feed|article")
		#expect(try #require(SuggestionRecords.summary(from: record)) == original)

		let ids = try #require(SuggestionRecords.deviceAndArticleID(fromRecordName: record.recordID.recordName))
		#expect(ids.deviceID == "device-1")
		#expect(ids.articleID == "feed|article")

		let reset = SuggestionRecords.resetRecord(date: Date(timeIntervalSince1970: 42), zoneID: zoneID)
		#expect(SuggestionRecords.resetDate(from: reset) == Date(timeIntervalSince1970: 42))
		#expect(SuggestionRecords.summary(from: reset) == nil)
	}
}
