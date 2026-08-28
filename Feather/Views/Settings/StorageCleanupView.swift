//
//  StorageCleanupView.swift
//  Feather
//
//  Feather 3.2 storage cleanup controls.
//

import SwiftUI
import NimbleViews

struct StorageCleanupView: View {
	@StateObject private var cleanupManager = StorageCleanupManager.shared
	@AppStorage(StorageCleanupManager.automaticCleanupKey) private var _automaticCleanup = false
	@AppStorage(StorageCleanupManager.automaticPurgeAppsKey) private var _automaticPurgeApps = false

	var body: some View {
		NBList("Cache e armazenamento") {
			Section {
				Button {
					Task {
						await cleanupManager.cleanNow()
					}
				} label: {
					HStack {
						Label("Limpar cache agora", systemImage: "trash.slash")
						Spacer()
						if cleanupManager.isCleaning {
							ProgressView()
						}
					}
				}
				.disabled(cleanupManager.isCleaning)

				if let report = cleanupManager.lastReport {
					LabeledContent("Espaço liberado") {
						Text(_formattedSize(report.bytesFreed))
							.foregroundStyle(.secondary)
					}

					if report.removedStoredApps > 0 {
						LabeledContent("Apps removidos da biblioteca") {
							Text("\(report.removedStoredApps)")
								.foregroundStyle(.secondary)
						}
					}
				}
			} footer: {
				Text("A limpeza manual remove somente caches de rede, cache interno e resíduos temporários seguros do Feather. Ela nunca apaga aplicativos importados ou assinados.")
			}

			Section {
				Toggle(isOn: $_automaticCleanup) {
					Label("Limpar cache após instalação", systemImage: "sparkles")
				}

				Toggle(isOn: $_automaticPurgeApps) {
					Label("Também apagar importados e assinados", systemImage: "trash")
				}
				.disabled(!_automaticCleanup)
			} footer: {
				if _automaticPurgeApps && _automaticCleanup {
					Text("Após uma instalação concluída, o Feather também remove da própria biblioteca todas as cópias em Importados e Assinados. O aplicativo já instalado no iOS não é apagado. Certificados, sources, registro de tweaks, histórico de atualizações e backups são preservados.")
			} else {
					Text("A segunda opção é destrutiva e fica desativada por padrão. Ela só atua na limpeza automática após uma instalação concluída; o botão manual continua seguro.")
			}
			}

			Section {
				Label("Conteúdo protegido", systemImage: "checkmark.shield")
			} footer: {
				Text("Certificados, sources, tweaks registrados, histórico de atualizações e backups não são apagados pela limpeza. Importados e Assinados só são removidos quando a opção específica acima estiver ativada.")
			}
		}
	}

	private func _formattedSize(_ bytes: Int64) -> String {
		ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
	}
}
