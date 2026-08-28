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
				}
			} footer: {
				Text("Remove manualmente caches de rede, cache interno e resíduos temporários seguros do Feather.")
			}

			Section {
				Toggle(isOn: $_automaticCleanup) {
					Label("Limpar cache após instalação", systemImage: "sparkles")
				}
			} footer: {
				Text("Quando ativado, o Feather executa a mesma limpeza segura automaticamente depois que uma instalação é concluída.")
			}

			Section {
				Label("Conteúdo protegido", systemImage: "checkmark.shield")
			} footer: {
				Text("Aplicativos importados ou assinados, certificados, sources, tweaks, histórico de atualizações e backups não são apagados pela limpeza de cache.")
			}
		}
	}

	private func _formattedSize(_ bytes: Int64) -> String {
		ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
	}
}
