//
//  FeatureExtractor.swift
//  Suggestions
//
//  Created by Simon on 10/19/26.
//

import Foundation
import NaturalLanguage

struct SparseFeature: Sendable, Equatable {
	let index: Int
	let value: Float
}

/// Turns a `SuggestionInput` into a sparse, hashed feature vector.
///
/// Feature hashing keeps the model a fixed size no matter how many feeds,
/// words, or authors it sees. The hash must be stable across launches,
/// so it uses FNV-1a rather than `Hasher`.
struct FeatureExtractor {

	static let dimension = 1 << 18

	/// Bump when the features change, so saved models are discarded.
	static let version: UInt32 = 1

	private let tokenizer = NLTokenizer(unit: .word)

	func features(for input: SuggestionInput) -> [SparseFeature] {
		var values = [Int: Float]()

		func add(_ name: String, _ value: Float = 1) {
			values[Self.index(for: name), default: 0] += value
		}

		add("bias")
		add("feed:\(input.feedID)")

		let tokens = titleTokens(input.title)
		if !tokens.isEmpty {
			let tokenWeight = 1 / Float(tokens.count).squareRoot()
			for token in tokens {
				add("word:\(token)", tokenWeight)
			}
			for (first, second) in zip(tokens, tokens.dropFirst()) {
				add("bigram:\(first) \(second)", tokenWeight)
			}
		}

		for author in input.authors {
			let name = author.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
			if !name.isEmpty {
				add("author:\(name)")
			}
		}

		if input.hasImage {
			add("hasImage")
		}
		add("length:\(Self.lengthBucket(input.textLength))")

		if let datePublished = input.datePublished {
			let hour = Calendar.current.component(.hour, from: datePublished)
			add("hour:\(hour / 3)")
		}

		return values
			.map { SparseFeature(index: $0.key, value: $0.value) }
			.sorted { $0.index < $1.index }
	}

	func titleTokens(_ title: String) -> [String] {
		let text = title.lowercased()
		tokenizer.string = text

		var tokens = [String]()
		tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
			let token = String(text[range])
			if token.count >= 3 && !Self.stopwords.contains(token) {
				tokens.append(token)
			}
			return true
		}
		return tokens
	}

	static func index(for name: String) -> Int {
		Int(fnv1a(name) % UInt64(dimension))
	}

	static func fnv1a(_ string: String) -> UInt64 {
		var hash: UInt64 = 0xcbf29ce484222325
		for byte in string.utf8 {
			hash ^= UInt64(byte)
			hash = hash &* 0x100000001b3
		}
		return hash
	}
}

private extension FeatureExtractor {

	static func lengthBucket(_ length: Int) -> Int {
		switch length {
		case 0:
			0
		case ..<500:
			1
		case ..<2000:
			2
		case ..<5000:
			3
		default:
			4
		}
	}

	static let stopwords: Set<String> = [
		// English
		"the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out", "has", "his", "how", "its", "may", "new", "now", "see", "who", "why", "did", "get", "use", "with", "this", "that", "from", "they", "will", "what", "when", "your", "about", "into", "than", "then", "them", "these", "those", "there", "their", "would", "could", "should", "been", "have", "more", "most", "some", "such", "just", "also", "over", "only", "very", "after", "before", "here", "which", "while", "where",
		// Hungarian
		"egy", "hogy", "nem", "meg", "van", "már", "csak", "még", "mint", "után", "által", "volt", "lesz", "ezt", "azt", "egyik", "vagy", "pedig", "mert", "akkor", "mit", "miért", "hol", "kell", "lett", "lehet"
	]
}
