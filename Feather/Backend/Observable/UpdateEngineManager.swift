//
//  UpdateEngineManager.swift
//  Feather
//
//  Feather 3.2 one-tap update pipeline.
//

import Combine
import CoreData
import Foundation

// Kept outside the actor so download/import handlers can route jobs safely.
enum UpdateEngineDownloadRoute {
	static let prefix = "FeatherAutoUpdate_"

	static func downloadID(for jobID: String) -> String {
		prefix + jobID
	}

	static func jobID(from downloadID: String) -> String? {
		guard downloadID.hasPrefix(prefix) else { return nil }
		let value = String(downloadID.dropFirst(prefix.count))
		return value.isEmpty ? nil : value
	}
}

enum UpdateEnginePhase: String, Equatable {
	case idle
	case downloading
	case signing
	case installing
	case completed
	case failed
}

struct UpdateEngineJobState: Equatable {
	var phase: UpdateEnginePhase = .idle
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
final class UpdateEngineManager: ObservableObject {
	static let shared = UpdateEngineManager()

	@Published private(set) var states: [String: UpdateEngineJobState] = [:]

	private final class JobContext {
		let update: AppUpdate
		var downloadObserver: AnyCancellable?
		var installer: FeatherAppInstaller?

		init(update: AppUpdate) {
			self.update = update
		}
	}

	private var _jobs: [String: JobContext] = [:]

	private init() {}

	func state(for update: AppUpdate) -> UpdateEngineJobState {
		states[update.localUUID] ?? UpdateEngineJobState()
	}

	func canAutomaticallyUpdate(_ update: AppUpdate) -> Bool {
		_ = update
		return UpdateEnginePreferences.shared.usableCertificate() != nil
	}

	@discardableResult
	func start(_ update: AppUpdate) -> Bool {
		guard UpdateEnginePreferences.shared.usableCertificate() != nil else {
			return false
		}

		if let existing = states[update.localUUID], existing.isActive {
			return true
		}

		let context = JobContext(update: update)
		_jobs[update.localUUID] = context
		_setState(update.localUUID, phase: .downloading, progress: 0, detail: "Baixando")

		let download = DownloadManager.shared.startDownload(
			from: update.downloadURL,
			id: UpdateEngineDownloadRoute.downloadID(for: update.localUUID),
			sourceProvenance: update.sourceProvenance
		)

		context.downloadObserver = download.$progress
			.receive(on: DispatchQueue.main)
			.sink { [weak self] progress in
				guard let self else { return }
				Task { @MainActor in
					guard self.states[update.localUUID]?.phase == .downloading else { return }
					self._setState(
						update.localUUID,
						phase: .downloading,
						progress: progress,
						detail: "Baixando"
					)
				}
			}

		return true
	}

	func importedAppReady(uuid: String, jobID: String) {
		guard let context = _jobs[jobID] else { return }
		context.downloadObserver = nil

		guard let imported = _importedApp(uuid: uuid) else {
			fail(jobID: jobID, message: "O IPA foi baixado, mas o app importado não foi localizado.")
			return
		}

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
			imported,
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
					bundleIdentifier: context.update.localBundleIdentifier
				) else {
					self.fail(jobID: jobID, message: "A assinatura terminou, mas o app assinado não foi localizado.")
					return
				}

				Storage.shared.deleteApp(for: imported)
				self._beginInstallation(signed, jobID: jobID)
			}
		}
	}

	func fail(jobID: String, error: Error) {
		fail(jobID: jobID, message: error.localizedDescription)
	}

	func fail(jobID: String, message: String) {
		guard _jobs[jobID] != nil || states[jobID] != nil else { return }
		_jobs[jobID]?.downloadObserver = nil
		_jobs[jobID]?.installer?.stop()
		_jobs[jobID]?.installer = nil
		_setState(jobID, phase: .failed, progress: 0, detail: message)
	}

	func clearState(for update: AppUpdate) {
		guard states[update.localUUID]?.isActive != true else { return }
		states.removeValue(forKey: update.localUUID)
		_jobs.removeValue(forKey: update.localUUID)
	}

	private func _beginInstallation(_ signed: Signed, jobID: String) {
		guard let context = _jobs[jobID] else { return }
		_setState(jobID, phase: .installing, progress: 0, detail: "Instalando")

		do {
			let installer = try FeatherAppInstaller(app: signed)
			context.installer = installer

			let progressObserver = installer.viewModel.$installProgress
				.receive(on: DispatchQueue.main)
				.sink { [weak self] progress in
					Task { @MainActor in
						guard let self, self.states[jobID]?.phase == .installing else { return }
						self._setState(jobID, phase: .installing, progress: progress, detail: "Instalando")
					}
				}

			// Retain both observers through the same job lifetime.
			context.downloadObserver = progressObserver

			installer.start { [weak self] error in
				Task { @MainActor in
					guard let self else { return }
					context.downloadObserver = nil
					context.installer = nil
					if let error {
						self.fail(jobID: jobID, message: error.localizedDescription)
					} else {
						self._setState(jobID, phase: .completed, progress: 1, detail: "Concluído")
					}
				}
			}
		} catch {
			fail(jobID: jobID, message: error.localizedDescription)
		}
	}

	private func _setState(
		_ jobID: String,
		phase: UpdateEnginePhase,
		progress: Double,
		detail: String?
	) {
		states[jobID] = UpdateEngineJobState(
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
		bundleIdentifier: String
	) -> Signed? {
		_allSignedApps().first {
			guard let uuid = $0.uuid, !previousUUIDs.contains(uuid) else { return false }
			return $0.identifier == bundleIdentifier
		}
	}
}
