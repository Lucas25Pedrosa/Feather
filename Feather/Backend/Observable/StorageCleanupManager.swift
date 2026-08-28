//
//  StorageCleanupManager.swift
//  Feather
//
//  Safe cache and temporary-file cleanup for Feather 3.2.
//

import Combine
import Foundation

struct StorageCleanupReport: Equatable, Sendable {
	let bytesFreed: Int64
	let removedItems: Int
}

@MainActor
final class StorageCleanupManager: ObservableObject {
	static let shared = StorageCleanupManager()
	static let automaticCleanupKey = "Feather.autoCleanupAfterInstallation"

	@Published private(set) var isCleaning = false
	@Published private(set) var lastReport: StorageCleanupReport?
	@Published private(set) var lastCleanupDate: Date?

	private init() {}

	var automaticCleanupEnabled: Bool {
		UserDefaults.standard.bool(forKey: Self.automaticCleanupKey)
	}

	func cleanNow() async {
		await _clean(minimumTemporaryAge: 30 * 60)
	}

	func scheduleAutomaticCleanup() {
		guard automaticCleanupEnabled else { return }
		Task { @MainActor in
			await _clean(minimumTemporaryAge: 10 * 60)
		}
	}

	private func _clean(minimumTemporaryAge: TimeInterval) async {
		guard !isCleaning else { return }
		isCleaning = true

		let report = await Task.detached(priority: .utility) {
			Self._performCleanup(minimumTemporaryAge: minimumTemporaryAge)
		}.value

		lastReport = report
		lastCleanupDate = Date()
		isCleaning = false
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

		return StorageCleanupReport(bytesFreed: bytesFreed, removedItems: removedItems)
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
