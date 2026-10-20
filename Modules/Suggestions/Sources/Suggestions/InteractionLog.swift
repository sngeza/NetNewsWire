//
//  InteractionLog.swift
//  Suggestions
//
//  Created by Simon on 10/19/26.
//

import Foundation
import RSDatabase
import RSDatabaseObjC

struct LabeledExample: Sendable {
	let input: SuggestionInput
	let label: Bool
	let weight: Float
}

/// SQLite storage for reading events. Only used from inside `SuggestionEngine`.
///
/// This device’s events are stored one per row. For syncing, they’re rolled up into one
/// `SuggestionSummary` per article. Other devices’ summaries are stored as they arrive,
/// and training uses both.
final class InteractionLog {

	private let database: FMDatabase

	private static let tableCreationStatements = """
	CREATE TABLE if not EXISTS items (articleID TEXT NOT NULL PRIMARY KEY, feedID TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', authors TEXT NOT NULL DEFAULT '', datePublished REAL, hasImage INTEGER NOT NULL DEFAULT 0, textLength INTEGER NOT NULL DEFAULT 0, firstSeen REAL NOT NULL);
	CREATE TABLE if not EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, articleID TEXT NOT NULL, type TEXT NOT NULL, date REAL NOT NULL, value REAL NOT NULL DEFAULT 0);
	CREATE INDEX if not EXISTS events_articleID_index on events (articleID);
	CREATE TABLE if not EXISTS remoteSummaries (deviceID TEXT NOT NULL, articleID TEXT NOT NULL, feedID TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', authors TEXT NOT NULL DEFAULT '', datePublished REAL, hasImage INTEGER NOT NULL DEFAULT 0, textLength INTEGER NOT NULL DEFAULT 0, firstSeen REAL NOT NULL, opens INTEGER NOT NULL DEFAULT 0, totalDwell REAL NOT NULL DEFAULT 0, browsers INTEGER NOT NULL DEFAULT 0, stars INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (deviceID, articleID));
	CREATE TABLE if not EXISTS dirtyItems (articleID TEXT NOT NULL PRIMARY KEY);
	CREATE TABLE if not EXISTS pendingDeletes (articleID TEXT NOT NULL PRIMARY KEY);
	CREATE TABLE if not EXISTS info (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
	"""

	/// Authors are stored as one string; this separator can’t appear in a name.
	private static let authorSeparator = "\u{1F}"

	private static let localAggregateColumns = """
	items.*, \
	coalesce(sum(events.type = 'open'), 0) as opens, \
	coalesce(sum(case when events.type = 'dwell' then events.value end), 0) as totalDwell, \
	coalesce(sum(events.type = 'browser'), 0) as browsers, \
	coalesce(sum(events.type = 'star'), 0) - coalesce(sum(events.type = 'unstar'), 0) as stars
	"""

	/// Identifies this device’s summaries in iCloud. Created once and kept, even across resets.
	let deviceID: String

	init(databasePath: String) {
		let database = FMDatabase.openAndSetUpDatabase(path: databasePath)
		database.runCreateStatements(Self.tableCreationStatements)
		database.vacuumIfNeeded()
		self.database = database

		if let deviceID = Self.infoValue("deviceID", database: database) {
			self.deviceID = deviceID
		} else {
			let deviceID = UUID().uuidString
			Self.setInfoValue(deviceID, for: "deviceID", database: database)
			self.deviceID = deviceID
		}

		// History recorded before syncing existed was never marked for upload. Mark it once.
		if Self.infoValue("didMarkExistingHistoryForUpload", database: database) == nil {
			database.executeUpdateInTransaction("insert or ignore into dirtyItems (articleID) select articleID from items")
			Self.setInfoValue("1", for: "didMarkExistingHistoryForUpload", database: database)
		}
	}

