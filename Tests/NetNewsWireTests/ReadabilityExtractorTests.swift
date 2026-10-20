//
//  ReadabilityExtractorTests.swift
//  NetNewsWireTests
//
//  Created by Simon on 10/20/26.
//

import Foundation
import Testing

@testable import NetNewsWire

/// Tests for on-device reader view extraction with Readability.js.
@MainActor @Suite struct ReadabilityExtractorTests {

	private let pageURL = URL(string: "https://example.com/blog/2026/10/post.html")!

	private func articleHTML(head: String = "") -> String {
		let paragraph = "<p>Reader view should keep this paragraph, which is long enough for Readability to treat the text around it as the main content of the page, with commas, and more words.</p>"
		return """
		<!doctype html>
		<html lang="en">
		<head><title>A Long Post — Example Blog</title>\(head)</head>
		<body>
		<nav><a href="/">Home</a> <a href="/about">About</a></nav>
		<article>
		<h1>A Long Post</h1>
		<p class="byline">By Jane Writer</p>
		\(String(repeating: paragraph, count: 8))
		<p><img src="images/photo.jpg" alt="Photo"> <a href="../other.html">Related</a></p>
		</article>
		<footer>Copyright Example Blog</footer>
		<script>document.body.innerHTML = "page scripts must not run";</script>
		</body>
		</html>
		"""
	}

	@Test func extractsArticle() async throws {
		let article = try await ReadabilityExtractor.shared.extract(html: articleHTML(), url: pageURL)
		let content = try #require(article.content)

		#expect(content.contains("Reader view should keep this paragraph"))
		#expect(!content.contains("Copyright Example Blog"))
		#expect(!content.contains("page scripts must not run"))
		#expect(article.title?.contains("A Long Post") == true)
		#expect(article.url == pageURL.absoluteString)
		#expect(article.domain == "example.com")
	}

	@Test func makesRelativeURLsAbsolute() async throws {
		let article = try await ReadabilityExtractor.shared.extract(html: articleHTML(), url: pageURL)
		let content = try #require(article.content)

		#expect(content.contains("https://example.com/blog/2026/10/images/photo.jpg"))
		#expect(content.contains("https://example.com/blog/2026/other.html"))
	}

	@Test func honorsPageBaseElement() async throws {
		let html = articleHTML(head: "<base href=\"/static/\">")
		let article = try await ReadabilityExtractor.shared.extract(html: html, url: pageURL)
		let content = try #require(article.content)

		#expect(content.contains("https://example.com/static/images/photo.jpg"))
	}

	@Test func pageWithoutArticleFails() async {
		let html = "<html><head><title>Empty</title></head><body></body></html>"
		await #expect(throws: ReadabilityExtractor.ExtractionError.self) {
			try await ReadabilityExtractor.shared.extract(html: html, url: pageURL)
		}
	}

	@Test func decodesCharsets() throws {
		let windows1252 = try #require("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1252\"><p>café</p>".data(using: .windowsCP1252))
		#expect(ReadabilityExtractor.decodeHTML(windows1252, textEncodingName: nil)?.contains("café") == true)

		let utf8 = try #require("<p>naïve ✦</p>".data(using: .utf8))
		#expect(ReadabilityExtractor.decodeHTML(utf8, textEncodingName: nil)?.contains("naïve ✦") == true)
		#expect(ReadabilityExtractor.decodeHTML(utf8, textEncodingName: "utf-8")?.contains("✦") == true)

		#expect(ReadabilityExtractor.metaCharset(in: Data("<meta charset='Shift_JIS'>".utf8)) == "shift_jis")
	}
}
