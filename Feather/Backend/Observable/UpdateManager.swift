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
	let localPackageRevision: String?
	let remotePackageRevision: String?
	let localPackageLabel: String?
	let remotePackageLabel: String?
	let isPackageOnlyUpdate: Bool
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

struct MonitoredSourceApp: Identifiable, Equatable {
	let bundleIdentifier: String
	let name: String
	let iconURL: URL?
	
	var id: String { bundleIdentifier.lowercased() }
}

@MainActor
final class UpdateManager: ObservableObject {
	static let shared = UpdateManager()

	typealias RepositoryDataHandler = Result<ASRepository, Error>

	@Published private(set) var updates: [String: AppUpdate] = [:]
	@Published private(set) var isChecking = false
	@Published private(set) var lastCheckedDate: Date?
	@Published private(set) var lastCheckFailedSourceCount = 0
	@Published private(set) var sourceApps: [MonitoredSourceApp] = []

	private let _dataService = NBFetchService()

	private init() {}

	var availableUpdates: [AppUpdate] {
		updates.values.sorted {
			$0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
		}
	}

	func update(for app: AppInfoPresentable) -> AppUpdate? {
		guard let candidate = _candidateUpdate(for: app) else { return nil }

		if
			let localBundleIdentifier = app.identifier,
			let installedRecord = InstallationRegistry.shared.records.first(where: {
				$0.localBundleIdentifier == localBundleIdentifier
			})
		{
			return Self._isRemoteReleaseNewer(
				remoteVersion: candidate.remoteVersion,
				remoteBuild: candidate.remoteBuildVersion,
				remoteDownloadURL: candidate.downloadURL,
				installedRecord: installedRecord
			) ? candidate : nil
		}

		// Source metadata is authoritative for source-linked downloads. It contains
		// the exact source version/build and download URL used for the installation.
		// The URL can also carry an optional package revision, allowing Feather to
		// detect an updated injected package even when app version/build did not move.
		if let metadata = Storage.shared.sourceMetadata(for: app),
		   let metadataVersion = metadata.sourceAppVersion,
		   !metadataVersion.isEmpty {
			let metadataBuild = SourceAppProvenance.buildVersion(
				fromSourceVersionID: metadata.sourceVersionID
			)
			return Self._isRemoteReleaseNewer(
				remoteVersion: candidate.remoteVersion,
				remoteBuild: candidate.remoteBuildVersion,
				remoteDownloadURL: candidate.downloadURL,
				installedVersion: metadataVersion,
				installedBuild: metadataBuild,
				installedDownloadURL: metadata.sourceAppDownloadURL
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
				remoteDownloadURL: update.downloadURL,
				installedVersion: installedVersion,
				installedBuild: installedBuild,
				installedDownloadURL: metadata?.sourceAppDownloadURL
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

		let discoveredSourceApps = _sourceApps(from: fetchResult.repositories)
		if fetchResult.failedSourceURLs.isEmpty || sourceApps.isEmpty {
			sourceApps = discoveredSourceApps
		}

		let monitoredRecords = InstallationRegistry.shared.records.filter {
			SourceMonitoringPreferences.shared.isMonitored($0.localBundleIdentifier)
		}
		let freshUpdates = _findUpdates(
			repositories: fetchResult.repositories,
			installedApps: monitoredRecords
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

	func applyMonitoringPreferences() {
		updates = updates.filter { _, update in
			SourceMonitoringPreferences.shared.isMonitored(update.localBundleIdentifier)
		}
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
					!remoteVersion.isEmpty,
					let downloadURL = remoteApp.currentDownloadUrl
				else {
					continue
				}
				let remoteBuild = remoteApp.currentAppVersion?.build

				guard Self._isRemoteReleaseNewer(
					remoteVersion: remoteVersion,
					remoteBuild: remoteBuild,
					remoteDownloadURL: downloadURL,
					installedRecord: installedApp
				) else {
					continue
				}

				if installedApp.updatesDisabled == true {
					continue
				}

				let remoteReleaseID = Self._releaseID(
					version: remoteVersion,
					build: remoteBuild,
					downloadURL: downloadURL
				)
				if let ignoredVersion = installedApp.ignoredRemoteVersion {
					if ignoredVersion == remoteReleaseID || ignoredVersion == remoteVersion {
						continue
					}

					InstallationRegistry.shared.clearStaleIgnoredVersion(
						recordID: installedApp.id,
						currentRemoteVersion: remoteReleaseID
					)
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
				let localPackageRevision = installedApp.installedPackageRevision
					?? Self._packageRevision(from: installedApp.sourceAppDownloadURL)
				let remotePackageRevision = Self._packageRevision(from: downloadURL)
				let localPackageLabel = installedApp.installedPackageLabel
					?? Self._packageLabel(from: installedApp.sourceAppDownloadURL)
				let remotePackageLabel = Self._packageLabel(from: downloadURL)
				let packageOnlyUpdate = Self._isPackageOnlyUpdate(
					remoteVersion: remoteVersion,
					remoteBuild: remoteBuild,
					remoteDownloadURL: downloadURL,
					installedRecord: installedApp
				)

				foundUpdates[installedApp.id] = AppUpdate(
					id: installedApp.id,
					localUUID: installedApp.id,
					localVersion: installedApp.installedVersion,
					localBuildVersion: installedApp.installedBuildVersion,
					remoteVersion: remoteVersion,
					remoteBuildVersion: remoteBuild,
					localPackageRevision: localPackageRevision,
					remotePackageRevision: remotePackageRevision,
					localPackageLabel: localPackageLabel,
					remotePackageLabel: remotePackageLabel,
					isPackageOnlyUpdate: packageOnlyUpdate,
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

	private func _sourceApps(
		from repositories: [(AltSource, ASRepository)]
	) -> [MonitoredSourceApp] {
		var canonical: [String: MonitoredSourceApp] = [:]
		
		for (_, repository) in repositories {
			for app in repository.apps {
				guard let rawBundleIdentifier = app.id else { continue }
				let bundleIdentifier = rawBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
				guard !bundleIdentifier.isEmpty else { continue }
				let key = bundleIdentifier.lowercased()
				let candidate = MonitoredSourceApp(
					bundleIdentifier: bundleIdentifier,
					name: app.currentName,
					iconURL: app.iconURL
				)
				
				if let current = canonical[key] {
					let currentIsUnknown = current.name.caseInsensitiveCompare("Unknown") == .orderedSame
					let candidateIsKnown = candidate.name.caseInsensitiveCompare("Unknown") != .orderedSame
					if currentIsUnknown && candidateIsKnown {
						canonical[key] = candidate
					}
				} else {
					canonical[key] = candidate
				}
			}
		}
		
		return canonical.values.sorted {
			$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
		}
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
				remoteDownloadURL: record.sourceAppDownloadURL,
				installedVersion: current.installedVersion,
				installedBuild: current.installedBuildVersion,
				installedDownloadURL: current.sourceAppDownloadURL
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
		remoteDownloadURL: URL?,
		installedRecord: InstalledSourceAppRecord
	) -> Bool {
		let versionComparison = remoteVersion.compare(
			installedRecord.installedVersion,
			options: [.numeric, .caseInsensitive]
		)
		if versionComparison == .orderedDescending { return true }
		if versionComparison == .orderedAscending { return false }

		let normalizedRemoteBuild = _normalizedValue(remoteBuild)
		let normalizedInstalledBuild = _normalizedValue(installedRecord.installedBuildVersion)
		if normalizedRemoteBuild != normalizedInstalledBuild {
			guard
				let normalizedRemoteBuild,
				let normalizedInstalledBuild
			else {
				return false
			}
			return normalizedRemoteBuild.compare(
				normalizedInstalledBuild,
				options: [.numeric, .caseInsensitive]
			) == .orderedDescending
		}

		if let installedPackageVersion = _normalizedValue(installedRecord.installedPackageVersion) {
			guard let remotePackageVersion = _packageVersion(from: remoteDownloadURL) else {
				return false
			}
			if
				let installedPackageName = _normalizedValue(installedRecord.installedPackageName),
				let remotePackageName = _packageName(from: remoteDownloadURL),
				installedPackageName.compare(remotePackageName, options: [.caseInsensitive]) != .orderedSame
			{
				return true
			}
			let packageVersionComparison = remotePackageVersion.compare(
				installedPackageVersion,
				options: [.numeric, .caseInsensitive]
			)
			if packageVersionComparison == .orderedDescending { return true }
			if packageVersionComparison == .orderedAscending { return false }

			guard
				let remoteRevision = _packageRevision(from: remoteDownloadURL),
				let installedRevision = _normalizedValue(installedRecord.installedPackageRevision)
			else {
				// A manually configured matching version has no trustworthy byte revision.
				// Do not turn that migration state into a false-positive update.
				return false
			}
			return remoteRevision.compare(installedRevision, options: [.caseInsensitive]) != .orderedSame
		}

		return _isRemoteReleaseNewer(
			remoteVersion: remoteVersion,
			remoteBuild: remoteBuild,
			remoteDownloadURL: remoteDownloadURL,
			installedVersion: installedRecord.installedVersion,
			installedBuild: installedRecord.installedBuildVersion,
			installedDownloadURL: installedRecord.sourceAppDownloadURL
		)
	}

	private static func _isPackageOnlyUpdate(
		remoteVersion: String,
		remoteBuild: String?,
		remoteDownloadURL: URL?,
		installedRecord: InstalledSourceAppRecord
	) -> Bool {
		guard remoteVersion.compare(
			installedRecord.installedVersion,
			options: [.numeric, .caseInsensitive]
		) == .orderedSame else {
			return false
		}
		guard _normalizedValue(remoteBuild) == _normalizedValue(installedRecord.installedBuildVersion) else {
			return false
		}
		return _isRemoteReleaseNewer(
			remoteVersion: remoteVersion,
			remoteBuild: remoteBuild,
			remoteDownloadURL: remoteDownloadURL,
			installedRecord: installedRecord
		)
	}

	private static func _isRemoteReleaseNewer(
		remoteVersion: String,
		remoteBuild: String?,
		remoteDownloadURL: URL? = nil,
		installedVersion: String,
		installedBuild: String?,
		installedDownloadURL: URL? = nil
	) -> Bool {
		let versionComparison = remoteVersion.compare(
			installedVersion,
			options: [.numeric, .caseInsensitive]
		)
		if versionComparison == .orderedDescending { return true }
		if versionComparison == .orderedAscending { return false }

		let normalizedRemoteBuild = _normalizedValue(remoteBuild)
		let normalizedInstalledBuild = _normalizedValue(installedBuild)
		if normalizedRemoteBuild != normalizedInstalledBuild {
			guard
				let normalizedRemoteBuild,
				let normalizedInstalledBuild
			else {
				return false
			}
			return normalizedRemoteBuild.compare(
				normalizedInstalledBuild,
				options: [.numeric, .caseInsensitive]
			) == .orderedDescending
		}

		let remotePackageRevision = _packageRevision(from: remoteDownloadURL)
		let installedPackageRevision = _packageRevision(from: installedDownloadURL)
		guard let remotePackageRevision else { return false }
		guard let installedPackageRevision else {
			// Migration path: a revision appearing for the first time on an otherwise
			// identical app release means the packaged IPA changed.
			return true
		}

		return remotePackageRevision.compare(
			installedPackageRevision,
			options: [.caseInsensitive]
		) != .orderedSame
	}

	private static func _isPackageOnlyUpdate(
		remoteVersion: String,
		remoteBuild: String?,
		remoteDownloadURL: URL?,
		installedVersion: String,
		installedBuild: String?,
		installedDownloadURL: URL?
	) -> Bool {
		guard remoteVersion.compare(
			installedVersion,
			options: [.numeric, .caseInsensitive]
		) == .orderedSame else {
			return false
		}
		guard _normalizedValue(remoteBuild) == _normalizedValue(installedBuild) else {
			return false
		}
		guard let remoteRevision = _packageRevision(from: remoteDownloadURL) else {
			return false
		}
		guard let installedRevision = _packageRevision(from: installedDownloadURL) else {
			return true
		}
		return remoteRevision.compare(installedRevision, options: [.caseInsensitive]) != .orderedSame
	}

	private static func _releaseID(version: String, build: String?, downloadURL: URL?) -> String {
		let base: String
		if let build = _normalizedValue(build) {
			base = "\(version) (\(build))"
		} else {
			base = version
		}
		guard let revision = _packageRevision(from: downloadURL) else { return base }
		return "\(base) [pkg:\(revision)]"
	}

	private static func _packageName(from url: URL?) -> String? {
		guard let url else { return nil }
		return _queryValue(in: url, keys: ["tweak", "tweakName"])
	}

	private static func _packageVersion(from url: URL?) -> String? {
		guard let url else { return nil }
		return _queryValue(in: url, keys: ["tweakVersion"])
	}

	private static func _packageRevision(from url: URL?) -> String? {
		guard let url else { return nil }
		if let explicit = _queryValue(
			in: url,
			keys: ["packageRevision", "featherRevision", "pkgRevision"]
		) {
			return explicit
		}
		guard let tweakVersion = _queryValue(in: url, keys: ["tweakVersion"]) else {
			return nil
		}
		let tweakName = _queryValue(in: url, keys: ["tweak", "tweakName"]) ?? "tweak"
		return "\(tweakName)@\(tweakVersion)"
	}

	private static func _packageLabel(from url: URL?) -> String? {
		guard let url else { return nil }
		if let explicit = _queryValue(in: url, keys: ["packageLabel"]) {
			return explicit
		}
		guard let tweakVersion = _queryValue(in: url, keys: ["tweakVersion"]) else {
			return nil
		}
		if let tweakName = _queryValue(in: url, keys: ["tweak", "tweakName"]) {
			return "\(tweakName) \(tweakVersion)"
		}
		return tweakVersion
	}

	private static func _queryValue(in url: URL, keys: [String]) -> String? {
		guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
			return nil
		}
		for key in keys {
			if let value = queryItems.first(where: {
				$0.name.compare(key, options: [.caseInsensitive]) == .orderedSame
			})?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
			!value.isEmpty {
				return value
			}
		}
		return nil
	}

	private static func _normalizedValue(_ value: String?) -> String? {
		guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
			return nil
		}
		return value
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
