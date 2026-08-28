//
//  StorageCleanupView.swift
//  Feather
//
//  Feather 3.2 storage cleanup controls.
//

import SwiftUI
import NimbleViews

struct StorageCleanupView: View {
	@AppStorage(StorageCleanupManager.automaticCleanupKey) private var _automaticCleanup = false
	@AppStorage(StorageCleanupManager.automaticPurgeAppsKey) private var _automaticPurgeApps = false

	var body: some View {
		NBList("Cache e armazenamento") {
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
					Text("A segunda opção é destrutiva e fica desativada por padrão. Ela só atua na limpeza automática após uma instalação concluída.")
				}
			}
		}
	}
}
