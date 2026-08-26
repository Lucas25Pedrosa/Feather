//
//  InstallationRegistry.swift
//  Feather
//
//  Persistent source-linked installation history for Updates.
//

import Foundation
import Combine

extension Notification.Name {
	static let featherInstallationRegistryChanged = Notification.Name("Feather.installationRegistryChanged")
}

struct InstalledSourceAppRecord: Codable, Equatable, Identifiable {
	let id: String
	let localBundleIdentifier: String
	var installedVersion: String
	var appName: String?
	let sourceRepositoryURL: URL
	var sourceRepositoryIdentifier: String?
	var sourceRepositoryName: String?
	let sourceAppIdentifier: String
	var sourceAppVersionDate: Date?
	var sourceAppDownloadURL: URL?
	var installedAt: Date
	var updatedAt: Date
	
	// Optional so registries created by older Feather builds remain decodable.
	var ignoredRemoteVersion: String? = nil
	var updatesDisabled: Bool? = nil
	
	var sourceProvenance: SourceAppProvenance {
		SourceAppProvenance(
			sourceRepositoryURL: sourceRepositoryURL,
			sourceRepositoryIdentifier: sourceRepositoryIdentifier,
			sourceRepositoryName: sourceRepositoryName,
			sourceAppIdentifier: sourceAppIdentifier,
			sourceAppName: appName,
			sourceAppVersion: installedVersion,
			sourceAppVersionDate: sourceAppVersionDate,
			sourceAppDownloadURL: sourceAppDownloadURL
		)
	}
	
	var hasHiddenUpdates: Bool {
		updatesDisabled == true || ignoredRemoteVersion != nil
	}
}

final class InstallationRegistry: ObservableObject {
	static let shared = InstallationRegistry()
	
	private let _fileManager = FileManager.default
	private let _fileURL: URL
	@Published private(set) var records: [InstalledSourceAppRecord] = []
	
	private init() {
		let applicationSupport = _fileManager.urls(
			for: .applicationSupportDirectory,
			in: .userDomainMask
		).first!
		let directory = applicationSupport
			.appendingPathComponent("Feather", isDirectory: true)
		
		try? _fileManager.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		
		_fileURL = directory.appendingPathComponent(
			"InstalledSourceApps.json",
			isDirectory: false
		)
		
		_load()
	}
	
	var hiddenRecords: [InstalledSourceAppRecord] {
		records
			.filter(\.hasHiddenUpdates)
			.sorted {
				($0.appName ?? $0.localBundleIdentifier)
					.localizedCaseInsensitiveCompare($1.appName ?? $1.localBundleIdentifier)
					== .orderedAscending
			}
	}
	
	@discardableResult
	func recordInstallation(
		of app: AppInfoPresentable,
		fallbackProvenance: SourceAppProvenance? = nil
	) -> Bool {
		guard
			let localBundleIdentifier = app.identifier,
			!localBundleIdentifier.isEmpty
		else {
			return false
		}
		
		let metadata = app.uuid.flatMap { Storage.shared.sourceMetadata(for: $0) }
		
		guard
			let sourceRepositoryURL = metadata?.sourceRepositoryURL ?? fallbackProvenance?.sourceRepositoryURL,
			let sourceAppIdentifier = metadata?.sourceAppIdentifier ?? fallbackProvenance?.sourceAppIdentifier
		else {
			return false
		}
		
		// For source-linked installs, provenance describes the IPA that was actually
		// downloaded and signed. Prefer that over AppInfoPresentable.version because
		// Core Data / view state may still expose the previous version immediately
		// after an update finishes installing.
		let installedVersion: String
		if let metadataVersion = metadata?.sourceAppVersion, !metadataVersion.isEmpty {
			installedVersion = metadataVersion
		} else if let fallbackVersion = fallbackProvenance?.sourceAppVersion, !fallbackVersion.isEmpty {
			installedVersion = fallbackVersion
		} else if let appVersion = app.version, !appVersion.isEmpty {
			installedVersion = appVersion
		} else {
			return false
		}
		
		let now = Date()
		let matchingRecordIDs = records
			.filter {
				_matchesIdentity(
					$0,
					sourceRepositoryURL: sourceRepositoryURL,
					sourceAppIdentifier: sourceAppIdentifier,
					localBundleIdentifier: localBundleIdentifier
				)
			}
			.sorted { $0.updatedAt > $1.updatedAt }
			.map(\.id)
		
		if let canonicalID = matchingRecordIDs.first {
			records.removeAll { record in
				matchingRecordIDs.dropFirst().contains(record.id)
			}
			
			guard let index = records.firstIndex(where: { $0.id == canonicalID }) else {
				return false
			}
			
			records[index].installedVersion = installedVersion
			records[index].appName = metadata?.sourceAppName ?? fallbackProvenance?.sourceAppName ?? app.name
			records[index].sourceRepositoryIdentifier = metadata?.sourceRepositoryIdentifier ?? fallbackProvenance?.sourceRepositoryIdentifier
			records[index].sourceRepositoryName = metadata?.sourceRepositoryName ?? fallbackProvenance?.sourceRepositoryName
			records[index].sourceAppVersionDate = metadata?.sourceAppVersionDate ?? fallbackProvenance?.sourceAppVersionDate
			records[index].sourceAppDownloadURL = metadata?.sourceAppDownloadURL ?? fallbackProvenance?.sourceAppDownloadURL
			records[index].installedAt = now
			records[index].updatedAt = now
			
			if let ignoredVersion = records[index].ignoredRemoteVersion {
				let comparison = installedVersion.compare(
					ignoredVersion,
					options: [.numeric, .caseInsensitive]
				)
				if comparison != .orderedAscending {
					records[index].ignoredRemoteVersion = nil
				}
			}
		} else {
			records.append(
				InstalledSourceAppRecord(
					id: UUID().uuidString,
					localBundleIdentifier: localBundleIdentifier,
					installedVersion: installedVersion,
					appName: metadata?.sourceAppName ?? fallbackProvenance?.sourceAppName ?? app.name,
					sourceRepositoryURL: sourceRepositoryURL,
					sourceRepositoryIdentifier: metadata?.sourceRepositoryIdentifier ?? fallbackProvenance?.sourceRepositoryIdentifier,
					sourceRepositoryName: metadata?.sourceRepositoryName ?? fallbackProvenance?.sourceRepositoryName,
					sourceAppIdentifier: sourceAppIdentifier,
					sourceAppVersionDate: metadata?.sourceAppVersionDate ?? fallbackProvenance?.sourceAppVersionDate,
					sourceAppDownloadURL: metadata?.sourceAppDownloadURL ?? fallbackProvenance?.sourceAppDownloadURL,
					installedAt: now,
					updatedAt: now
				)
			)
		}
		
		_save()
		return true
	}
	
