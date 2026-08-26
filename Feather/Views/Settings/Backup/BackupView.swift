//
//  BackupView.swift
//  Feather
//
//  Cloud backup settings for update history.
//

import NimbleViews
import SwiftUI
import UIKit

struct BackupView: View {
	@StateObject private var backupManager = BackupManager.shared
	@StateObject private var installationRegistry = InstallationRegistry.shared
	@State private var _serverURL = ""
	@State private var _enteredRecoveryKey = ""
	@State private var _showRecoveryKey = false
	@State private var _alertMessage: String?
	@State private var _isRestoreConfirmationPresented = false
	@State private var _isDisconnectConfirmationPresented = false
	
	var body: some View {
		NBNavigationView(.localized("Backup & Restore")) {
			Form {
				Section {
					TextField(.localized("Server URL"), text: $_serverURL)
						.keyboardType(.URL)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.onSubmit {
							_doConnect()
						}
					
					HStack {
						Text(.localized("Status"))
						Spacer()
						_connectionStatus
					}
					
					Button(.localized("Connect"), systemImage: "network") {
						_doConnect()
					}
					.disabled(
						backupManager.recoveryKey == nil
							|| _serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
							|| backupManager.connectionState == .checking
					)
				} header: {
					Text(.localized("Backup Server"))
				} footer: {
					if case .failed(let message) = backupManager.connectionState {
						Text(message)
					} else {
						Text(.localized("Enter the address of a compatible Feather backup server. The server and recovery key are validated before backup is enabled."))
					}
				}
				
				Section {
					if let formattedKey = backupManager.formattedRecoveryKey {
						VStack(alignment: .leading, spacing: 8) {
							Text(_showRecoveryKey ? formattedKey : _maskedKey(formattedKey))
								.font(.system(.footnote, design: .monospaced))
								.textSelection(.enabled)
							
							HStack {
								Button(_showRecoveryKey ? .localized("Hide Key") : .localized("Show Key")) {
									_showRecoveryKey.toggle()
								}
								
								Spacer()
								
								Button(.localized("Copy Key")) {
									UIPasteboard.general.string = formattedKey
									_alertMessage = .localized("Recovery key copied.")
								}
							}
						}
						
						Button(.localized("Remove Recovery Key"), role: .destructive) {
							_isDisconnectConfirmationPresented = true
						}
					} else {
						TextField(.localized("Recovery Key"), text: $_enteredRecoveryKey)
							.font(.system(.body, design: .monospaced))
							.textInputAutocapitalization(.characters)
							.autocorrectionDisabled()
						
						Button(.localized("Use Existing Recovery Key")) {
							_doUseExistingKey()
						}
						.disabled(_enteredRecoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
						
						Button(.localized("Generate Recovery Key")) {
							_doGenerateKey()
						}
					}
				} header: {
					Text(.localized("Recovery Key"))
				} footer: {
					Text(.localized("Keep this key somewhere safe. After reinstalling Feather, enter the same server URL and recovery key, connect, and restore the backup."))
				}
				
				Section {
					NavigationLink(destination: ManuallyInstalledAppsView()) {
						HStack {
							Label(.localized("Manage Installed Apps"), systemImage: "app.badge.checkmark")
							Spacer()
							Text(installationRegistry.records.count.description)
								.foregroundStyle(.secondary)
						}
					}
				} header: {
					Text(.localized("Installed Apps"))
				} footer: {
					Text(.localized("Register apps that were already installed before Feather began tracking them. Their saved versions are used to detect newer versions from your sources and are included in cloud backup."))
				}
				
				Section {
					Toggle(
						.localized("Cloud Backup"),
						isOn: Binding(
							get: { backupManager.isEnabled },
							set: { backupManager.setEnabled($0) }
						)
					)
					.disabled(!backupManager.isConnected)
					
					HStack {
						Text(.localized("Last Backup"))
						Spacer()
						Text(_lastBackupText)
							.foregroundStyle(.secondary)
					}
				} header: {
					Text(.localized("Cloud Backup"))
				} footer: {
					Text(.localized("Your update history is encrypted on this iPhone before it is uploaded. The recovery key is never sent to the backup service."))
				}
				
				if backupManager.recoveryKey != nil {
					Section {
						Button(.localized("Back Up Now"), systemImage: "icloud.and.arrow.up") {
							_doBackupNow()
						}
						.disabled(backupManager.isBusy || !backupManager.isEnabled || !backupManager.isConnected)
						
						Button(.localized("Restore Backup"), systemImage: "arrow.counterclockwise.icloud") {
							_isRestoreConfirmationPresented = true
						}
						.disabled(backupManager.isBusy || !backupManager.isConnected)
						
						if backupManager.isBusy {
							HStack {
								ProgressView()
								Text(.localized("Working…"))
									.foregroundStyle(.secondary)
							}
						}
					} header: {
						Text(.localized("Actions"))
					} footer: {
						Text(.localized("Restore replaces the local update history with the encrypted cloud backup. Your installed apps and IPA files are not changed."))
					}
				}
			}
		}
		.onAppear {
			if _serverURL.isEmpty {
				_serverURL = backupManager.serverURLString
			}
		}
		.task {
			guard
				backupManager.recoveryKey != nil,
				!backupManager.serverURLString.isEmpty
			else {
				return
			}
			
			if _serverURL.isEmpty {
				_serverURL = backupManager.serverURLString
			}
			await backupManager.refreshConnection()
		}
		.alert(
			.localized("Cloud Backup"),
			isPresented: Binding(
				get: { _alertMessage != nil },
				set: { if !$0 { _alertMessage = nil } }
			)
		) {
			Button(.localized("OK"), role: .cancel) { }
		} message: {
			Text(_alertMessage ?? "")
		}
		.confirmationDialog(
			.localized("Restore Backup?"),
			isPresented: $_isRestoreConfirmationPresented,
			titleVisibility: .visible
		) {
			Button(.localized("Restore Backup"), role: .destructive) {
				_doRestore()
			}
			Button(.localized("Cancel"), role: .cancel) { }
		} message: {
			Text(.localized("The local update history will be replaced by the cloud backup."))
		}
		.confirmationDialog(
			.localized("Remove Recovery Key?"),
			isPresented: $_isDisconnectConfirmationPresented,
			titleVisibility: .visible
		) {
			Button(.localized("Remove Recovery Key"), role: .destructive) {
				backupManager.disconnect()
				_showRecoveryKey = false
			}
			Button(.localized("Cancel"), role: .cancel) { }
		} message: {
			Text(.localized("The cloud backup is not deleted, but you will need the recovery key to access it again."))
		}
	}
	
	@ViewBuilder
	private var _connectionStatus: some View {
		switch backupManager.connectionState {
		case .checking:
			HStack(spacing: 6) {
				ProgressView()
				Text(.localized("Connecting…"))
					.foregroundStyle(.secondary)
			}
		case .connected:
			Text("Conectado")
				.fontWeight(.semibold)
				.foregroundStyle(.green)
		case .failed(_):
			Text(.localized("Not Connected"))
				.foregroundStyle(.red)
		case .idle:
			Text(.localized("Not Connected"))
				.foregroundStyle(.secondary)
		}
	}
	
	private var _lastBackupText: String {
		guard let date = backupManager.lastBackupDate else {
			return .localized("Never")
		}
		return date.formatted(date: .abbreviated, time: .shortened)
	}
	
	private func _maskedKey(_ key: String) -> String {
		guard key.hasPrefix("FTHR-") else { return "••••••••••••" }
		let masked: [Character] = key.dropFirst(5).map { character in
			character == "-" ? Character("-") : Character("•")
		}
		return "FTHR-" + String(masked)
	}
	
	private func _doConnect() {
		Task {
			do {
				try await backupManager.connect(serverURL: _serverURL)
				_serverURL = backupManager.serverURLString
			} catch {
				_alertMessage = error.localizedDescription
			}
		}
	}
	
	private func _doUseExistingKey() {
		do {
			try backupManager.useRecoveryKey(_enteredRecoveryKey)
			_enteredRecoveryKey = ""
			
			if !_serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				_doConnect()
			} else {
				_alertMessage = .localized("Recovery key saved. Enter the backup server URL to connect.")
			}
		} catch {
			_alertMessage = error.localizedDescription
		}
	}
	
