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
	@State private var _enteredRecoveryKey = ""
	@State private var _showRecoveryKey = false
	@State private var _alertMessage: String?
	@State private var _isRestoreConfirmationPresented = false
	@State private var _isDisconnectConfirmationPresented = false
	
	var body: some View {
		NBNavigationView(.localized("Backup & Restore")) {
			Form {
				Section {
					Toggle(
						.localized("Cloud Backup"),
						isOn: Binding(
							get: { backupManager.isEnabled },
							set: { backupManager.setEnabled($0) }
						)
					)
					.disabled(backupManager.recoveryKey == nil)
					
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
					Text(.localized("Keep this key somewhere safe. After reinstalling Feather, enter the same key here and restore the backup."))
				}
				
				if backupManager.recoveryKey != nil {
					Section {
						Button(.localized("Back Up Now"), systemImage: "icloud.and.arrow.up") {
							_doBackupNow()
						}
						.disabled(backupManager.isBusy || !backupManager.isEnabled)
						
						Button(.localized("Restore Backup"), systemImage: "arrow.counterclockwise.icloud") {
							_isRestoreConfirmationPresented = true
						}
						.disabled(backupManager.isBusy)
						
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
	
	private var _lastBackupText: String {
		guard let date = backupManager.lastBackupDate else {
			return .localized("Never")
		}
		return date.formatted(date: .abbreviated, time: .shortened)
	}
	
	private func _maskedKey(_ key: String) -> String {
		guard key.hasPrefix("FTHR-") else { return "••••••••••••" }
		let masked = key.dropFirst(5).map { $0 == "-" ? "-" : "•" }
		return "FTHR-" + String(masked)
	}
	
	private func _doUseExistingKey() {
		do {
			try backupManager.useRecoveryKey(_enteredRecoveryKey)
			_enteredRecoveryKey = ""
			_alertMessage = .localized("Recovery key saved. If this is a new Feather installation, restore your backup before making changes to the update history.")
		} catch {
			_alertMessage = error.localizedDescription
		}
	}
	
	private func _doGenerateKey() {
		do {
			let generated = try backupManager.generateRecoveryKey()
			_showRecoveryKey = true
			UIPasteboard.general.string = generated
			_alertMessage = .localized("A new recovery key was generated and copied. Save it somewhere safe.")
			
			Task {
				try? await backupManager.backupNow()
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
				_alertMessage = .localized("Backup restored. %d update history records were recovered.", arguments: count)
			} catch {
				_alertMessage = error.localizedDescription
			}
		}
	}
}
