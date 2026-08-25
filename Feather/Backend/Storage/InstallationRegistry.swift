//
//  InstallationRegistry.swift
//  Feather
//
//  Persistent source-linked installation history for Updates.
//

import Foundation

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
}

final class InstallationRegistry {
	static let shared = InstallationRegistry()
	
	private let _fileManager = FileManager.default
	private let _fileURL: URL
	private(set) var records: [InstalledSourceAppRecord] = []
	
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
	
	@discardableResult
	func recordInstallation(of app: AppInfoPresentable) -> Bool {
		guard
			let appUUID = app.uuid,
			let localBundleIdentifier = app.identifier,
			!localBundleIdentifier.isEmpty,
			let metadata = Storage.shared.sourceMetadata(for: appUUID),
			let sourceRepositoryURL = metadata.sourceRepositoryURL,
			let sourceAppIdentifier = metadata.sourceAppIdentifier
		else {
			return false
		}
		
		guard
			let installedVersion = metadata.sourceAppVersion ?? app.version,
			!installedVersion.isEmpty
		else {
			return false
		}
		
		let now = Date()
		if let index = records.firstIndex(where: {
			_matchesIdentity(
				$0,
				sourceRepositoryURL: sourceRepositoryURL,
				sourceAppIdentifier: sourceAppIdentifier,
				localBundleIdentifier: localBundleIdentifier
			)
		}) {
			records[index].installedVersion = installedVersion
			records[index].appName = metadata.sourceAppName ?? app.name
			records[index].sourceRepositoryIdentifier = metadata.sourceRepositoryIdentifier
			records[index].sourceRepositoryName = metadata.sourceRepositoryName
			records[index].sourceAppVersionDate = metadata.sourceAppVersionDate
			records[index].sourceAppDownloadURL = metadata.sourceAppDownloadURL
			records[index].installedAt = now
			records[index].updatedAt = now
		} else {
			records.append(
				InstalledSourceAppRecord(
					id: UUID().uuidString,
					localBundleIdentifier: localBundleIdentifier,
					installedVersion: installedVersion,
					appName: metadata.sourceAppName ?? app.name,
					sourceRepositoryURL: sourceRepositoryURL,
					sourceRepositoryIdentifier: metadata.sourceRepositoryIdentifier,
					sourceRepositoryName: metadata.sourceRepositoryName,
					sourceAppIdentifier: sourceAppIdentifier,
					sourceAppVersionDate: metadata.sourceAppVersionDate,
					sourceAppDownloadURL: metadata.sourceAppDownloadURL,
					installedAt: now,
					updatedAt: now
				)
			)
		}
		
		_save()
		return true
	}
	
	func reset() {
		records.removeAll()
		try? _fileManager.removeItem(at: _fileURL)
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
	
	private func _save() {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		
		guard let data = try? encoder.encode(records) else {
			return
		}
		
		try? data.write(to: _fileURL, options: .atomic)
	}
}
