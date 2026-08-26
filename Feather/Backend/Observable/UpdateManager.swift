//
//  UpdateManager.swift
//  Feather
//
//  Created by Dominic on 24.05.2026.
//

import AltSourceKit
import Foundation
import NimbleJSON

struct AppUpdate: Identifiable, Equatable {
	let id: String
	let localUUID: String
	let localVersion: String?
	let remoteVersion: String
	let appName: String
	let bundleIdentifier: String
	let localBundleIdentifier: String
	let iconURL: URL?
	let downloadURL: URL
	let sourceURL: URL
	let sourceProvenance: SourceAppProvenance
}

@MainActor
final class UpdateManager: ObservableObject {
	static let shared = UpdateManager()
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	@Published private(set) var updates: [String: AppUpdate] = [:]
	@Published private(set) var isChecking = false
	@Published private(set) var lastCheckedDate: Date?
	
	private let _dataService = NBFetchService()
	
	private init() {}
	
	var availableUpdates: [AppUpdate] {
		updates.values.sorted {
			$0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
		}
	}
	
	func update(for app: AppInfoPresentable) -> AppUpdate? {
		guard let candidate = _candidateUpdate(for: app) else { return nil }
		
		// A freshly downloaded update is already the remote version. In that case
		// Library should offer Sign/Install instead of downloading the same IPA again.
		if let appVersion = app.version, !appVersion.isEmpty {
			let comparison = appVersion.compare(
				candidate.remoteVersion,
				options: [.numeric, .caseInsensitive]
			)
			if comparison != .orderedAscending {
				return nil
			}
		}
		
		return candidate
	}
	
	func provenanceForInstallation(of app: AppInfoPresentable) -> SourceAppProvenance? {
		_candidateUpdate(for: app)?.sourceProvenance
	}
	
	func hideCurrentUpdate(_ update: AppUpdate) {
		guard InstallationRegistry.shared.ignoreUpdate(
			recordID: update.id,
			remoteVersion: update.remoteVersion
		) else {
			return
		}
		updates.removeValue(forKey: update.id)
	}
	
	func hideUpdatesForApp(_ update: AppUpdate) {
		guard InstallationRegistry.shared.disableUpdates(recordID: update.id) else {
			return
		}
		updates.removeValue(forKey: update.id)
	}
	
	func showUpdatesForApp(recordID: String) {
		_ = InstallationRegistry.shared.showUpdates(recordID: recordID)
	}
	
	func reconcileInstallation(of app: AppInfoPresentable) {
		guard
			let localBundleIdentifier = app.identifier,
			!localBundleIdentifier.isEmpty
		else {
			return
		}
		
		let metadata = Storage.shared.sourceMetadata(for: app)
		let sourceURL = metadata?.sourceRepositoryURL
		let sourceAppIdentifier = metadata?.sourceAppIdentifier
		
		let installedVersion: String
		if let appVersion = app.version, !appVersion.isEmpty {
			installedVersion = appVersion
		} else if let metadataVersion = metadata?.sourceAppVersion, !metadataVersion.isEmpty {
			installedVersion = metadataVersion
		} else {
			return
		}
		
		updates = updates.filter { _, update in
			let sameBundle = update.localBundleIdentifier == localBundleIdentifier
			guard sameBundle else { return true }
			
			if let sourceURL, let sourceAppIdentifier {
				let isSameApp = update.sourceProvenance.sourceAppIdentifier == sourceAppIdentifier
					&& _matchesStoredRepository(
						storedSourceURL: update.sourceURL,
						sourceURL: sourceURL
					)
				guard isSameApp else { return true }
			}
			
			let comparison = installedVersion.compare(
				update.remoteVersion,
				options: [.numeric, .caseInsensitive]
			)
			return comparison == .orderedAscending
		}
	}
	
	func checkForUpdates(
		sources: [AltSource],
		localApps: [AppInfoPresentable] = []
	) async {
		guard !isChecking else { return }
		
		isChecking = true
		defer {
			isChecking = false
			lastCheckedDate = Date()
		}
		
		// Library entries are intentionally not the authority anymore.
		// They remain in the signature so existing callers do not need special handling.
		_ = localApps
		
		let repositories = await _fetchRepositories(from: sources)
		updates = _findUpdates(
			repositories: repositories,
			installedApps: InstallationRegistry.shared.records
		)
	}
	
	private func _candidateUpdate(for app: AppInfoPresentable) -> AppUpdate? {
		guard
			let localBundleIdentifier = app.identifier,
			!localBundleIdentifier.isEmpty
		else {
			return nil
		}
		
		if
			let metadata = Storage.shared.sourceMetadata(for: app),
			let sourceURL = metadata.sourceRepositoryURL,
			let sourceAppIdentifier = metadata.sourceAppIdentifier,
			let candidate = updates.values.first(where: {
				$0.localBundleIdentifier == localBundleIdentifier
					&& $0.sourceProvenance.sourceAppIdentifier == sourceAppIdentifier
					&& _matchesStoredRepository(
						storedSourceURL: $0.sourceURL,
						sourceURL: sourceURL
					)
			})
		{
			return candidate
		}
		
		return updates.values.first {
			$0.localBundleIdentifier == localBundleIdentifier
		}
	}
	
