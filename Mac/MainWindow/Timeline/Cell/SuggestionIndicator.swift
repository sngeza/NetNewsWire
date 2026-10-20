//
//  SuggestionIndicator.swift
//  NetNewsWire
//
//  Created by Simon on 10/19/26.
//

import AppKit

/// Drawing helpers for the “suggested for you” mark in the timeline.
@MainActor enum SuggestionIndicator {

	static let dimension: CGFloat = 11.0

	static let color = NSColor.systemOrange

	static let image: NSImage? = {
		let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
		return NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
	}()

	/// Higher scores are drawn more strongly.
	static func alpha(for score: Float) -> CGFloat {
		let threshold = SuggestionsManager.displayThreshold
		guard score >= threshold else {
			return 0
		}
		let fraction = (score - threshold) / (1 - threshold)
		return CGFloat(0.4 + 0.6 * min(max(fraction, 0), 1))
	}

	static func label(for score: Float) -> String {
		let format = NSLocalizedString("Suggested for you (%d%%)", comment: "Timeline suggestion indicator: percent likelihood of opening the article")
		return String(format: format, Int((score * 100).rounded()))
	}

	/// The mark followed by a space, for the start of a single line of text.
	static func attributedPrefix(score: Float, font: NSFont) -> NSAttributedString {
		guard let image else {
			return NSAttributedString()
		}

		let tintedColor = color.withAlphaComponent(alpha(for: score))
		let tinted = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tintedColor])) ?? image

		let attachment = NSTextAttachment()
		attachment.image = tinted
		let y = (font.capHeight - tinted.size.height) / 2
		attachment.bounds = NSRect(x: 0, y: y, width: tinted.size.width, height: tinted.size.height)

		let prefix = NSMutableAttributedString(attachment: attachment)
		prefix.append(NSAttributedString(string: " ", attributes: [.font: font]))
		return prefix
	}
}
