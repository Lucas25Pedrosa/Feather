from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


# Keep the main Tweaks & Updates screen compact. The complete source-app
# monitoring list now lives behind a navigation row, like installed-app
# management, while preserving all Beta 3 monitoring behavior.
view_path = "Feather/Views/Settings/TweakCatalogView.swift"
text = read(view_path)

if "private struct MonitoredAppsView: View" not in text:
    start_marker = '''\t\t\tSection {\n\t\t\t\tNavigationLink(destination: ManuallyInstalledAppsView()) {\n\t\t\t\t\tLabel("Gerenciar apps instalados", systemImage: "app.badge.checkmark")\n\t\t\t\t}\n\t\t\t} footer: {\n\t\t\t\tText("Cadastre aqui um app que já estava instalado antes do Feather começar a acompanhá-lo. Depois você poderá informar o tweak instalado.")\n\t\t\t}\n'''
    end_marker = "\n\t\t\tif !_records.isEmpty {"
    start = text.find(start_marker)
    if start < 0:
        raise SystemExit("ERRO: início do bloco de gerenciamento não encontrado em TweakCatalogView.swift")
    end = text.find(end_marker, start)
    if end < 0:
        raise SystemExit("ERRO: fim do bloco Apps monitorados não encontrado em TweakCatalogView.swift")

    replacement = '''\t\t\tSection {\n\t\t\t\tNavigationLink(destination: ManuallyInstalledAppsView()) {\n\t\t\t\t\tLabel("Gerenciar apps instalados", systemImage: "app.badge.checkmark")\n\t\t\t\t}\n\t\t\t\tNavigationLink(destination: MonitoredAppsView()) {\n\t\t\t\t\tLabel("Apps monitorados", systemImage: "eye")\n\t\t\t\t}\n\t\t\t} footer: {\n\t\t\t\tText("Gerencie os apps já cadastrados e escolha quais aplicativos das suas fontes o Feather deve acompanhar para tweaks e atualizações.")\n\t\t\t}\n'''
    text = text[:start] + replacement + text[end:]

    editor_marker = "\nprivate struct InstalledTweakEditorView: View {"
    insert_at = text.find(editor_marker)
    if insert_at < 0:
        raise SystemExit("ERRO: ponto de inserção da tela Apps monitorados não encontrado")

    monitored_view = r'''

private struct MonitoredAppsView: View {
	@StateObject private var _monitoring = SourceMonitoringPreferences.shared
	@StateObject private var _updates = UpdateManager.shared
	
	var body: some View {
		List {
			if _updates.sourceApps.isEmpty {
				Section {
					HStack(spacing: 10) {
						ProgressView()
						Text("Carregando apps das fontes…")
							.foregroundStyle(.secondary)
					}
				}
			} else {
				Section {
					ForEach(_updates.sourceApps) { app in
						Toggle(
							isOn: Binding(
								get: { _monitoring.isMonitored(app.bundleIdentifier) },
								set: { enabled in
									_monitoring.setMonitored(enabled, bundleIdentifier: app.bundleIdentifier)
									_updates.applyMonitoringPreferences()
									if enabled {
										Task {
											await _updates.checkForUpdates(sources: Storage.shared.getSources())
										}
									}
								}
							)
						) {
							VStack(alignment: .leading, spacing: 2) {
								Text(app.name)
								Text(app.bundleIdentifier)
									.font(.caption2)
									.foregroundStyle(.secondary)
							}
						}
					}
				} footer: {
					Text("Desative um app para ocultá-lo de Tweaks instalados e impedir que suas atualizações entrem na lista ou no badge. O app continua disponível normalmente nas Fontes e seu registro é preservado.")
				}
			}
		}
		.navigationTitle("Apps monitorados")
		.task {
			await _updates.checkForUpdates(sources: Storage.shared.getSources())
		}
	}
}
'''
    text = text[:insert_at] + monitored_view + text[insert_at:]
    write(view_path, text)