	@discardableResult
	func ignoreUpdate(recordID: String, remoteVersion: String) -> Bool {
		guard let index = records.firstIndex(where: { $0.id == recordID }) else {
			return false
		}
		
		records[index].ignoredRemoteVersion = remoteVersion
		records[index].updatedAt = Date()
		_save()
		return true
	}
	
	@discardableResult
	func disableUpdates(recordID: String) -> Bool {
		guard let index = records.firstIndex(where: { $0.id == recordID }) else {
			return false
		}
		
		records[index].updatesDisabled = true
		records[index].ignoredRemoteVersion = nil
		records[index].updatedAt = Date()
		_save()
		return true
	}
	
	@discardableResult
	func showUpdates(recordID: String) -> Bool {
		guard let index = records.firstIndex(where: { $0.id == recordID }) else {
			return false
		}
		
		records[index].updatesDisabled = nil
		records[index].ignoredRemoteVersion = nil
		records[index].updatedAt = Date()
		_save()
		return true
	}
	
	func clearStaleIgnoredVersion(recordID: String, currentRemoteVersion: String) {
		guard
			let index = records.firstIndex(where: { $0.id == recordID }),
			let ignoredVersion = records[index].ignoredRemoteVersion,
			ignoredVersion != currentRemoteVersion
		else {
			return
		}
		
		records[index].ignoredRemoteVersion = nil
		records[index].updatedAt = Date()
		_save()
	}
	
	func restoreBackupRecords(_ restoredRecords: [InstalledSourceAppRecord]) {
		records = restoredRecords
		_save(notifyBackup: false)
	}
	
	func reset() {
		records.removeAll()
		try? _fileManager.removeItem(at: _fileURL)
		NotificationCenter.default.post(name: .featherInstallationRegistryChanged, object: nil)
	}
	
	private func _matchesIdentity(
		_ record: InstalledSourceAppRecord,
		sourceRepositoryURL: URL,
		sourceAppIdentifier: String,
		localBundleIdentifier: String
	) -> Bool {
		_normalizedSourceURL(record.sourceRepositoryURL)
			== _normalizedSourceURL(sourceRepositoryURL)
			&& record.sourceAppIdentifier == sourceAppIdentifier
			&& record.localBundleIdentifier == localBundleIdentifier
	}
	
	private func _normalizedSourceURL(_ url: URL) -> String {
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		let scheme = components?.scheme?.lowercased()
		let host = components?.host?.lowercased()
		components?.scheme = scheme
		components?.host = host
		components?.fragment = nil
		
		let normalized = components?.url ?? url
		let value = normalized.absoluteString
		return value.hasSuffix("/") ? String(value.dropLast()) : value
	}
	
	private func _load() {
		guard
			let data = try? Data(contentsOf: _fileURL),
			let decoded = try? JSONDecoder().decode(
				[InstalledSourceAppRecord].self,
				from: data
			)
		else {
			return
		}
		
		records = decoded
	}
	
	private func _save(notifyBackup: Bool = true) {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		
		guard let data = try? encoder.encode(records) else {
			return
		}
		
		do {
			try data.write(to: _fileURL, options: .atomic)
			if notifyBackup {
				NotificationCenter.default.post(name: .featherInstallationRegistryChanged, object: nil)
			}
		} catch {
			return
		}
	}
}
