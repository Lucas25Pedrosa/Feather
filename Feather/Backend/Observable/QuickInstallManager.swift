//
//  QuickInstallManager.swift
//  Feather
//
//  Feather 3.2 one-tap install pipeline for source downloads and imported IPAs.
//

import Combine
import CoreData
import Foundation

enum QuickInstallDownloadRoute {
	static let prefix = "FeatherQuickInstall_"

	static func downloadID(for jobID: String) -> String {
		prefix + jobID
	}

	static func jobID(from downloadID: String) -> String? {
		guard downloadID.hasPrefix(prefix) else { return nil }
		let value = String(downloadID.dropFirst(prefix.count))
		return value.isEmpty ? nil : value
	}
}

enum QuickInstallPhase: String, Equatable {
	case idle
	case downloading
	case signing
	case installing
	case completed
	case failed
}

struct QuickInstallJobState: Equatable {
	var phase: QuickInstallPhase = .idle
	var progress: Double = 0
	var detail: String?

	var isActive: Bool {
		switch phase {
		case .downloading, .signing, .installing:
			return true
		default:
			return false
		}
	}
}

@MainActor
final class QuickInstallManager: ObservableObject {
	static let shared = QuickInstallManager()

	@Published private(set) var states: [String: QuickInstallJobState] = [:]

	private final class JobContext {
		let expectedBundleIdentifier: String?
		let shouldDeleteImported: Bool
		var observer: AnyCancellable?
		var installer: FeatherAppInstaller?

		init(
			expectedBundleIdentifier: String?,
			shouldDeleteImported: Bool
		) {
			self.expectedBundleIdentifier = expectedBundleIdentifier
			self.shouldDeleteImported = shouldDeleteImported
		}
	}

	private var _jobs: [String: JobContext] = [:]

	private init() {}

	func state(for jobID: String) -> QuickInstallJobState {
		states[jobID] ?? QuickInstallJobState()
	}

	var hasUsableCertificate: Bool {
		UpdateEnginePreferences.shared.usableCertificate() != nil
	}

	@discardableResult
	func startSourceDownload(
		from url: URL,
		jobID: String,
		expectedBundleIdentifier: String?,
		sourceProvenance: SourceAppProvenance?
	) -> Bool {
		guard hasUsableCertificate else { return false }

		if states[jobID]?.isActive == true {
			return true
		}

		let context = JobContext(
			expectedBundleIdentifier: expectedBundleIdentifier,
			shouldDeleteImported: true
		)
		_jobs[jobID] = context
		_setState(jobID, phase: .downloading, progress: 0, detail: "Baixando")

		let download = DownloadManager.shared.startDownload(
			from: url,
			id: QuickInstallDownloadRoute.downloadID(for: jobID),
			sourceProvenance: sourceProvenance
		)

		context.observer = download.$progress
			.receive(on: DispatchQueue.main)
			.sink { [weak self] progress in
				Task { @MainActor in
					guard
						let self,
						self.states[jobID]?.phase == .downloading
					else { return }
					self._setState(
						jobID,
						phase: .downloading,
						progress: progress,
						detail: "Baixando"
					)
				}
			}

		return true
	}

	@discardableResult
	func startImported(_ app: AppInfoPresentable) -> Bool {
		guard
			hasUsableCertificate,
			!app.isSigned,
			let jobID = app.uuid,
			!jobID.isEmpty
		else {
			return false
		}

		if states[jobID]?.isActive == true {
			return true
		}

		let context = JobContext(
			expectedBundleIdentifier: app.identifier,
			shouldDeleteImported: OptionsManager.shared.options.post_deleteAppAfterSigned
		)
		_jobs[jobID] = context
		_beginSigning(app, jobID: jobID)
		return true
	}

	func importedAppReady(uuid: String, jobID: String) {
		guard let context = _jobs[jobID] else { return }
		context.observer = nil

		guard let imported = _importedApp(uuid: uuid) else {
			fail(jobID: jobID, message: "O IPA foi baixado, mas o app importado não foi localizado.")
			return
		}

		_beginSigning(imported, jobID: jobID)
	}

	func fail(jobID: String, error: Error) {
		fail(jobID: jobID, message: error.localizedDescription)
	}

	func fail(jobID: String, message: String) {
		guard _jobs[jobID] != nil || states[jobID] != nil else { return }
		guard states[jobID]?.phase != .failed else { return }

		_jobs[jobID]?.observer = nil
		_jobs[jobID]?.installer?.stop()
		_jobs[jobID]?.installer = nil
		_setState(jobID, phase: .failed, progress: 0, detail: message)
	}

