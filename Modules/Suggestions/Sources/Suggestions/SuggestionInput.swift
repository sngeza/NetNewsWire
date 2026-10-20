//
//  SuggestionInput.swift
//  Suggestions
//
//  Created by Simon on 10/19/26.
//

import Foundation

/// A snapshot of the parts of an article the model learns from.
///
/// Stored in the interaction log so training doesn’t depend on the article
/// still existing in the account’s database.
public struct SuggestionInput: Sendable, Hashable {

	public let articleID: String
	public let feedID: String
	public let title: String
	public let authors: [String]
	public let datePublished: Date?
	public let hasImage: Bool
	public let textLength: Int

	public init(articleID: String, feedID: String, title: String, authors: [String], datePublished: Date?, hasImage: Bool, textLength: Int) {
		self.articleID = articleID
		self.feedID = feedID
		self.title = title
		self.authors = authors
		self.datePublished = datePublished
		self.hasImage = hasImage
		self.textLength = textLength
	}
}

public enum InteractionKind: String, Sendable, CaseIterable {
	/// Article was shown in the timeline.
	case impression
	/// Article was displayed in the detail pane.
	case open
	/// Seconds the article stayed displayed (stored in the event’s value).
	case dwell
	/// Article was opened in a browser.
	case browser
	case star
	case unstar
}

/// One device’s history with one article, rolled up for syncing.
public struct SuggestionSummary: Sendable, Hashable {
	public let deviceID: String
	public let input: SuggestionInput
	public let firstSeen: Date
	public let opens: Int
	public let totalDwell: Double
	public let browsers: Int
	/// Stars minus unstars.
	public let stars: Int

	public init(deviceID: String, input: SuggestionInput, firstSeen: Date, opens: Int, totalDwell: Double, browsers: Int, stars: Int) {
		self.deviceID = deviceID
		self.input = input
		self.firstSeen = firstSeen
		self.opens = opens
		self.totalDwell = totalDwell
		self.browsers = browsers
		self.stars = stars
	}
}
