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
	// Optional so registries created by Feather 3.0 remain decodable.
	var installedBuildVersion: String? = nil
	var appName: String?
	var sourceRepositoryURL: URL
	var sourceRepositoryIdentifier: String?
	var sourceRepositoryName: String?
	var sourceAppIdentifier: String
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
			sourceAppBuildVersion: installedBuildVersion,
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

		let installedBuildVersion = SourceAppProvenance.buildVersion(
			fromSourceVersionID: metadata?.sourceVersionID
		) ?? fallbackProvenance?.sourceAppBuildVersion
		
		return _upsert(
			localBundleIdentifier: localBundleIdentifier,
			installedVersion: installedVersion,
			installedBuildVersion: installedBuildVersion,
			appName: metadata?.sourceAppName ?? fallbackProvenance?.sourceAppName ?? app.name,
			sourceRepositoryURL: sourceRepositoryURL,
			sourceRepositoryIdentifier: metadata?.sourceRepositoryIdentifier ?? fallbackProvenance?.sourceRepositoryIdentifier,
			sourceRepositoryName: metadata?.sourceRepositoryName ?? fallbackProvenance?.sourceRepositoryName,
			sourceAppIdentifier: sourceAppIdentifier,
			sourceAppVersionDate: metadata?.sourceAppVersionDate ?? fallbackProvenance?.sourceAppVersionDate,
			sourceAppDownloadURL: metadata?.sourceAppDownloadURL ?? fallbackProvenance?.sourceAppDownloadURL
		)
	}
	
	@discardableResult
	func recordManualInstallation(
		localBundleIdentifier: String,
		installedVersion: String,
		provenance: SourceAppProvenance
	) -> Bool {
		let bundleIdentifier = localBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
		let version = installedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !bundleIdentifier.isEmpty, !version.isEmpty else {
			return false
		}
		
		return _upsert(
			localBundleIdentifier: bundleIdentifier,
			installedVersion: version,
			installedBuildVersion: provenance.sourceAppBuildVersion,
			appName: provenance.sourceAppName,
			sourceRepositoryURL: provenance.sourceRepositoryURL,
			sourceRepositoryIdentifier: provenance.sourceRepositoryIdentifier,
			sourceRepositoryName: provenance.sourceRepositoryName,
			sourceAppIdentifier: provenance.sourceAppIdentifier,
			sourceAppVersionDate: provenance.sourceAppVersionDate,
			sourceAppDownloadURL: provenance.sourceAppDownloadURL
		)
	}
	
	@discardableResult
	func updateInstalledVersion(
		recordID: String,
		version: String,
		buildVersion: String? = nil
	) -> Bool {
		let normalizedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
		guard
			!normalizedVersion.isEmpty,
			let index = records.firstIndex(where: { $0.id == recordID })
		else {
			return false
		}
		
		records[index].installedVersion = normalizedVersion
		records[index].installedBuildVersion = buildVersion
		records[index].updatedAt = Date()
		records[index].ignoredRemoteVersion = nil
		_save()
		return true
	}
	
	@discardableResult
	func remove(recordID: String) -> Bool {
		let previousCount = records.count
		records.removeAll { $0.id == recordID }
		guard records.count != previousCount else {
			return false
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
		records = _canonicalized(restoredRecords)
		_save(notifyBackup: false)
	}
	
	func reset() {
		records.removeAll()
		try? _fileManager.removeItem(at: _fileURL)
		NotificationCenter.default.post(name: .featherInstallationRegistryChanged, object: nil)
	}
	
	@discardableResult
	private func _upsert(
		localBundleIdentifier: String,
		installedVersion: String,
		installedBuildVersion: String?,
		appName: String?,
		sourceRepositoryURL: URL,
		sourceRepositoryIdentifier: String?,
		sourceRepositoryName: String?,
		sourceAppIdentifier: String,
		sourceAppVersionDate: Date?,
		sourceAppDownloadURL: URL?
	) -> Bool {
		let now = Date()
		let matchingRecordIDs = records
			.filter { $0.localBundleIdentifier == localBundleIdentifier }
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
			records[index].installedBuildVersion = installedBuildVersion
			records[index].appName = appName
			records[index].sourceRepositoryURL = sourceRepositoryURL
			records[index].sourceRepositoryIdentifier = sourceRepositoryIdentifier
			records[index].sourceRepositoryName = sourceRepositoryName
			records[index].sourceAppIdentifier = sourceAppIdentifier
			records[index].sourceAppVersionDate = sourceAppVersionDate
			records[index].sourceAppDownloadURL = sourceAppDownloadURL
			records[index].installedAt = now
			records[index].updatedAt = now
			records[index].ignoredRemoteVersion = nil
		} else {
			records.append(
				InstalledSourceAppRecord(
					id: UUID().uuidString,
					localBundleIdentifier: localBundleIdentifier,
					installedVersion: installedVersion,
					installedBuildVersion: installedBuildVersion,
					appName: appName,
					sourceRepositoryURL: sourceRepositoryURL,
					sourceRepositoryIdentifier: sourceRepositoryIdentifier,
					sourceRepositoryName: sourceRepositoryName,
					sourceAppIdentifier: sourceAppIdentifier,
					sourceAppVersionDate: sourceAppVersionDate,
					sourceAppDownloadURL: sourceAppDownloadURL,
					installedAt: now,
					updatedAt: now
				)
			)
		}
		
		_save()
		return true
	}
	
	private func _canonicalized(_ input: [InstalledSourceAppRecord]) -> [InstalledSourceAppRecord] {
		var canonical: [String: InstalledSourceAppRecord] = [:]
		for record in input {
			guard let current = canonical[record.localBundleIdentifier] else {
				canonical[record.localBundleIdentifier] = record
				continue
			}
			if record.updatedAt > current.updatedAt {
				canonical[record.localBundleIdentifier] = record
			}
		}
		return Array(canonical.values)
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
		
		records = _canonicalized(decoded)
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
