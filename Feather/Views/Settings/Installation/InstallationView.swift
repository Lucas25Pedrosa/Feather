//
//  InstallationView.swift
//  Feather
//
//  Created by samara on 3.06.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct InstallationView: View {
	@AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
	@AppStorage(StorageCleanupManager.automaticCleanupKey) private var _automaticCleanup = false
	@AppStorage(StorageCleanupManager.automaticPurgeAppsKey) private var _automaticPurgeApps = false
	@State private var _showMethodChangedAlert = false
	@StateObject private var _preferences = UpdateEnginePreferences.shared

	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>

	private let _installationMethods: [String] = [
		.localized("Server"),
		.localized("idevice")
	]
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Installation")) {
			Section {
				Picker(.localized("Installation Type"), systemImage: "arrow.down.app", selection: $_installationMethod) {
					ForEach(_installationMethods.indices, id: \.description) { index in
						Text(_installationMethods[index]).tag(index)
					}
				}
			} footer: {
				Text(.localized("Server (Recommended):\nUses a locally hosted server and itms-services:// to install applications.\n\nIDevice (advanced):\nUses a VPN and a pairing file. Writes to AFC and manually calls installd, while monitoring install progress by using a callback\nAdvantage: It is very reliable, does not need SSL certificates or a externally hosted server. Rather, works similarly to a computer."))
			}

			if _installationMethod == 0 {
				ServerView()
			} else if _installationMethod == 1 {
				TunnelView()
			}

			Section {
				Button {
					_preferences.selectCertificate(nil)
				} label: {
					HStack {
						Label("Assinatura manual", systemImage: "hand.tap")
						Spacer()
						if _preferences.defaultCertificateUUID == nil {
							Image(systemName: "checkmark")
								.foregroundStyle(Color.accentColor)
						}
					}
				}
				.buttonStyle(.plain)
			} header: {
				Text("Comportamento")
			} footer: {
				Text("Sem um certificado padrão, Atualizar mantém o fluxo manual e abre a tela de assinatura depois do download.")
			}

			Section {
				if _certificates.isEmpty {
					Text("Nenhum certificado importado.")
						.foregroundStyle(.secondary)
				} else {
					ForEach(_certificates, id: \.objectID) { certificate in
						Button {
							_preferences.selectCertificate(certificate)
						} label: {
							HStack(spacing: 12) {
								CertificatesCellView(cert: certificate)
								Spacer(minLength: 8)
								if _preferences.defaultCertificateUUID == certificate.uuid {
									Image(systemName: "checkmark.circle.fill")
										.foregroundStyle(Color.accentColor)
								}
							}
							.contentShape(Rectangle())
						}
						.buttonStyle(.plain)
						.disabled(certificate.revoked == true || _isExpired(certificate))
					}
				}
			} header: {
				Text("Certificado padrão")
			} footer: {
				Text("Quando um certificado válido é escolhido, Atualizar executa baixar → assinar → instalar. A preferência é vinculada ao UUID do certificado e não muda se a lista for reordenada.")
			}

			if let selected = _preferences.selectedCertificate(),
			   selected.revoked == true || _isExpired(selected) {
				Section {
					Label("O certificado selecionado não está mais válido. As atualizações voltarão ao modo manual até você escolher outro.", systemImage: "exclamationmark.triangle.fill")
						.foregroundStyle(.orange)
				}
			}

			Section {
				Toggle(isOn: $_automaticCleanup) {
					Label("Limpar cache após instalação", systemImage: "sparkles")
				}

				Toggle(isOn: $_automaticPurgeApps) {
					Label("Também apagar importados e assinados", systemImage: "trash")
				}
				.disabled(!_automaticCleanup)
			} header: {
				Text("Limpeza automática")
			} footer: {
				if _automaticPurgeApps && _automaticCleanup {
					Text("Após uma instalação concluída, o Feather também remove da própria biblioteca todas as cópias em Importados e Assinados. O aplicativo já instalado no iOS não é apagado. Certificados, sources, registro de tweaks, histórico de atualizações e backups são preservados.")
				} else {
					Text("A segunda opção é destrutiva e fica desativada por padrão. Ela só atua na limpeza automática após uma instalação concluída.")
				}
			}
		}
		.onChange(of: _installationMethod) { newValue in
			guard newValue == 1 else { return }
			_showMethodChangedAlert = true
		}
		.alert(.localized("Advanced Installation Method"), isPresented: $_showMethodChangedAlert) {
			Button(.localized("Switch Back"), role: .destructive) {
				_installationMethod = 0
			}
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(.localized("idevice warning"))
		}
		.animation(.default, value: _installationMethod)
	}

	private func _isExpired(_ certificate: CertificatePair) -> Bool {
		guard let expiration = certificate.expiration else { return true }
		return expiration <= Date()
	}
}
