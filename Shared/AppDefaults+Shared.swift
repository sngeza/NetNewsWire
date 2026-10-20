//
//  AppDefaults+Shared.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 10/6/26.
//

import Foundation

private extension AppDefaults.Key {
	static let unreadCountDisplay = "unreadCountDisplay"
	static let showSuggestions = "showSuggestions"
	static let syncSuggestionsWithiCloud = "syncSuggestionsWithiCloud"
}

extension AppDefaults {

	var unreadCountDisplay: UnreadCountDisplay {
		get {
			UnreadCountDisplay(rawValue: UserDefaults.standard.integer(forKey: Key.unreadCountDisplay)) ?? .count
		}
		set {
			UserDefaults.standard.set(newValue.rawValue, forKey: Key.unreadCountDisplay)
			NotificationCenter.default.post(name: .unreadCountDisplaySettingDidChange, object: self)
		}
	}

	/// Whether to log reading history and show suggested articles in the timeline. On by default.
	var showSuggestions: Bool {
		get {
			UserDefaults.standard.object(forKey: Key.showSuggestions) as? Bool ?? true
		}
		set {
			UserDefaults.standard.set(newValue, forKey: Key.showSuggestions)
			NotificationCenter.default.post(name: .suggestionsSettingDidChange, object: self)
		}
	}

	/// Whether suggestion history syncs through the person’s iCloud account. On by default.
	/// Independent of whether an iCloud feeds account is set up.
	var syncSuggestionsWithiCloud: Bool {
		get {
			UserDefaults.standard.object(forKey: Key.syncSuggestionsWithiCloud) as? Bool ?? true
		}
		set {
			UserDefaults.standard.set(newValue, forKey: Key.syncSuggestionsWithiCloud)
			NotificationCenter.default.post(name: .suggestionsSyncSettingDidChange, object: self)
		}
	}
}