	/// Adds the article snapshot if it isn’t already stored.
	func addItem(_ input: SuggestionInput, date: Date) {
		var dictionary: DatabaseDictionary = [
			"articleID": input.articleID,
			"feedID": input.feedID,
			"title": input.title,
			"authors": input.authors.joined(separator: Self.authorSeparator),
			"hasImage": input.hasImage,
			"textLength": input.textLength,
			"firstSeen": date.timeIntervalSince1970
		]
		if let datePublished = input.datePublished {
			dictionary["datePublished"] = datePublished.timeIntervalSince1970
		}
		database.insertRow(dictionary, insertType: .orIgnore, tableName: "items")
	}

	func addEvent(_ kind: InteractionKind, articleID: String, date: Date, value: Double = 0) {
		let dictionary: DatabaseDictionary = [
			"articleID": articleID,
			"type": kind.rawValue,
			"date": date.timeIntervalSince1970,
			"value": value
		]
		database.insertRow(dictionary, insertType: .normal, tableName: "events")
		database.insertRow(["articleID": articleID], insertType: .orIgnore, tableName: "dirtyItems")
	}

	/// Adds an event for each article without storing a snapshot. The event counts
	/// only if the article is also stored, via `addItem`, at some point.
	func addEvent(_ kind: InteractionKind, articleIDs: Set<String>, date: Date, value: Double = 0) {
		for articleID in articleIDs {
			addEvent(kind, articleID: articleID, date: date, value: value)
		}
	}

	func hasImpression(articleID: String) -> Bool {
		let sql = "select 1 from events where articleID = ? and type = ? limit 1"
		guard let resultSet = database.executeQuery(sql, withArgumentsIn: [articleID, InteractionKind.impression.rawValue]) else {
			return false
		}
		defer { resultSet.close() }
		return resultSet.next()
	}

	// MARK: - Training

	/// Builds training examples from this device’s log and other devices’ summaries.
	///
	/// An article is positive if it was opened, opened in a browser, or is starred.
	/// It’s negative if it was shown at least `negativeDelay` ago and never acted on.
	/// Articles shown more recently than that are left out, since the person may not have
	/// gotten to them yet.
	func labeledExamples(now: Date, negativeDelay: TimeInterval) -> [LabeledExample] {
		let merged = Self.merge(localSummaries() + remoteSummaries())
		let negativeCutoff = now.addingTimeInterval(-negativeDelay)

		return merged.compactMap { summary in
			let weight = Self.positiveWeight(opens: summary.opens, totalDwell: summary.totalDwell, browsers: summary.browsers, isStarred: summary.stars > 0)
			if weight > 0 {
				return LabeledExample(input: summary.input, label: true, weight: weight)
			}

			guard summary.firstSeen <= negativeCutoff else {
				return nil
			}
			return LabeledExample(input: summary.input, label: false, weight: 1)
		}
	}

	/// Combines summaries of the same article from different devices.
	///
	/// Counts add up, and the article counts as first seen when any device first showed it.
	/// Stars sync between devices, so each device may have logged the same star:
	/// the largest count is used, not the sum.
	static func merge(_ summaries: [SuggestionSummary]) -> [SuggestionSummary] {
		var merged = [String: SuggestionSummary]()
		var order = [String]()

		for summary in summaries {
			let articleID = summary.input.articleID
			guard let existing = merged[articleID] else {
				merged[articleID] = summary
				order.append(articleID)
				continue
			}
			merged[articleID] = SuggestionSummary(
				deviceID: existing.deviceID,
				input: existing.input,
				firstSeen: min(existing.firstSeen, summary.firstSeen),
				opens: existing.opens + summary.opens,
				totalDwell: existing.totalDwell + summary.totalDwell,
				browsers: existing.browsers + summary.browsers,
				stars: max(existing.stars, summary.stars)
			)
		}

		return order.compactMap { merged[$0] }
	}

	static func positiveWeight(opens: Int, totalDwell: Double, browsers: Int, isStarred: Bool) -> Float {
		var weight: Float = 0
		if opens > 0 {
			// Very short opens are usually skimming or moving to the next article.
			weight += totalDwell >= 3 ? 1 : 0.3
			if totalDwell > 20 {
				weight += 0.5
			}
		}
		if browsers > 0 {
			weight += 1
		}
		if isStarred {
			weight += 1.5
		}
		return weight
	}

