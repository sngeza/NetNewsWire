//
//  ArticleExtractor.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 9/18/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import Foundation
import Account

public enum ArticleExtractorState: Sendable {
    case ready
    case processing
    case failedToParse
    case complete
	case cancelled
}

@MainActor protocol ArticleExtractorDelegate {
	func articleExtractionDidFail(with: Error)
	func articleExtractionDidComplete(extractedArticle: ExtractedArticle)
}

/// Extracts the readable content of the article at `articleLink`, on the device. See `ReadabilityExtractor`.
@MainActor final class ArticleExtractor {
	let articleLink: String
	let delegate: ArticleExtractorDelegate
	var article: ExtractedArticle?

	var state = ArticleExtractorState.ready
	private let url: URL
	private var task: Task<Void, Never>?

	public init?(_ articleLink: String, delegate: ArticleExtractorDelegate) {
		self.articleLink = articleLink
		self.delegate = delegate

		let articleLinkToUse = ArticleExtractor.specialCaseExtractionLink(for: articleLink) ?? articleLink
		guard let url = URL(string: articleLinkToUse), url.scheme == "http" || url.scheme == "https" else {
			return nil
		}
		self.url = url
	}

	public func process() {
		state = .processing

		task = Task { @MainActor in
			do {
				let extractedArticle = try await ReadabilityExtractor.shared.extract(url: url)
				guard state != .cancelled else {
					return
				}
				article = extractedArticle
				state = .complete
				delegate.articleExtractionDidComplete(extractedArticle: extractedArticle)
			} catch {
				guard state != .cancelled else {
					return
				}
				state = .failedToParse
				delegate.articleExtractionDidFail(with: error)
			}
		}
	}

	public func cancel() {
		state = .cancelled
		task?.cancel()
	}
}

private extension ArticleExtractor {

	/// Returns a URL string optimized for extraction, applying site-specific transformations where needed.
	static func specialCaseExtractionLink(for articleLink: String) -> String? {
		guard let url = URL(string: articleLink),
			  let host = url.host()?.lowercased() else {
			return nil
		}

		// Naver Blog desktop URLs use a JavaScript-heavy SPA that extractors can't parse.
		// The mobile site (m.blog.naver.com) renders as static HTML and works correctly.
		if host == "blog.naver.com" {
			var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
			components?.host = "m.blog.naver.com"
			components?.query = nil
			if let mobileURL = components?.url {
				return mobileURL.absoluteString
			}
		}

		return nil
	}
}
