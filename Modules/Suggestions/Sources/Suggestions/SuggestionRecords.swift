//
//  SuggestionRecords.swift
//  Suggestions
//
//  Created by Simon on 10/19/26.
//

import Foundation
import CloudKit

/// CloudKit record formats for suggestion history.
///
/// Each device writes one `SuggestionSummary` record per article, named
/// `<device ID>|<article ID>`, and is the only writer of its records, so they never conflict.
/// A reset writes one `SuggestionsReset` record; every device then forgets history from before it.
enum SuggestionRecords {

	static let zoneName = "Suggestions"

	enum Summary {
		static let recordType = "SuggestionSummary"
		enum Fields {
			static let deviceID = "deviceID"
			static let articleID = "articleID"
			static let feedID = "feedID"
			static let title = "title"
			static let authors = "authors"
			static let datePublished = "datePublished"
			static let hasImage = "hasImage"
			static let textLength = "textLength"
			static let firstSeen = "firstSeen"
			static let opens = "opens"
			static let totalDwell = "totalDwell"
			static let browsers = "browsers"
			static let stars = "stars"
		}
	}

	enum Reset {
		static let recordType = "SuggestionsReset"
		static let recordName = "reset"
		enum Fields {
			static let resetDate = "resetDate"
		}
	}

	static func recordName(deviceID: String, articleID: String) -> String {
		"\(deviceID)|\(articleID)"
	}

	static func record(for summary: SuggestionSummary, zoneID: CKRecordZone.ID) -> CKRecord {
		let recordID = CKRecord.ID(recordName: recordName(deviceID: summary.deviceID, articleID: summary.input.articleID), zoneID: zoneID)
		let record = CKRecord(recordType: Summary.recordType, recordID: recordID)
		let input = summary.input

		record[Summary.Fields.deviceID] = summary.deviceID
		record[Summary.Fields.articleID] = input.articleID
		record[Summary.Fields.feedID] = input.feedID
		record[Summary.Fields.title] = input.title
		record[Summary.Fields.authors] = input.authors.isEmpty ? nil : input.authors
		record[Summary.Fields.datePublished] = input.datePublished
		record[Summary.Fields.hasImage] = input.hasImage ? 1 : 0
		record[Summary.Fields.textLength] = input.textLength
		record[Summary.Fields.firstSeen] = summary.firstSeen
		record[Summary.Fields.opens] = summary.opens
		record[Summary.Fields.totalDwell] = summary.totalDwell
		record[Summary.Fields.browsers] = summary.browsers
		record[Summary.Fields.stars] = summary.stars
		return record
	}

	static func summary(from record: CKRecord) -> SuggestionSummary? {
		guard record.recordType == Summary.recordType,
			  let deviceID = record[Summary.Fields.deviceID] as? String,
			  let articleID = record[Summary.Fields.articleID] as? String,
			  let feedID = record[Summary.Fields.feedID] as? String,
			  let firstSeen = record[Summary.Fields.firstSeen] as? Date else {
			return nil
		}

		let input = SuggestionInput(
			articleID: articleID,
			feedID: feedID,
			title: record[Summary.Fields.title] as? String ?? "",
			authors: record[Summary.Fields.authors] as? [String] ?? [],
			datePublished: record[Summary.Fields.datePublished] as? Date,
			hasImage: (record[Summary.Fields.hasImage] as? Int ?? 0) != 0,
			textLength: record[Summary.Fields.textLength] as? Int ?? 0
		)
		return SuggestionSummary(
			deviceID: deviceID,
			input: input,
			firstSeen: firstSeen,
			opens: record[Summary.Fields.opens] as? Int ?? 0,
			totalDwell: record[Summary.Fields.totalDwell] as? Double ?? 0,
			browsers: record[Summary.Fields.browsers] as? Int ?? 0,
			stars: record[Summary.Fields.stars] as? Int ?? 0
		)
	}

	/// Splits `<device ID>|<article ID>`. Article IDs may contain `|`, device IDs (UUIDs) don’t.
	static func deviceAndArticleID(fromRecordName recordName: String) -> (deviceID: String, articleID: String)? {
		guard let separator = recordName.firstIndex(of: "|") else {
			return nil
		}
		let deviceID = String(recordName[..<separator])
		let articleID = String(recordName[recordName.index(after: separator)...])
		guard !deviceID.isEmpty, !articleID.isEmpty else {
			return nil
		}
		return (deviceID, articleID)
	}

	static func resetRecord(date: Date, zoneID: CKRecordZone.ID) -> CKRecord {
		let record = CKRecord(recordType: Reset.recordType, recordID: CKRecord.ID(recordName: Reset.recordName, zoneID: zoneID))
		record[Reset.Fields.resetDate] = date
		return record
	}

	static func resetDate(from record: CKRecord) -> Date? {
		guard record.recordType == Reset.recordType else {
			return nil
		}
		return record[Reset.Fields.resetDate] as? Date
	}
}
