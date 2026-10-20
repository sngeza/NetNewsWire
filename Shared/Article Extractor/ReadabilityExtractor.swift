//
//  ReadabilityExtractor.swift
//  NetNewsWire
//
//  Created by Simon on 10/20/26.
//

import Foundation
import WebKit
import RSWeb

/// Extracts an article’s readable content on the device, using Mozilla’s Readability.js
/// (the reader view engine in Firefox), bundled as Readability.js.
///
/// The page’s HTML is downloaded, then parsed by Readability in a hidden web view as a
/// detached document: the page itself is never loaded, so none of its scripts run and
/// none of its images, trackers, or ads are fetched.
@MainActor final class ReadabilityExtractor {

	static let shared = ReadabilityExtractor()

	enum ExtractionError: LocalizedError {
		case downloadFailed(statusCode: Int)
		case notHTML
		case undecodableHTML
		case missingReadabilityScript
		/// Readability didn’t find an article on the page.
		case noArticle

		var errorDescription: String? {
			switch self {
			case .downloadFailed(let statusCode):
				return String(format: NSLocalizedString("The page couldn’t be downloaded (HTTP %d).", comment: "Reader view error"), statusCode)
			case .notHTML:
				return NSLocalizedString("The page isn’t a web page.", comment: "Reader view error")
			case .undecodableHTML:
				return NSLocalizedString("The page’s text couldn’t be read.", comment: "Reader view error")
			case .missingReadabilityScript:
				return NSLocalizedString("Reader view is unavailable.", comment: "Reader view error")
			case .noArticle:
				return NSLocalizedString("No article was found on the page.", comment: "Reader view error")
			}
		}
	}

	/// Keeps Readability’s globals away from anything else that runs in the web view.
	private let contentWorld = WKContentWorld.world(name: "NetNewsWireReadability")

	private lazy var readabilitySource: String? = {
		guard let url = Bundle.main.url(forResource: "Readability", withExtension: "js") else {
			return nil
		}
		return try? String(contentsOf: url, encoding: .utf8)
	}()

	private lazy var webView: WKWebView = {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = false
		return WKWebView(frame: .zero, configuration: configuration)
	}()

	func extract(url: URL) async throws -> ExtractedArticle {
		let (html, finalURL) = try await downloadHTML(url)
		return try await extract(html: html, url: finalURL)
	}

	/// Runs Readability on `html`. Relative links and images resolve against `url`.
	func extract(html: String, url: URL) async throws -> ExtractedArticle {
		guard let readabilitySource else {
			throw ExtractionError.missingReadabilityScript
		}

		let script = readabilitySource + "\n" + Self.parseScript
		let result = try await webView.callAsyncJavaScript(script, arguments: ["html": html, "baseURL": url.absoluteString], in: nil, contentWorld: contentWorld)

		guard let article = result as? [String: Any], let content = article["content"] as? String, !content.isEmpty else {
			throw ExtractionError.noArticle
		}

		return ExtractedArticle(
			title: Self.nonEmptyString(article["title"]),
			author: Self.nonEmptyString(article["byline"]),
			datePublished: Self.nonEmptyString(article["publishedTime"]),
			dek: nil,
			leadImageURL: nil,
			content: content,
			nextPageURL: nil,
			url: url.absoluteString,
			domain: url.host(),
			excerpt: Self.nonEmptyString(article["excerpt"]),
			wordCount: nil,
			direction: Self.nonEmptyString(article["dir"]),
			totalPages: nil,
			renderedPages: nil
		)
	}
}

private extension ReadabilityExtractor {

	/// Parses the HTML into a detached document, so nothing on the page loads or runs, and gives
	/// it a <base> so Readability can make relative URLs absolute. Returns nil when there’s no article.
	static let parseScript = """
	const doc = new DOMParser().parseFromString(html, "text/html");
	let base = doc.querySelector("base[href]");
	if (base) {
		base.setAttribute("href", new URL(base.getAttribute("href"), baseURL).href);
	} else {
		base = doc.createElement("base");
		base.setAttribute("href", baseURL);
		(doc.head || doc.documentElement).prepend(base);
	}
	const article = new Readability(doc).parse();
	if (!article) {
		return null;
	}
	return {
		title: article.title,
		byline: article.byline,
		content: article.content,
		excerpt: article.excerpt,
		dir: article.dir,
		publishedTime: article.publishedTime
	};
	"""

	func downloadHTML(_ url: URL) async throws -> (html: String, finalURL: URL) {
		let response = try await Downloader.shared.download(url, userAgentStyle: .browser)

		if let httpResponse = response.response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
			throw ExtractionError.downloadFailed(statusCode: httpResponse.statusCode)
		}
		if let mimeType = response.response?.mimeType?.lowercased(), !mimeType.contains("html") {
			throw ExtractionError.notHTML
		}
		guard let data = response.data, let html = Self.decodeHTML(data, textEncodingName: response.response?.textEncodingName) else {
			throw ExtractionError.undecodableHTML
		}

		return (html, response.response?.url ?? url)
	}

	static func nonEmptyString(_ value: Any?) -> String? {
		guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
			return nil
		}
		return string
	}
}

// MARK: - Decoding

extension ReadabilityExtractor {

	/// Uses the charset from the HTTP header, then a <meta> charset, then UTF-8, then Latin-1.
	static func decodeHTML(_ data: Data, textEncodingName: String?) -> String? {
		let charsetName = textEncodingName ?? metaCharset(in: data)
		if let charsetName, let encoding = encoding(forCharset: charsetName), let html = String(data: data, encoding: encoding) {
			return html
		}
		return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
	}

	static func encoding(forCharset name: String) -> String.Encoding? {
		let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
		guard cfEncoding != kCFStringEncodingInvalidId else {
			return nil
		}
		return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
	}

	/// Finds `<meta charset="…">` or `<meta http-equiv="Content-Type" content="…; charset=…">` near the start.
	static func metaCharset(in data: Data) -> String? {
		let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
		guard let charsetRange = head.range(of: "charset=") else {
			return nil
		}
		let rest = head[charsetRange.upperBound...].drop { $0 == "\"" || $0 == "'" || $0 == " " }
		let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
		return name.isEmpty ? nil : String(name)
	}
}