	func clearState(jobID: String) {
		guard states[jobID]?.isActive != true else { return }
		states.removeValue(forKey: jobID)
		_jobs.removeValue(forKey: jobID)
	}

	private func _beginSigning(_ app: AppInfoPresentable, jobID: String) {
		guard let context = _jobs[jobID] else { return }
		guard let certificate = UpdateEnginePreferences.shared.usableCertificate() else {
			fail(jobID: jobID, message: "O certificado padrão não está mais disponível ou expirou.")
			return
		}

		_setState(jobID, phase: .signing, progress: 0, detail: "Assinando")
		let signedBefore = Set(_allSignedApps().compactMap(\.uuid))
		var options = OptionsManager.shared.options
		options.post_installAppAfterSigned = false
		options.post_deleteAppAfterSigned = false

		FR.signPackageFile(
			app,
			using: options,
			icon: nil,
			certificate: certificate
		) { [weak self] error in
			Task { @MainActor in
				guard let self else { return }
				if let error {
					self.fail(jobID: jobID, message: error.localizedDescription)
					return
				}

				guard let signed = self._newSignedApp(
					excluding: signedBefore,
					preferredBundleIdentifier: context.expectedBundleIdentifier
				) else {
					self.fail(jobID: jobID, message: "A assinatura terminou, mas o app assinado não foi localizado.")
					return
				}

				if context.shouldDeleteImported {
					Storage.shared.deleteApp(for: app)
				}
				self._beginInstallation(signed, jobID: jobID)
			}
		}
	}

	private func _beginInstallation(_ signed: Signed, jobID: String) {
		guard let context = _jobs[jobID] else { return }
		_setState(jobID, phase: .installing, progress: 0, detail: "Instalando")

		do {
			let installer = try FeatherAppInstaller(app: signed)
			context.installer = installer
			context.observer = installer.viewModel.$installProgress
				.receive(on: DispatchQueue.main)
				.sink { [weak self] progress in
					Task { @MainActor in
						guard
							let self,
							self.states[jobID]?.phase == .installing
						else { return }
						self._setState(
							jobID,
							phase: .installing,
							progress: progress,
							detail: "Instalando"
						)
					}
				}

			installer.start { [weak self] error in
				Task { @MainActor in
					guard let self else { return }
					context.observer = nil
					context.installer = nil

					if let error {
						self.fail(jobID: jobID, message: error.localizedDescription)
						return
					}

					self._setState(jobID, phase: .completed, progress: 1, detail: "Concluído")
					self._scheduleCompletedStateCleanup(jobID: jobID)
				}
			}
		} catch {
			fail(jobID: jobID, message: error.localizedDescription)
		}
	}

	private func _scheduleCompletedStateCleanup(jobID: String) {
		Task { [weak self] in
			try? await Task.sleep(nanoseconds: 1_500_000_000)
			guard !Task.isCancelled else { return }
			await MainActor.run {
				guard self?.states[jobID]?.phase == .completed else { return }
				self?.states.removeValue(forKey: jobID)
				self?._jobs.removeValue(forKey: jobID)
			}
		}
	}

	private func _setState(
		_ jobID: String,
		phase: QuickInstallPhase,
		progress: Double,
		detail: String?
	) {
		states[jobID] = QuickInstallJobState(
			phase: phase,
			progress: min(1, max(0, progress)),
			detail: detail
		)
	}

	private func _importedApp(uuid: String) -> Imported? {
		let request: NSFetchRequest<Imported> = Imported.fetchRequest()
		request.fetchLimit = 1
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		return try? Storage.shared.context.fetch(request).first
	}

	private func _allSignedApps() -> [Signed] {
		let request: NSFetchRequest<Signed> = Signed.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
		return (try? Storage.shared.context.fetch(request)) ?? []
	}

	private func _newSignedApp(
		excluding previousUUIDs: Set<String>,
		preferredBundleIdentifier: String?
	) -> Signed? {
		let newApps = _allSignedApps().filter {
			guard let uuid = $0.uuid else { return false }
			return !previousUUIDs.contains(uuid)
		}

		if let preferredBundleIdentifier,
		   let exact = newApps.first(where: { $0.identifier == preferredBundleIdentifier }) {
			return exact
		}
		return newApps.first
	}
}
