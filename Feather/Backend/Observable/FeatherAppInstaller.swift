//
//  FeatherAppInstaller.swift
//  Feather
//
//  Reusable installation pipeline introduced for Feather 3.2.
//

import Combine
import Foundation
import IDeviceSwift
import OSLog
import UIKit

@MainActor
final class FeatherAppInstaller: ObservableObject {
	let app: AppInfoPresentable
	let viewModel: InstallerStatusViewModel

	private let _installationMethod: Int
	private let _serverMethod: Int
	private var _server: ServerInstaller?
	private var _statusObserver: AnyCancellable?
	private var _progressTask: Task<Void, Never>?
	private var _completion: ((Error?) -> Void)?
	private var _finished = false
	private var _didRecordInstallation = false

	init(app: AppInfoPresentable) throws {
		self.app = app
		self._installationMethod = UserDefaults.standard.integer(forKey: "Feather.installationMethod")
		self._serverMethod = UserDefaults.standard.integer(forKey: "Feather.serverMethod")
		self.viewModel = InstallerStatusViewModel(isIdevice: _installationMethod == 1)

		if _installationMethod == 0 {
			self._server = try ServerInstaller(app: app, viewModel: viewModel)
		}
	}

	deinit {
		_progressTask?.cancel()
	}

	func start(completion: @escaping (Error?) -> Void) {
		guard _completion == nil, !_finished else { return }
		_completion = completion

		guard app.identifier != Bundle.main.bundleIdentifier! || _installationMethod == 1 else {
			_finish(_error("O Feather não pode atualizar a si mesmo por este método."))
			return
		}

		_statusObserver = viewModel.$status
			.receive(on: DispatchQueue.main)
			.sink { [weak self] status in
				self?._handle(status)
			}

		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.start()
		#endif

		Task { await _prepareAndInstall() }
	}

	func stop() {
		guard !_finished else { return }
		_finished = true
		_completion = nil
		_statusObserver = nil
		_progressTask?.cancel()
		_progressTask = nil
		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.stop()
		#endif
	}

	private func _prepareAndInstall() async {
		do {
			let app = app
			let viewModel = viewModel
			let packageURL = try await Task.detached(priority: .userInitiated) {
				let handler = ArchiveHandler(app: app, viewModel: viewModel)
				try await handler.move()
				return try await handler.archive()
			}.value

			if _installationMethod == 1 {
				let proxy = InstallationProxy(viewModel: viewModel)
				try await proxy.install(
					at: packageURL,
					suspend: app.identifier == Bundle.main.bundleIdentifier!
				)
			} else {
				guard let server = _server else {
					throw _error("Não foi possível iniciar o servidor de instalação.")
				}
				server.packageUrl = packageURL
				viewModel.status = .ready
			}
		} catch {
			_finish(error)
		}
	}

	private func _handle(_ status: InstallerStatusViewModel.InstallerStatus) {
		switch status {
		case .ready where _installationMethod == 0:
			_openServerInstallation()

		case .installing where _installationMethod == 0:
			_startProgressPolling()

		case .completed(let result):
			_progressTask?.cancel()
			_progressTask = nil
			switch result {
			case .success:
				_recordInstallationIfNeeded()
				_finish(nil)
			case .failure(let error):
				_finish(error)
			}

		case .broken(let error):
			_progressTask?.cancel()
			_progressTask = nil
			_finish(error)

		default:
			break
		}
	}

	private func _openServerInstallation() {
		guard let server = _server else {
			_finish(_error("Servidor de instalação indisponível."))
			return
		}

		let url: URL?
		if _serverMethod == 1 {
			url = server.pageEndpoint
		} else {
			url = URL(string: server.iTunesLink)
		}

		guard let url else {
			_finish(_error("Não foi possível gerar o link de instalação."))
			return
		}

		UIApplication.shared.open(url) { [weak self] opened in
			guard !opened else { return }
			Task { @MainActor in
				self?._finish(self?._error("O iOS recusou o link de instalação."))
			}
		}
	}

	private func _startProgressPolling() {
		guard _progressTask == nil, let bundleID = app.identifier else { return }

		_progressTask = Task.detached(priority: .background) { [weak self, viewModel] in
			var hasStarted = false

			while !Task.isCancelled {
				let raw = await UIApplication.installProgress(for: bundleID) ?? 0.0
				if raw > 0 { hasStarted = true }

				let normalized = hasStarted ? min(1.0, max(0.0, (raw - 0.6) / 0.3)) : 0.0
				Logger.misc.info("3.2 update install progress for \(bundleID): \(normalized)")

				await MainActor.run {
					viewModel.installProgress = normalized
				}

				if hasStarted, raw == 0 {
					await MainActor.run {
						viewModel.installProgress = 1.0
						viewModel.status = .completed(.success(()))
					}
					break
				}

				try? await Task.sleep(nanoseconds: 250_000_000)
			}

			_ = self
		}
	}

	private func _recordInstallationIfNeeded() {
		guard !_didRecordInstallation else { return }
		let provenance = UpdateManager.shared.provenanceForInstallation(of: app)
		let didRecord = InstallationRegistry.shared.recordInstallation(
			of: app,
			fallbackProvenance: provenance
		)
		_didRecordInstallation = didRecord
		if didRecord {
			UpdateManager.shared.reconcileInstallation(of: app)
		}
	}

	private func _finish(_ error: Error?) {
		guard !_finished else { return }
		_finished = true
		_statusObserver = nil
		_progressTask?.cancel()
		_progressTask = nil

		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.stop()
		#endif

		let completion = _completion
		_completion = nil
		completion?(error)
	}

	private func _error(_ message: String) -> Error {
		NSError(
			domain: "Feather.UpdateInstaller",
			code: -1,
			userInfo: [NSLocalizedDescriptionKey: message]
		)
	}
}
