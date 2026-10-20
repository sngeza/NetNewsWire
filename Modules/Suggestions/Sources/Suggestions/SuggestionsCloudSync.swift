//
//  SuggestionsCloudSync.swift
//  Suggestions
//
//  Created by Simon on 10/19/26.
//

import Foundation
import CloudKit
import CloudKitSync
import os

/// Syncs suggestion history through the person’s private iCloud database, in its own zone.
///
/// Each device uploads a summary of its own history per article and downloads the others’.
/// Every device trains on the combined history.
@MainActor public final class SuggestionsCloudSync {

	public typealias ModelDidChange = @MainActor @Sendable () -> Void

	private let container: CKContainer
	private let zone: SuggestionsZone
	private let zoneDelegate: SuggestionsZoneDelegate
	private let engine: SuggestionEngine
	private let modelDidChange: ModelDidChange

	private var isSyncing = false
	private var needsSync = false
	private var didSubscribe = false

	/// Records saved or deleted per request. CloudKit splits larger requests itself if needed.
	private static let uploadBatchSize = 200

	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Suggestions", category: "SuggestionsCloudSync")

	public init(containerIdentifier: String, engine: SuggestionEngine, modelDidChange: @escaping ModelDidChange) {
		self.container = CKContainer(identifier: containerIdentifier)
		self.zone = SuggestionsZone(container: container)
		self.zoneDelegate = SuggestionsZoneDelegate(engine: engine)
		self.engine = engine
		self.modelDidChange = modelDidChange
		zone.delegate = zoneDelegate
	}

	/// Downloads other devices’ changes, then uploads this device’s.
	/// Calls made while a sync is running are coalesced into one more sync afterward.
	public func sync() async {
		if isSyncing {
			needsSync = true
			return
		}
		isSyncing = true
		defer {
			isSyncing = false
		}

		repeat {
			needsSync = false
			await performSync()
		} while needsSync
	}

	public func receiveRemoteNotification(userInfo: [AnyHashable: Any]) async {
		guard CKRecordZoneNotification(fromRemoteNotificationDictionary: userInfo)?.recordZoneID?.zoneName == SuggestionRecords.zoneName else {
			return
		}
		await sync()
	}

	/// Deletes the history in iCloud and on this device, and tells other devices to forget theirs.
	///
	/// Other devices forget everything first seen before now the next time they sync.
	public func resetEverywhere() async {
		let resetDate = Date()
		await engine.reset(date: resetDate)

		guard await isAccountAvailable(), let database = zone.database else {
			// Other devices will still have their history. Without iCloud there’s no way to reach them.
			return
		}

		do {
			_ = try await database.deleteRecordZone(withID: zone.zoneID)
		} catch let error as CKError where error.code == .zoneNotFound {
			// Nothing to delete.
		} catch {
			Self.logger.error("Suggestions: could not delete iCloud zone: \(error.localizedDescription)")
		}
		zone.resetChangeToken()
		// Deleting the zone deleted its subscription, which every device shares.
		didSubscribe = false

		do {
			try await zone.createZoneRecord()
			try await zone.save([SuggestionRecords.resetRecord(date: resetDate, zoneID: zone.zoneID)])
			try await zone.subscribeToZoneChanges()
			didSubscribe = true
		} catch {
			Self.logger.error("Suggestions: could not save reset to iCloud: \(error.localizedDescription)")
		}
	}
}

private extension SuggestionsCloudSync {

	func performSync() async {
		guard await isAccountAvailable() else {
			return
		}

		zoneDelegate.didChangeHistory = false
		do {
			try await zone.fetchChangesInZone()
		} catch CloudKitZoneError.userDeletedZone {
			// Deleted from iCloud settings. Start over in a new zone; local history is kept and re-uploaded.
			zone.resetChangeToken()
			try? await zone.createZoneRecord()
		} catch {
			Self.logger.error("Suggestions: could not fetch iCloud changes: \(error.localizedDescription)")
		}

		if zoneDelegate.didChangeHistory {
			await engine.retrain()
			modelDidChange()
		}

		// After fetching, which creates the zone if it doesn’t exist yet. A subscription needs the zone.
		if !didSubscribe {
			do {
				try await zone.subscribeToZoneChanges()
				didSubscribe = true
			} catch {
				Self.logger.error("Suggestions: could not subscribe to iCloud changes: \(error.localizedDescription)")
			}
		}

		await upload()
	}

