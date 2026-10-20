//
//  TimelineCellData.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 2/6/16.
//  Copyright © 2016 Ranchero Software, LLC. All rights reserved.
//

import AppKit
import Articles
import Images

@MainActor struct TimelineCellData {

	private static let noText = NSLocalizedString("(No Text)", comment: "No Text")

	let title: String
	let attributedTitle: NSAttributedString
	let text: String
	let dateString: String
	let feedName: String
	let byline: String
	let showFeedName: TimelineShowFeedName
	let iconImage: IconImage? // feed icon, user avatar, or favicon
	let showIcon: Bool // Make space even when icon is nil
	let read: Bool
	let starred: Bool
	let suggestionScore: Float // 0 when not suggested

	init(article: Article, showFeedName: TimelineShowFeedName, feedName: String?, byline: String?, iconImage: IconImage?, showIcon: Bool, suggestionScore: Float = 0) {

		self.title = ArticleStringFormatter.shared.truncatedTitle(article)
		self.attributedTitle = ArticleStringFormatter.shared.attributedTruncatedTitle(article)
		self.text = Self.summaryText(for: article, title: self.title)

		self.dateString = ArticleStringFormatter.shared.dateString(article.logicalDatePublished)

		if let feedName = feedName {
			self.feedName = ArticleStringFormatter.shared.truncatedFeedName(feedName)
		} else {
			self.feedName = ""
		}

		if let byline = byline {
			self.byline = byline
		} else {
			self.byline = ""
		}

		self.showFeedName = showFeedName

		self.showIcon = showIcon
		self.iconImage = iconImage

		self.read = article.status.read
		self.starred = article.status.starred
		self.suggestionScore = suggestionScore
	}

	/// The article’s summary, or “(No Text)” when it has neither a title nor a summary.
	static func summaryText(for article: Article, title: String) -> String {
		let truncatedSummary = ArticleStringFormatter.shared.truncatedSummary(article)
		if title.isEmpty && truncatedSummary.isEmpty {
			return noText
		}
		return truncatedSummary
	}

	init() { // Empty
		self.title = ""
		self.text = ""
		self.dateString = ""
		self.feedName = ""
		self.byline = ""
		self.showFeedName = .none
		self.showIcon = false
		self.iconImage = nil
		self.read = true
		self.starred = false
		self.suggestionScore = 0
		self.attributedTitle = NSAttributedString()
	}
}
