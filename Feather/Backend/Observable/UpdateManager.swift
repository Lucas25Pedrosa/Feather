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
	let localBuildVersion: String?
	let remoteVersion: String
	let remoteBuildVersion: String?
	let remoteReleaseID: String
	let appName: String
	let bundleIdentifier: String
	let localBundleIdentifier: String
	let iconURL: URL?
	let downloadURL: URL
	let sourceURL: URL
	let changelog: String?
	let sourceProvenance: SourceAppProvenance
}

@MainActor
final class UpdateManager: ObservableObject {
	static let shared = UpdateManager()
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	@Published private(set) var updates: [String: AppUpdate] = [:]
	@Published private(set) var isChecking = false
	@Published private(set) var lastCheckedDate: Date?
	@Published private(set) var lastCheckFailedSourceCount = 0
	
	private let _dataService = NBFetchService()
	
	private init() {}
	
	var availableUpdates: [AppUpdate] {
		updates.values.sorted {
			$0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
		}
	}
	
	func update(for app: AppInfoPresentable) -> AppUpdate? {
		guard let candidate = _candidateUpdate(for: app) else { return nil }
		
		// Source metadata is authoritative for source-linked downloads. It contains
		// the exact source version/build even when the IPA's CFBundle version uses a
		// different human-readable beta label.
		if let metadata = Storage.shared.sourceMetadata(for: app),
		   let metadataVersion = metadata.sourceAppVersion,
		   !metadataVersion.isEmpty {
			let metadataBuild = SourceAppProvenance.buildVersion(
				fromSourceVersionID: metadata.sourceVersionID
			)
			return Self._isRemoteReleaseNewer(
				remoteVersion: candidate.remoteVersion,
				remoteBuild: candidate.remoteBuildVersion,
				installedVersion: metadataVersion,
				installedBuild: metadataBuild
			) ? candidate : nil
		}
		
		// Fallback for apps without source metadata.
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
			remoteVersion: update.remoteReleaseID
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
		if let metadataVersion = metadata?.sourceAppVersion, !metadataVersion.isEmpty {
			installedVersion = metadataVersion
		} else if let appVersion = app.version, !appVersion.isEmpty {
			installedVersion = appVersion
		} else {
			return
		}
		let installedBuild = SourceAppProvenance.buildVersion(
			fromSourceVersionID: metadata?.sourceVersionID
		)
		
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
			
			return Self._isRemoteReleaseNewer(
				remoteVersion: update.remoteVersion,
				remoteBuild: update.remoteBuildVersion,
				installedVersion: installedVersion,
				installedBuild: installedBuild
			)
		}
	}
	
	func checkForUpdates(
		sources: [AltSource],
		localApps: [AppInfoPresentable] = []
	) async {
		while isChecking {
			try? await Task.sleep(nanoseconds: 50_000_000)
		}
		
		isChecking = true
		defer {
			isChecking = false
			lastCheckedDate = Date()
		}
		
		_ = localApps
		
		let fetchResult = await _fetchRepositories(from: sources)
		lastCheckFailedSourceCount = fetchResult.failedSourceURLs.count
		
		// If every configured source failed, do not replace a previously valid
		// update list with a misleading "No Updates" state.
		if !sources.isEmpty && fetchResult.repositories.isEmpty && !fetchResult.failedSourceURLs.isEmpty {
			return
		}
		
		let freshUpdates = _findUpdates(
			repositories: fetchResult.repositories,
			installedApps: InstallationRegistry.shared.records
		)
		
		// Preserve entries belonging to sources that temporarily failed while
		// refreshing successful sources normally.
		var merged = freshUpdates
		for (id, existing) in updates {
			let normalizedURL = _normalizedSourceURL(existing.sourceURL)
			if fetchResult.failedSourceURLs.contains(normalizedURL), merged[id] == nil {
				merged[id] = existing
			}
		}
		updates = merged
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
	
	private struct RepositoryFetchResult {
		let repositories: [(AltSource, ASRepository)]
		let failedSourceURLs: Set<String>
	}
	
	private func _fetchRepositories(from sources: [AltSource]) async -> RepositoryFetchResult {
		var repositories: [(AltSource, ASRepository)] = []
		var failedSourceURLs: Set<String> = []
		
		for source in sources {
			guard let url = source.sourceURL else {
				continue
			}
			
			guard let repository = await _fetchRepository(from: url) else {
				failedSourceURLs.insert(_normalizedSourceURL(url))
				continue
			}
			
			repositories.append((source, repository))
		}
		
		return RepositoryFetchResult(
			repositories: repositories,
			failedSourceURLs: failedSourceURLs
		)
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
				let remoteBuild = remoteApp.currentAppVersion?.build
				
				guard Self._isRemoteReleaseNewer(
					remoteVersion: remoteVersion,
					remoteBuild: remoteBuild,
					installedVersion: installedApp.installedVersion,
					installedBuild: installedApp.installedBuildVersion
				) else {
					continue
				}
				
				if installedApp.updatesDisabled == true {
					continue
				}
				
				let remoteReleaseID = Self._releaseID(version: remoteVersion, build: remoteBuild)
				if let ignoredVersion = installedApp.ignoredRemoteVersion {
					if ignoredVersion == remoteReleaseID || ignoredVersion == remoteVersion {
						continue
					}
					
					InstallationRegistry.shared.clearStaleIgnoredVersion(
						recordID: installedApp.id,
						currentRemoteVersion: remoteReleaseID
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
				
				let changelog = remoteApp.currentAppVersion?.localizedDescription
					?? remoteApp.versionDescription
				
				foundUpdates[installedApp.id] = AppUpdate(
					id: installedApp.id,
					localUUID: installedApp.id,
					localVersion: installedApp.installedVersion,
					localBuildVersion: installedApp.installedBuildVersion,
					remoteVersion: remoteVersion,
					remoteBuildVersion: remoteBuild,
					remoteReleaseID: remoteReleaseID,
					appName: remoteApp.currentName,
					bundleIdentifier: installedApp.sourceAppIdentifier,
					localBundleIdentifier: installedApp.localBundleIdentifier,
					iconURL: remoteApp.iconURL,
					downloadURL: downloadURL,
					sourceURL: sourceURL,
					changelog: changelog,
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
			
			if Self._isRemoteReleaseNewer(
				remoteVersion: record.installedVersion,
				remoteBuild: record.installedBuildVersion,
				installedVersion: current.installedVersion,
				installedBuild: current.installedBuildVersion
			) || (record.installedVersion == current.installedVersion
				&& record.installedBuildVersion == current.installedBuildVersion
				&& record.updatedAt > current.updatedAt) {
				canonical[key] = record
			}
		}
		
		return Array(canonical.values)
	}
	
	private static func _isRemoteReleaseNewer(
		remoteVersion: String,
		remoteBuild: String?,
		installedVersion: String,
		installedBuild: String?
	) -> Bool {
		let versionComparison = remoteVersion.compare(
			installedVersion,
			options: [.numeric, .caseInsensitive]
		)
		if versionComparison == .orderedDescending { return true }
		if versionComparison == .orderedAscending { return false }
		
		guard
			let remoteBuild,
			!remoteBuild.isEmpty,
			let installedBuild,
			!installedBuild.isEmpty
		else {
			return false
		}
		
		return remoteBuild.compare(
			installedBuild,
			options: [.numeric, .caseInsensitive]
		) == .orderedDescending
	}
	
	private static func _releaseID(version: String, build: String?) -> String {
		guard let build, !build.isEmpty else { return version }
		return "\(version) (\(build))"
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