	func upload() async {
		let deviceID = await engine.deviceID

		while true {
			let pending = await engine.pendingUploads(limit: Self.uploadBatchSize)
			guard !pending.dirtyArticleIDs.isEmpty || !pending.deletedArticleIDs.isEmpty else {
				return
			}

			let records = pending.summaries.map { SuggestionRecords.record(for: $0, zoneID: zone.zoneID) }
			do {
				try await zone.save(records)
			} catch {
				Self.logger.error("Suggestions: could not upload history: \(error.localizedDescription)")
				return
			}

			let recordIDsToDelete = pending.deletedArticleIDs.map {
				CKRecord.ID(recordName: SuggestionRecords.recordName(deviceID: deviceID, articleID: $0), zoneID: zone.zoneID)
			}
			if !recordIDsToDelete.isEmpty {
				do {
					try await zone.delete(recordIDs: recordIDsToDelete)
				} catch where Self.isTransient(error) {
					Self.logger.error("Suggestions: could not delete old history from iCloud: \(error.localizedDescription)")
					return
				} catch {
					// Usually records that were never uploaded. Not worth retrying.
					Self.logger.info("Suggestions: skipped deleting old history from iCloud: \(error.localizedDescription)")
				}
			}

			await engine.didUpload(dirtyArticleIDs: pending.dirtyArticleIDs, deletedArticleIDs: pending.deletedArticleIDs)
		}
	}

	func isAccountAvailable() async -> Bool {
		do {
			return try await container.accountStatus() == .available
		} catch {
			Self.logger.error("Suggestions: could not get iCloud account status: \(error.localizedDescription)")
			return false
		}
	}

	static func isTransient(_ error: Error) -> Bool {
		let underlyingError = (error as? CloudKitError)?.error ?? error
		guard let ckError = underlyingError as? CKError else {
			return false
		}
		switch ckError.code {
		case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .notAuthenticated, .accountTemporarilyUnavailable, .quotaExceeded:
			return true
		default:
			return false
		}
	}
}

// MARK: - Zone

@MainActor final class SuggestionsZone: CloudKitZone {

	let zoneID = CKRecordZone.ID(zoneName: SuggestionRecords.zoneName, ownerName: CKCurrentUserDefaultName)

	// Owned by SuggestionsCloudSync.
	weak var container: CKContainer?
	weak var database: CKDatabase?
	var delegate: CloudKitZoneDelegate?
	var fetchChangesPageHandler: CloudKitZoneFetchPageHandler?

	init(container: CKContainer) {
		self.container = container
		self.database = container.privateCloudDatabase
	}
}

/// Applies each page of downloaded changes to the local history.
final class SuggestionsZoneDelegate: CloudKitZoneDelegate {

	private let engine: SuggestionEngine

	/// Set when a page changes the history, so the sync retrains once at the end.
	@MainActor var didChangeHistory = false

	init(engine: SuggestionEngine) {
		self.engine = engine
	}

	@MainActor func cloudKitDidModify(changed: [CKRecord], deleted: [CloudKitRecordKey]) async throws {
		var summaries = [SuggestionSummary]()
		var resetDate: Date?
		for record in changed {
			if let date = SuggestionRecords.resetDate(from: record) {
				resetDate = max(resetDate ?? date, date)
			} else if let summary = SuggestionRecords.summary(from: record) {
				summaries.append(summary)
			}
		}

		let deletedSummaries = deleted.compactMap { key in
			key.recordType == SuggestionRecords.Summary.recordType ? SuggestionRecords.deviceAndArticleID(fromRecordName: key.recordID.recordName) : nil
		}

		// A reset applies first, so summaries from before it in the same page are dropped.
		var didChange = false
		if let resetDate, await engine.applyReset(date: resetDate) {
			didChange = true
		}
		if await engine.applyRemoteChanges(changed: summaries, deleted: deletedSummaries) {
			didChange = true
		}
		if didChange {
			didChangeHistory = true
		}
	}
}