	private func _doGenerateKey() {
		do {
			let generated = try backupManager.generateRecoveryKey()
			_showRecoveryKey = true
			UIPasteboard.general.string = generated
			
			if !_serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				Task {
					do {
						try await backupManager.connect(serverURL: _serverURL)
						_serverURL = backupManager.serverURLString
						backupManager.setEnabled(true)
						try await backupManager.backupNow()
						_alertMessage = .localized("A new recovery key was generated, copied, connected, and backed up. Save the key somewhere safe.")
					} catch {
						_alertMessage = error.localizedDescription
					}
				}
			} else {
				_alertMessage = .localized("A new recovery key was generated and copied. Save it somewhere safe, then enter the backup server URL to connect.")
			}
		} catch {
			_alertMessage = error.localizedDescription
		}
	}
	
	private func _doBackupNow() {
		Task {
			do {
				try await backupManager.backupNow()
				_alertMessage = .localized("Backup completed successfully.")
			} catch {
				_alertMessage = error.localizedDescription
			}
		}
	}
	
	private func _doRestore() {
		Task {
			do {
				let count = try await backupManager.restoreCurrentBackup()
				backupManager.setEnabled(true)
				_alertMessage = .localized("Backup restored. %d update history records were recovered.", arguments: count)
			} catch {
				_alertMessage = error.localizedDescription
			}
		}
	}
}