	// MARK: - Sync

	/// This device’s summaries: all of them, or only the given articles.
	func localSummaries(articleIDs: [String]? = nil) -> [SuggestionSummary] {
		var sql = "select \(Self.localAggregateColumns) from items left join events on events.articleID = items.articleID"
		var arguments = [Any]()
		if let articleIDs {
			guard !articleIDs.isEmpty else {
				return []
			}
			sql += " where items.articleID in (\(Array(repeating: "?", count: articleIDs.count).joined(separator: ", ")))"
			arguments = articleIDs
		}
		sql += " group by items.articleID"

		guard let resultSet = database.executeQuery(sql, withArgumentsIn: arguments) else {
			return []
		}
		return resultSet.compactMap { summaryWithRow($0, deviceID: deviceID) }
	}

	func remoteSummaries() -> [SuggestionSummary] {
		guard let resultSet = database.executeQuery("select * from remoteSummaries", withArgumentsIn: nil) else {
			return []
		}
		return resultSet.compactMap { row in
			guard let deviceID = row.swiftString(forColumn: "deviceID") else {
				return nil
			}
			return summaryWithRow(row, deviceID: deviceID)
		}
	}

	/// Articles whose events changed since they were last uploaded.
	func dirtyArticleIDs(limit: Int) -> [String] {
		articleIDs(sql: "select articleID from dirtyItems limit ?", arguments: [limit])
	}

	func clearDirty(_ articleIDs: [String]) {
		delete(articleIDs, from: "dirtyItems")
	}

	/// This device’s articles whose summaries should be deleted from iCloud.
	func pendingDeleteArticleIDs(limit: Int) -> [String] {
		articleIDs(sql: "select articleID from pendingDeletes limit ?", arguments: [limit])
	}

	func clearPendingDeletes(_ articleIDs: [String]) {
		delete(articleIDs, from: "pendingDeletes")
	}

	/// Stores other devices’ summaries, replacing earlier versions. This device’s own are ignored.
	func saveRemoteSummaries(_ summaries: [SuggestionSummary]) {
		for summary in summaries where summary.deviceID != deviceID {
			let input = summary.input
			var dictionary: DatabaseDictionary = [
				"deviceID": summary.deviceID,
				"articleID": input.articleID,
				"feedID": input.feedID,
				"title": input.title,
				"authors": input.authors.joined(separator: Self.authorSeparator),
				"hasImage": input.hasImage,
				"textLength": input.textLength,
				"firstSeen": summary.firstSeen.timeIntervalSince1970,
				"opens": summary.opens,
				"totalDwell": summary.totalDwell,
				"browsers": summary.browsers,
				"stars": summary.stars
			]
			if let datePublished = input.datePublished {
				dictionary["datePublished"] = datePublished.timeIntervalSince1970
			}
			database.insertRow(dictionary, insertType: .orReplace, tableName: "remoteSummaries")
		}
	}

	func deleteRemoteSummary(deviceID: String, articleID: String) {
		database.executeUpdateInTransaction("delete from remoteSummaries where deviceID = ? and articleID = ?", withArgumentsIn: [deviceID, articleID])
	}

	func infoValue(_ key: String) -> String? {
		Self.infoValue(key, database: database)
	}

	func setInfoValue(_ value: String, for key: String) {
		Self.setInfoValue(value, for: key, database: database)
	}

	func deleteInfoValueForTesting(_ key: String) {
		database.executeUpdateInTransaction("delete from info where key = ?", withArgumentsIn: [key])
	}

	// MARK: - Removing History

	/// Removes history first seen before `date`. This device’s summaries of it are queued
	/// for deletion from iCloud.
	func prune(olderThan date: Date) {
		forgetHistory(before: date)
	}

