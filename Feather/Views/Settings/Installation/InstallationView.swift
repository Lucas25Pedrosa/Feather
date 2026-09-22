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
				Toggle(isOn: $_preferences.quickInstallEnabled) {
					Label("Instalação rápida", systemImage: "bolt.fill")
				}

				if _preferences.quickInstallEnabled && _certificates.count >= 2 {
					NavigationLink {
						QuickInstallCertificatePickerView()
					} label: {
						HStack {
							Label("Certificado padrão", systemImage: "checkmark.seal")
							Spacer()
							Text(_selectedCertificateName)
								.foregroundStyle(.secondary)
								.lineLimit(1)
						}
					}
				}
			} footer: {
				if !_preferences.quickInstallEnabled {
					Text("Desativada: o Feather mantém o fluxo manual de assinatura.")
				} else if _certificates.isEmpty {
					Text("Importe um certificado para usar a Instalação rápida. Sem certificado, o fluxo continua manual.")
				} else if _certificates.count == 1 {
					Text("O único certificado importado será usado automaticamente para baixar, assinar e instalar.")
				} else if _preferences.usableCertificate() == nil {
					Text("Selecione o certificado padrão que será usado pela Instalação rápida.")
				} else {
					Text("O Feather baixa, aplica personalizações predefinidas quando existirem, assina e instala automaticamente.")
				}
			}

			if _preferences.quickInstallEnabled,
			   _certificates.count >= 2,
			   let selected = _preferences.selectedCertificate(),
			   selected.revoked == true || _isExpired(selected) {
				Section {
					Label("O certificado selecionado não está mais válido. Escolha outro certificado para usar a Instalação rápida.", systemImage: "exclamationmark.triangle.fill")
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
					Text("Após uma instalação concluída, o Feather também remove da própria biblioteca todas as cópias em Importados e Assinados. O aplicativo já instalado no iOS não é apagado. Certificados, sources, personalizações predefinidas, ícones personalizados, registro de tweaks, histórico de atualizações e backups são preservados.")
				} else {
					Text("A segunda opção é destrutiva e fica desativada por padrão. Ela só atua na limpeza automática após uma instalação concluída. Personalizações predefinidas e seus ícones são preservados.")
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

	private var _selectedCertificateName: String {
		guard let certificate = _preferences.selectedCertificate() else {
			return "Selecionar"
		}
		return certificate.nickname
			?? Storage.shared.getProvisionFileDecoded(for: certificate)?.Name
			?? "Certificado"
	}

	private func _isExpired(_ certificate: CertificatePair) -> Bool {
		guard let expiration = certificate.expiration else { return true }
		return expiration <= Date()
	}
}

// MARK: - Quick install certificate picker
private struct QuickInstallCertificatePickerView: View {
	@StateObject private var _preferences = UpdateEnginePreferences.shared

	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>

	var body: some View {
		NBList("Certificado padrão") {
			Section {
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
			} footer: {
				Text("Este certificado será usado somente quando houver mais de um certificado importado e a Instalação rápida estiver ativada.")
			}
		}
	}

	private func _isExpired(_ certificate: CertificatePair) -> Bool {
		guard let expiration = certificate.expiration else { return true }
		return expiration <= Date()
	}
}
