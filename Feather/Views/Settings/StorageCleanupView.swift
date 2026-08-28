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

	var body: some View {
		NBList("Armazenamento") {
			Section {
				Toggle(isOn: $_automaticCleanup) {
					Label("Limpar cache após instalação", systemImage: "sparkles")
				}
			} footer: {
				Text("Quando ativado, o Feather limpa caches e resíduos temporários com segurança depois que uma instalação é concluída.")
			}

			Section {
				Button {
					Task {
						await cleanupManager.cleanNow()
					}
				} label: {
					HStack {
						Label("Liberar espaço agora", systemImage: "trash.slash")
						Spacer()
						if cleanupManager.isCleaning {
							ProgressView()
						}
					}
				}
				.disabled(cleanupManager.isCleaning)

				if let report = cleanupManager.lastReport {
					LabeledContent("Última limpeza") {
						Text(_formattedSize(report.bytesFreed))
							.foregroundStyle(.secondary)
					}
				}
			} footer: {
				Text("Remove cache de rede, cache interno e arquivos temporários abandonados do Feather. Aplicativos importados ou assinados, certificados, sources, tweaks, histórico de atualizações e backups não são apagados.")
			}
		}
	}

	private func _formattedSize(_ bytes: Int64) -> String {
		ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
	}
}