# Beta 3's appearance-only badge offset can be overwritten by the iOS 27
# Liquid Glass tab bar during layout/selection. Beta 4 reapplies the public
# UITabBar appearance after layout and also nudges the rendered native badge
# container as a runtime fallback. This changes only badge geometry.
tab_path = "Feather/Views/TabView/Bars/TabbarView.swift"
tab_text = read(tab_path)
marker = "\n\nprivate struct _TabBarBadgePositionConfigurator: UIViewControllerRepresentable {"
marker_at = tab_text.find(marker)
if marker_at < 0:
    raise SystemExit("ERRO: configurador do badge não encontrado em TabbarView.swift")

new_configurator = r'''

private struct _TabBarBadgePositionConfigurator: UIViewControllerRepresentable {
	func makeUIViewController(context: Context) -> Controller {
		Controller()
	}

	func updateUIViewController(_ uiViewController: Controller, context: Context) {
		uiViewController.scheduleBadgePositionUpdate()
	}

	final class Controller: UIViewController {
		override func viewDidAppear(_ animated: Bool) {
			super.viewDidAppear(animated)
			scheduleBadgePositionUpdate()
		}

		override func viewDidLayoutSubviews() {
			super.viewDidLayoutSubviews()
			scheduleBadgePositionUpdate()
		}

		func scheduleBadgePositionUpdate() {
			// SwiftUI/iOS 27 may rebuild the Liquid Glass tab-bar appearance after
			// this representable first appears. Reapply after those layout passes.
			_applyBadgePosition(after: 0)
			_applyBadgePosition(after: 0.05)
			_applyBadgePosition(after: 0.20)
		}

		private func _applyBadgePosition(after delay: TimeInterval) {
			DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
				guard
					let root = self?.view.window?.rootViewController,
					let tabBarController = Self.findTabBarController(in: root)
				else {
					return
				}

				let tabBar = tabBarController.tabBar
				let appearance = tabBar.standardAppearance
				let offset = UIOffset(horizontal: 18, vertical: -11)
				let layouts = [
					appearance.stackedLayoutAppearance,
					appearance.inlineLayoutAppearance,
					appearance.compactInlineLayoutAppearance,
				]
				for layout in layouts {
					layout.normal.badgePositionAdjustment = offset
					layout.selected.badgePositionAdjustment = offset
					layout.focused.badgePositionAdjustment = offset
					layout.disabled.badgePositionAdjustment = offset
				}
				tabBar.standardAppearance = appearance
				tabBar.scrollEdgeAppearance = appearance

				// Runtime fallback for the floating selected-tab presentation, which
				// can ignore/rewrite badgePositionAdjustment on iOS 27.
				for badgeView in Self.outermostBadgeViews(in: tabBar) {
					badgeView.transform = CGAffineTransform(translationX: 5, y: -4)
				}
			}
		}

		private static func outermostBadgeViews(in view: UIView) -> [UIView] {
			var result: [UIView] = []
			for subview in view.subviews {
				let className = NSStringFromClass(type(of: subview)).lowercased()
				if className.contains("badge") {
					// Move only the badge container, not its text/background children.
					result.append(subview)
					continue
				}
				result.append(contentsOf: outermostBadgeViews(in: subview))
			}
			return result
		}

		private static func findTabBarController(in controller: UIViewController) -> UITabBarController? {
			if let tabBarController = controller as? UITabBarController {
				return tabBarController
			}
			if let presented = controller.presentedViewController,
			   let match = findTabBarController(in: presented) {
				return match
			}
			for child in controller.children {
				if let match = findTabBarController(in: child) {
					return match
				}
			}
			return nil
		}
	}
}
'''
write(tab_path, tab_text[:marker_at] + new_configurator)

print("Feather 3.1 Beta 4: UI compacta e correção reforçada do badge aplicadas.")