	/// Removes everything first seen before `date`, on this device and in other devices’
	/// summaries stored here. This device’s summaries of it are queued for deletion from iCloud.
	func forgetHistory(before date: Date) {
		let cutoff = date.timeIntervalSince1970
		database.executeUpdateInTransaction("insert or ignore into pendingDeletes (articleID) select articleID from items where firstSeen < ?", withArgumentsIn: [cutoff])
		database.executeUpdateInTransaction("delete from dirtyItems where articleID in (select articleID from items where firstSeen < ?)", withArgumentsIn: [cutoff])
		database.executeUpdateInTransaction("delete from events where articleID in (select articleID from items where firstSeen < ?)", withArgumentsIn: [cutoff])
		database.executeUpdateInTransaction("delete from items where firstSeen < ?", withArgumentsIn: [cutoff])
		database.executeUpdateInTransaction("delete from remoteSummaries where firstSeen < ?", withArgumentsIn: [cutoff])
	}

	/// Removes all history. Keeps the device ID.
	func deleteAll() {
		for table in ["events", "items", "remoteSummaries", "dirtyItems", "pendingDeletes"] {
			database.executeUpdateInTransaction("delete from \(table)")
		}
	}

	func eventCount(articleID: String, kind: InteractionKind) -> Int {
		let sql = "select count(*) from events where articleID = ? and type = ?"
		guard let resultSet = database.executeQuery(sql, withArgumentsIn: [articleID, kind.rawValue]) else {
			return 0
		}
		defer { resultSet.close() }
		guard resultSet.next() else {
			return 0
		}
		return resultSet.long(forColumnIndex: 0)
	}
}

private extension InteractionLog {

	func inputWithRow(_ row: FMResultSet) -> SuggestionInput? {
		guard let articleID = row.swiftString(forColumn: "articleID"),
			  let feedID = row.swiftString(forColumn: "feedID") else {
			return nil
		}

		let title = row.swiftString(forColumn: "title") ?? ""
		let authorsString = row.swiftString(forColumn: "authors") ?? ""
		let authors = authorsString.isEmpty ? [] : authorsString.components(separatedBy: Self.authorSeparator)
		let datePublished = row.columnIsNull("datePublished") ? nil : Date(timeIntervalSince1970: row.double(forColumn: "datePublished"))
		let hasImage = row.bool(forColumn: "hasImage")
		let textLength = row.long(forColumn: "textLength")

		return SuggestionInput(articleID: articleID, feedID: feedID, title: title, authors: authors, datePublished: datePublished, hasImage: hasImage, textLength: textLength)
	}

	/// Reads a row from `remoteSummaries` or from the local aggregate query, which share column names.
	func summaryWithRow(_ row: FMResultSet, deviceID: String) -> SuggestionSummary? {
		guard let input = inputWithRow(row) else {
			return nil
		}
		return SuggestionSummary(
			deviceID: deviceID,
			input: input,
			firstSeen: Date(timeIntervalSince1970: row.double(forColumn: "firstSeen")),
			opens: row.long(forColumn: "opens"),
			totalDwell: row.double(forColumn: "totalDwell"),
			browsers: row.long(forColumn: "browsers"),
			stars: row.long(forColumn: "stars")
		)
	}

	func articleIDs(sql: String, arguments: [Any]) -> [String] {
		guard let resultSet = database.executeQuery(sql, withArgumentsIn: arguments) else {
			return []
		}
		return resultSet.compactMap { $0.swiftString(forColumn: "articleID") }
	}

	func delete(_ articleIDs: [String], from table: String) {
		guard !articleIDs.isEmpty else {
			return
		}
		let placeholders = Array(repeating: "?", count: articleIDs.count).joined(separator: ", ")
		database.executeUpdateInTransaction("delete from \(table) where articleID in (\(placeholders))", withArgumentsIn: articleIDs)
	}

	static func infoValue(_ key: String, database: FMDatabase) -> String? {
		guard let resultSet = database.executeQuery("select value from info where key = ?", withArgumentsIn: [key]) else {
			return nil
		}
		defer { resultSet.close() }
		guard resultSet.next() else {
			return nil
		}
		return resultSet.swiftString(forColumn: "value")
	}

	static func setInfoValue(_ value: String, for key: String, database: FMDatabase) {
		database.insertRow(["key": key, "value": value], insertType: .orReplace, tableName: "info")
	}
}
