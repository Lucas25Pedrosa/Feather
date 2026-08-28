//
//  UpdateEngineSettingsView.swift
//  Feather
//
//  Feather 3.2 automatic update configuration.
//

import SwiftUI

struct UpdateEngineSettingsView: View {
	@StateObject private var _preferences = UpdateEnginePreferences.shared

	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>

	var body: some View {
		List {
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
				Text("Sem um certificado padrão, Atualizar mantém o fluxo manual da 3.1 e abre a tela de assinatura depois do download.")
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
		}
		.navigationTitle("Atualizações e instalação")
	}

	private func _isExpired(_ certificate: CertificatePair) -> Bool {
		guard let expiration = certificate.expiration else { return true }
		return expiration <= Date()
	}
}
