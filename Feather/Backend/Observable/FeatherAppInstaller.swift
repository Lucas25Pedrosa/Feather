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

private struct FeatherInstalledAppSnapshot: Equatable, Sendable {
	let bundleURL: String?
	let modificationTime: TimeInterval?
}

private enum FeatherInstalledAppLookup {
	static func snapshot(for identifier: String) -> FeatherInstalledAppSnapshot? {
		let classNameBase64 = "TFNBcHBsaWNhdGlvblByb3h5" // LSApplicationProxy
		let proxySelectorBase64 = "YXBwbGljYXRpb25Qcm94eUZvcklkZW50aWZpZXI6" // applicationProxyForIdentifier:
		let bundleURLSelectorBase64 = "YnVuZGxlVVJM" // bundleURL
		let modTimeSelectorBase64 = "YnVuZGxlTW9kVGltZQ==" // bundleModTime

		guard
			let classNameData = Data(base64Encoded: classNameBase64),
			let proxySelectorData = Data(base64Encoded: proxySelectorBase64),
			let bundleURLSelectorData = Data(base64Encoded: bundleURLSelectorBase64),
			let modTimeSelectorData = Data(base64Encoded: modTimeSelectorBase64),
			let className = String(data: classNameData, encoding: .utf8),
			let proxySelector = String(data: proxySelectorData, encoding: .utf8),
			let bundleURLSelector = String(data: bundleURLSelectorData, encoding: .utf8),
			let modTimeSelector = String(data: modTimeSelectorData, encoding: .utf8),
			let proxyClass = NSClassFromString(className) as? NSObject.Type,
			let proxy = proxyClass.perform(
				NSSelectorFromString(proxySelector),
				with: identifier
			)?.takeUnretainedValue() as? NSObject
		else {
			return nil
		}

		let bundleURL = proxy.perform(
			NSSelectorFromString(bundleURLSelector)
		)?.takeUnretainedValue() as? URL
		let modificationDate = proxy.perform(
			NSSelectorFromString(modTimeSelector)
		)?.takeUnretainedValue() as? Date

		guard bundleURL != nil || modificationDate != nil else { return nil }
		return FeatherInstalledAppSnapshot(
			bundleURL: bundleURL?.absoluteString,
			modificationTime: modificationDate?.timeIntervalSince1970
		)
	}
}

@MainActor
final class FeatherAppInstaller: ObservableObject {
	let app: AppInfoPresentable
	let viewModel: InstallerStatusViewModel

	private let _installationMethod: Int
	private let _serverMethod: Int
	private let _initialInstallSnapshot: FeatherInstalledAppSnapshot?
	private var _server: ServerInstaller?
	private var _statusObserver: AnyCancellable?
	private var _progressTask: Task<Void, Never>?
	private var _completion: ((Error?) -> Void)?
	private var _installWorkDirectory: URL?
	private var _finished = false
	private var _didRecordInstallation = false

	init(app: AppInfoPresentable) throws {
		self.app = app
		self._installationMethod = UserDefaults.standard.integer(forKey: "Feather.installationMethod")
		self._serverMethod = UserDefaults.standard.integer(forKey: "Feather.serverMethod")
		self.viewModel = InstallerStatusViewModel(isIdevice: _installationMethod == 1)
		self._initialInstallSnapshot = app.identifier.flatMap {
			FeatherInstalledAppLookup.snapshot(for: $0)
		}

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
		_cleanupInstallWorkspace()
		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.stop()
		#endif
	}

	private func _prepareAndInstall() async {
		do {
			let app = app
			let viewModel = viewModel
			let packageURL = try await Task.detached(priority: .userInitiated) {
				let handler = await ArchiveHandler(app: app, viewModel: viewModel)
				try await handler.move()
				return try await handler.archive()
			}.value
			_installWorkDirectory = packageURL.deletingLastPathComponent()

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

		let primaryLink = _serverMethod == 1 ? server.iTunesLinkExternal : server.iTunesLink
		guard let primaryURL = URL(string: primaryLink) else {
			_finish(_error("Não foi possível gerar o link de instalação."))
			return
		}

		UIApplication.shared.open(primaryURL) { [weak self] opened in
			guard let self else { return }
			guard !opened else { return }

			Task { @MainActor in
				if self._serverMethod == 1 {
					UIApplication.shared.open(server.pageEndpoint) { fallbackOpened in
						if !fallbackOpened {
							Task { @MainActor in
								self._finish(self._error("O iOS recusou o link de instalação."))
							}
						}
					}
				} else {
					self._finish(self._error("O iOS recusou o link de instalação."))
				}
			}
		}
	}

	private func _startProgressPolling() {
		guard _progressTask == nil, let bundleID = app.identifier else { return }
		let initialSnapshot = _initialInstallSnapshot

		// ServerInstaller only emits .installing after streamFile finished
		// successfully. At this point the full IPA has already been delivered
		// to installd. Some iOS releases never publish LS installProgress for
		// sideloaded replacements, so a bounded grace period is used as the
		// final fallback instead of leaving Feather stuck forever.
		_progressTask = Task.detached(priority: .background) { [viewModel] in
			var hasStarted = false
			let startedAt = Date()
			let fallbackDelay: TimeInterval = 10

			while !Task.isCancelled {
				let elapsed = Date().timeIntervalSince(startedAt)
				let raw = await UIApplication.installProgress(for: bundleID) ?? 0.0
				if raw > 0 { hasStarted = true }

				let nativeProgress = hasStarted
					? min(1.0, max(0.0, (raw - 0.6) / 0.3))
					: 0.0
				let fallbackProgress = min(0.95, max(0.05, elapsed / fallbackDelay * 0.95))
				let visibleProgress = hasStarted ? nativeProgress : fallbackProgress

				let currentSnapshot = await MainActor.run {
					FeatherInstalledAppLookup.snapshot(for: bundleID)
				}
				let didReplaceApplication = currentSnapshot != nil && currentSnapshot != initialSnapshot

				Logger.misc.info(
					"3.2 install verification for \(bundleID): native=\(nativeProgress), replacement=\(didReplaceApplication), elapsed=\(elapsed)"
				)

				await MainActor.run {
					viewModel.installProgress = visibleProgress
				}

				if (hasStarted && raw == 0) || didReplaceApplication {
					await MainActor.run {
						viewModel.installProgress = 1.0
						viewModel.status = .completed(.success(()))
					}
					break
				}

				if elapsed >= fallbackDelay {
					Logger.misc.info(
						"Completing \(bundleID) using payload-delivered fallback after \(elapsed)s"
					)
					await MainActor.run {
						viewModel.installProgress = 1.0
						viewModel.status = .completed(.success(()))
					}
					break
				}

				try? await Task.sleep(nanoseconds: 250_000_000)
			}
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

	private func _cleanupInstallWorkspace() {
		guard let workDirectory = _installWorkDirectory else { return }
		try? FileManager.default.removeItem(at: workDirectory)
		_installWorkDirectory = nil
	}

	private func _finish(_ error: Error?) {
		guard !_finished else { return }
		_finished = true
		_statusObserver = nil
		_progressTask?.cancel()
		_progressTask = nil
		_cleanupInstallWorkspace()

		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.stop()
		#endif

		if error == nil {
			StorageCleanupManager.shared.scheduleAutomaticCleanup()
		}

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