	private func _fetchRepositories(from sources: [AltSource]) async -> [(AltSource, ASRepository)] {
		var repositories: [(AltSource, ASRepository)] = []
		
		for source in sources {
			guard let url = source.sourceURL else {
				continue
			}
			
			guard let repository = await _fetchRepository(from: url) else {
				continue
			}
			
			repositories.append((source, repository))
		}
		
		return repositories
	}
	
	private func _fetchRepository(from url: URL) async -> ASRepository? {
		await withCheckedContinuation { continuation in
			_dataService.fetch(from: url, forceReload: true) { (result: RepositoryDataHandler) in
				switch result {
				case .success(let repository):
					continuation.resume(returning: repository)
				case .failure:
					continuation.resume(returning: nil)
				}
			}
		}
	}
	
	private func _findUpdates(
		repositories: [(AltSource, ASRepository)],
		installedApps: [InstalledSourceAppRecord]
	) -> [String: AppUpdate] {
		var foundUpdates: [String: AppUpdate] = [:]
		let canonicalInstalledApps = _canonicalInstalledApps(installedApps)
		
		for installedApp in canonicalInstalledApps {
			for (source, repository) in repositories {
				guard let sourceURL = source.sourceURL else {
					continue
				}
				
				guard _matchesStoredRepository(
					storedSourceURL: installedApp.sourceRepositoryURL,
					sourceURL: sourceURL
				) else {
					continue
				}
				
				guard let remoteApp = repository.apps.first(where: {
					$0.id == installedApp.sourceAppIdentifier
				}) else {
					continue
				}
				
				guard
					let remoteVersion = remoteApp.currentVersion,
					!remoteVersion.isEmpty
				else {
					continue
				}
				
				let comparison = remoteVersion.compare(
					installedApp.installedVersion,
					options: [.numeric, .caseInsensitive]
				)
				guard comparison == .orderedDescending else {
					continue
				}
				
				if installedApp.updatesDisabled == true {
					continue
				}
				
				if let ignoredVersion = installedApp.ignoredRemoteVersion {
					if ignoredVersion == remoteVersion {
						continue
					}
					
					// "Hide This Update" applies only to that exact remote version.
					InstallationRegistry.shared.clearStaleIgnoredVersion(
						recordID: installedApp.id,
						currentRemoteVersion: remoteVersion
					)
				}
				
				guard let downloadURL = remoteApp.currentDownloadUrl else {
					continue
				}
				
				guard let provenance = SourceAppProvenance(
					sourceURL: sourceURL,
					repository: repository,
					app: remoteApp
				) else {
					continue
				}
				
				foundUpdates[installedApp.id] = AppUpdate(
					id: installedApp.id,
					localUUID: installedApp.id,
					localVersion: installedApp.installedVersion,
					remoteVersion: remoteVersion,
					appName: remoteApp.currentName,
					bundleIdentifier: installedApp.sourceAppIdentifier,
					localBundleIdentifier: installedApp.localBundleIdentifier,
					iconURL: remoteApp.iconURL,
					downloadURL: downloadURL,
					sourceURL: sourceURL,
					sourceProvenance: provenance
				)
				break
			}
		}
		
		return foundUpdates
	}
	
	private func _canonicalInstalledApps(
		_ installedApps: [InstalledSourceAppRecord]
	) -> [InstalledSourceAppRecord] {
		var canonical: [String: InstalledSourceAppRecord] = [:]
		
		for record in installedApps {
			let key = [
				_normalizedSourceURL(record.sourceRepositoryURL),
				record.sourceAppIdentifier,
				record.localBundleIdentifier
			].joined(separator: "|")
			
			guard let current = canonical[key] else {
				canonical[key] = record
				continue
			}
			
			let versionComparison = record.installedVersion.compare(
				current.installedVersion,
				options: [.numeric, .caseInsensitive]
			)
			
			if versionComparison == .orderedDescending
				|| (versionComparison == .orderedSame && record.updatedAt > current.updatedAt)
			{
				canonical[key] = record
			}
		}
		
		return Array(canonical.values)
	}
	
	private func _matchesStoredRepository(
		storedSourceURL: URL,
		sourceURL: URL
	) -> Bool {
		_normalizedSourceURL(storedSourceURL) == _normalizedSourceURL(sourceURL)
	}
	
	private func _normalizedSourceURL(_ url: URL) -> String {
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		let scheme = components?.scheme?.lowercased()
		let host = components?.host?.lowercased()
		components?.scheme = scheme
		components?.host = host
		components?.fragment = nil
		
		let normalized = components?.url ?? url
		let absoluteString = normalized.absoluteString
		return absoluteString.hasSuffix("/") ? String(absoluteString.dropLast()) : absoluteString
	}
}
