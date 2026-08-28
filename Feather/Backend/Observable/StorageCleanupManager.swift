//
//  StorageCleanupManager.swift
//  Feather
//
//  Safe cache and temporary-file cleanup for Feather 3.2.
//

import Combine
import CoreData
import Foundation

struct StorageCleanupReport: Equatable, Sendable {
	let bytesFreed: Int64
	let removedItems: Int
	let removedStoredApps: Int
}

@MainActor
final class StorageCleanupManager: ObservableObject {
	static let shared = StorageCleanupManager()
	static let automaticCleanupKey = "Feather.autoCleanupAfterInstallation"
	static let automaticPurgeAppsKey = "Feather.autoCleanupPurgeImportedAndSigned"

	@Published private(set) var isCleaning = false
	@Published private(set) var lastReport: StorageCleanupReport?
	@Published private(set) var lastCleanupDate: Date?

	private init() {}

	var automaticCleanupEnabled: Bool {
		UserDefaults.standard.bool(forKey: Self.automaticCleanupKey)
	}

	var automaticPurgeAppsEnabled: Bool {
		UserDefaults.standard.bool(forKey: Self.automaticPurgeAppsKey)
	}

	func cleanNow() async {
		// Manual cleanup is intentionally always safe: it never removes apps
		// from Imported or Signed, even if automatic purge is enabled.
		await _clean(
			minimumTemporaryAge: 30 * 60,
			purgeStoredApps: false
		)
	}

	func scheduleAutomaticCleanup() {
		guard automaticCleanupEnabled else { return }
		let shouldPurgeStoredApps = automaticPurgeAppsEnabled

		Task { @MainActor in
			// Let the update/quick-install engine release its Signed object before
			// optionally deleting the library copies that are no longer needed.
			try? await Task.sleep(nanoseconds: 750_000_000)
			await _clean(
				minimumTemporaryAge: 10 * 60,
				purgeStoredApps: shouldPurgeStoredApps
			)
		}
	}

	private func _clean(
		minimumTemporaryAge: TimeInterval,
		purgeStoredApps: Bool
	) async {
		guard !isCleaning else { return }
		isCleaning = true

		let cacheReport = await Task.detached(priority: .utility) {
			Self._performCleanup(minimumTemporaryAge: minimumTemporaryAge)
		}.value

		let libraryReport = purgeStoredApps
			? _purgeImportedAndSignedApps()
			: StorageCleanupReport(bytesFreed: 0, removedItems: 0, removedStoredApps: 0)

		lastReport = StorageCleanupReport(
			bytesFreed: cacheReport.bytesFreed + libraryReport.bytesFreed,
			removedItems: cacheReport.removedItems + libraryReport.removedItems,
			removedStoredApps: libraryReport.removedStoredApps
		)
		lastCleanupDate = Date()
		isCleaning = false
	}

	private func _purgeImportedAndSignedApps() -> StorageCleanupReport {
		let storage = Storage.shared
		let fileManager = FileManager.default
		let importedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
		let signedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()

		let imported = (try? storage.context.fetch(importedRequest)) ?? []
		let signed = (try? storage.context.fetch(signedRequest)) ?? []
		let apps: [AppInfoPresentable] = imported.map { $0 as AppInfoPresentable }
			+ signed.map { $0 as AppInfoPresentable }

		var bytesFreed: Int64 = 0
		var removedApps = 0

		for app in apps {
			if let directory = storage.getUuidDirectory(for: app) {
				bytesFreed += Self._allocatedSize(of: directory, fileManager: fileManager)
			}
			storage.deleteApp(for: app)
			removedApps += 1
		}

		return StorageCleanupReport(
			bytesFreed: bytesFreed,
			removedItems: removedApps,
			removedStoredApps: removedApps
		)
	}

	nonisolated private static func _performCleanup(
		minimumTemporaryAge: TimeInterval
	) -> StorageCleanupReport {
		let fileManager = FileManager.default
		var bytesFreed: Int64 = 0
		var removedItems = 0

		URLCache.shared.removeAllCachedResponses()

		if let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
			for item in (try? fileManager.contentsOfDirectory(
				at: cachesDirectory,
				includingPropertiesForKeys: nil,
				options: [.skipsHiddenFiles]
			)) ?? [] {
				let size = _allocatedSize(of: item, fileManager: fileManager)
				if (try? fileManager.removeItem(at: item)) != nil {
					bytesFreed += size
					removedItems += 1
				}
			}
		}

		let temporaryDirectory = fileManager.temporaryDirectory
		let cutoff = Date().addingTimeInterval(-minimumTemporaryAge)
		let prefixes = ["FeatherInstall_", "FeatherImport_", "FeatherSigning_"]

		for item in (try? fileManager.contentsOfDirectory(
			at: temporaryDirectory,
			includingPropertiesForKeys: [.contentModificationDateKey],
			options: [.skipsHiddenFiles]
		)) ?? [] {
			let name = item.lastPathComponent
			let isKnownTransient = prefixes.contains { name.hasPrefix($0) } || name == "FeatherDownloads"
			guard isKnownTransient else { continue }

			let values = try? item.resourceValues(forKeys: [.contentModificationDateKey])
			let modificationDate = values?.contentModificationDate ?? .distantPast
			guard modificationDate <= cutoff else { continue }

			let size = _allocatedSize(of: item, fileManager: fileManager)
			if (try? fileManager.removeItem(at: item)) != nil {
				bytesFreed += size
				removedItems += 1
			}
		}

		return StorageCleanupReport(
			bytesFreed: bytesFreed,
			removedItems: removedItems,
			removedStoredApps: 0
		)
	}

	nonisolated private static func _allocatedSize(
		of url: URL,
		fileManager: FileManager
	) -> Int64 {
		if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]),
		   values.isDirectory != true {
			return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
		}

		guard let enumerator = fileManager.enumerator(
			at: url,
			includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey],
			options: [.skipsHiddenFiles, .skipsPackageDescendants]
		) else {
			return 0
		}

		var total: Int64 = 0
		for case let fileURL as URL in enumerator {
			guard let values = try? fileURL.resourceValues(
				forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
			), values.isRegularFile == true else {
				continue
			}
			total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
		}
		return total
	}
}
