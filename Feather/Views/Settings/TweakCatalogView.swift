//
//  TweakCatalogView.swift
//  Feather
//
//  Beta 2 tweak catalog and installed-package configuration.
//

import SwiftUI

struct TweakCatalogView: View {
	@StateObject private var _catalog = TweakCatalogManager.shared
	@StateObject private var _monitoring = SourceMonitoringPreferences.shared
	@StateObject private var _updates = UpdateManager.shared
	@ObservedObject private var _registry = InstallationRegistry.shared
	@State private var _catalogURL = ""
	@State private var _alertMessage: String?
	
	private var _records: [InstalledSourceAppRecord] {
		_registry.records
			.filter { _monitoring.isMonitored($0.localBundleIdentifier) }
			.sorted {
			($0.appName ?? $0.localBundleIdentifier)
				.localizedCaseInsensitiveCompare($1.appName ?? $1.localBundleIdentifier) == .orderedAscending
		}
	}
	
	var body: some View {
		Form {
			Section {
				TextField("URL do catálogo", text: $_catalogURL)
					.keyboardType(.URL)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
				
				Button("Salvar e atualizar", systemImage: "arrow.triangle.2.circlepath") {
					_saveAndRefresh()
				}
				.disabled(_catalog.isRefreshing || _catalogURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
				
				Button("Usar catálogo padrão", systemImage: "arrow.uturn.backward") {
					_catalog.resetCatalogURL()
					_catalogURL = _catalog.catalogURLString
					Task { await _catalog.refresh(force: true) }
				}
				
				HStack {
					Text("Status")
					Spacer()
					if _catalog.isRefreshing {
						ProgressView()
					} else if _catalog.catalog != nil {
						Text("Disponível")
							.foregroundStyle(.green)
					} else {
						Text("Não carregado")
							.foregroundStyle(.secondary)
					}
				}
				
				if let lastUpdated = _catalog.lastUpdated {
					HStack {
						Text("Última atualização")
						Spacer()
						Text(lastUpdated.formatted(date: .abbreviated, time: .shortened))
							.foregroundStyle(.secondary)
					}
				}
			} header: {
				Text("Catálogo de tweaks")
			} footer: {
				VStack(alignment: .leading, spacing: 4) {
					Text("O catálogo informa quais versões estão disponíveis. Ele nunca altera sozinho a versão registrada como instalada neste iPhone.")
					if let error = _catalog.lastError {
						Text(error)
							.foregroundStyle(.red)
					}
				}
			}
			
			Section {
				NavigationLink(destination: ManuallyInstalledAppsView()) {
					Label("Gerenciar apps instalados", systemImage: "app.badge.checkmark")
				}
			} footer: {
				Text("Cadastre aqui um app que já estava instalado antes do Feather começar a acompanhá-lo. Depois você poderá informar o tweak instalado.")
			}
			
			if !_updates.sourceApps.isEmpty {
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
				} header: {
					Text("Apps monitorados")
				} footer: {
					Text("Escolha quais aplicativos das suas fontes serão monitorados para tweaks e atualizações. Apps ocultados continuam disponíveis normalmente nas Fontes e podem ser reativados a qualquer momento.")
				}
			}
			
			if !_records.isEmpty {
				Section {
					ForEach(_records) { record in
						NavigationLink(destination: InstalledTweakEditorView(recordID: record.id)) {
							VStack(alignment: .leading, spacing: 3) {
								Text(record.appName ?? record.localBundleIdentifier)
									.font(.body)
								Text(_packageSummary(for: record))
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
					}
				} header: {
					Text("Tweaks instalados")
				} footer: {
					Text("Manual é usado apenas para a configuração inicial. Depois de instalar uma atualização pela source, o Feather passa a registrar os metadados do pacote automaticamente.")
				}
			}
		}
		.navigationTitle("Tweaks e atualizações")
		.onAppear {
			if _catalogURL.isEmpty {
				_catalogURL = _catalog.catalogURLString
			}
		}
		.task {
			await _catalog.refresh(force: false)
			await _updates.checkForUpdates(sources: Storage.shared.getSources())
		}
		.alert(
			"Catálogo de tweaks",
			isPresented: Binding(
				get: { _alertMessage != nil },
				set: { if !$0 { _alertMessage = nil } }
			)
		) {
			Button("OK", role: .cancel) { }
		} message: {
			Text(_alertMessage ?? "")
		}
	}
	
	private func _packageSummary(for record: InstalledSourceAppRecord) -> String {
		guard let label = record.installedPackageLabel else {
			if let catalogApp = _catalog.app(for: record.localBundleIdentifier),
			   let addon = catalogApp.addons.first {
				return "Não configurado · \(addon.name) disponível"
			}
			return "Tweak não configurado"
		}
		let source = record.packageMetadataSource == .source ? "Automático" : "Manual"
		return "\(label) · \(source)"
	}
	
	private func _saveAndRefresh() {
		do {
			try _catalog.saveCatalogURL(_catalogURL)
			_catalogURL = _catalog.catalogURLString
			Task { await _catalog.refresh(force: true) }
		} catch {
			_alertMessage = error.localizedDescription
		}
	}
}

private struct InstalledTweakEditorView: View {
	@ObservedObject private var _registry = InstallationRegistry.shared
	@StateObject private var _catalog = TweakCatalogManager.shared
	let recordID: String
	@State private var _selectedPackageName = ""
	@State private var _customPackageName = ""
	@State private var _customVersion = ""
	@State private var _alertMessage: String?
	
	private var _record: InstalledSourceAppRecord? {
		_registry.records.first { $0.id == recordID }
	}
	
	private var _addons: [FeatherTweakCatalogAddon] {
		guard let record = _record else { return [] }
		return _catalog.addons(for: record.localBundleIdentifier)
	}
	
	private var _selectedAddon: FeatherTweakCatalogAddon? {
		if let exact = _addons.first(where: {
			$0.name.compare(_selectedPackageName, options: [.caseInsensitive]) == .orderedSame
		}) {
			return exact
		}
		return _addons.first
	}
	
	private var _knownVersions: [String] {
		guard let addon = _selectedAddon else { return [] }
		var values = addon.knownVersions
		if !values.contains(addon.currentVersion) {
			values.append(addon.currentVersion)
		}
		return Array(Set(values)).sorted {
			$0.compare($1, options: [.numeric, .caseInsensitive]) == .orderedDescending
		}
	}
	
	var body: some View {
		Form {
			if let record = _record {
				Section {
					_infoRow("App", value: record.appName ?? record.localBundleIdentifier)
					_infoRow("Bundle ID", value: record.localBundleIdentifier)
					_infoRow("Versão do app", value: _appVersionText(record))
					if let label = record.installedPackageLabel {
						_infoRow("Tweak registrado", value: label)
						_infoRow(
							"Origem",
							value: record.packageMetadataSource == .source ? "Automático" : "Manual"
						)
					}
				}
				
				if !_addons.isEmpty {
					if _addons.count > 1 {
						Section {
							Picker("Pacote instalado", selection: $_selectedPackageName) {
								ForEach(_addons) { addon in
									Text(addon.name).tag(addon.name)
								}
							}
						} header: {
							Text("Pacote")
						}
					}
					
					if let addon = _selectedAddon {
						Section {
							ForEach(_knownVersions, id: \.self) { version in
								Button {
									_save(addon: addon, version: version)
								} label: {
									HStack {
										VStack(alignment: .leading, spacing: 2) {
											Text(version)
											if version == addon.currentVersion {
												Text("Versão atual disponível")
													.font(.caption2)
													.foregroundStyle(.secondary)
											}
										}
										Spacer()
										if record.installedPackageName?.caseInsensitiveCompare(addon.name) == .orderedSame,
										   record.installedPackageVersion == version {
											Image(systemName: "checkmark.circle.fill")
												.foregroundStyle(Color.accentColor)
										}
									}
								}
							}
						} header: {
							Text("Versão instalada de \(addon.name)")
						} footer: {
							Text("Escolha a versão que realmente está instalada neste iPhone. A versão atual do catálogo continua separada e será usada apenas para comparação.")
						}
						
						Section {
							TextField("Outra versão", text: $_customVersion)
								.textInputAutocapitalization(.never)
								.autocorrectionDisabled()
							Button("Usar esta versão") {
								let value = _customVersion.trimmingCharacters(in: .whitespacesAndNewlines)
								guard !value.isEmpty else { return }
								_save(addon: addon, version: value)
							}
							.disabled(_customVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
						} header: {
							Text("Outra versão")
						}
						
						if let components = addon.components, !components.isEmpty {
							Section {
								ForEach(components) { component in
									HStack {
										Text(component.name)
										Spacer()
										Text(component.version)
											.foregroundStyle(.secondary)
									}
								}
							} header: {
								Text("Componentes do pacote")
							} footer: {
								Text("Informativo. A versão do pacote principal é a que controla a detecção de atualizações nesta Beta.")
							}
						}
					}
				} else {
					Section {
						TextField("Nome do tweak", text: $_customPackageName)
							.textInputAutocapitalization(.words)
							.autocorrectionDisabled()
						TextField("Versão instalada", text: $_customVersion)
							.textInputAutocapitalization(.never)
							.autocorrectionDisabled()
						Button("Salvar informação manual") {
							_saveCustomPackage()
						}
						.disabled(
							_customPackageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
								|| _customVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
						)
					} header: {
						Text("Informação manual")
					} footer: {
						Text("Este app ainda não está no catálogo atual. Você pode registrar o nome e a versão manualmente.")
					}
				}
				
				if record.installedPackageName != nil || record.installedPackageVersion != nil {
					Section {
						Button("Remover informação do tweak", role: .destructive) {
							_ = _registry.clearInstalledPackage(recordID: record.id)
						}
					} footer: {
						Text("Remove apenas o registro usado pelo Feather. O IPA instalado não é alterado.")
					}
				}
			}
		}
		.navigationTitle(_record?.appName ?? "Tweak instalado")
		.onAppear {
			_resolveInitialState()
		}
		.task {
			await _catalog.refresh(force: false)
			_resolveInitialState()
		}
		.alert(
			"Tweak instalado",
			isPresented: Binding(
				get: { _alertMessage != nil },
				set: { if !$0 { _alertMessage = nil } }
			)
		) {
			Button("OK", role: .cancel) { }
		} message: {
			Text(_alertMessage ?? "")
		}
	}
	
	@ViewBuilder
	private func _infoRow(_ title: String, value: String) -> some View {
		HStack(alignment: .firstTextBaseline) {
			Text(title)
			Spacer()
			Text(value)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.trailing)
		}
	}
	
	private func _appVersionText(_ record: InstalledSourceAppRecord) -> String {
		guard let build = record.installedBuildVersion, !build.isEmpty else {
			return record.installedVersion
		}
		return "\(record.installedVersion) (\(build))"
	}
	
	private func _resolveInitialState() {
		guard let record = _record else { return }
		if _selectedPackageName.isEmpty {
			_selectedPackageName = record.installedPackageName ?? _addons.first?.name ?? ""
		}
		if _customPackageName.isEmpty {
			_customPackageName = record.installedPackageName ?? ""
		}
	}
	
	private func _save(addon: FeatherTweakCatalogAddon, version: String) {
		guard let record = _record else { return }
		let revision = version == addon.currentVersion ? addon.currentRevision : nil
		if _registry.setInstalledPackage(
			recordID: record.id,
			name: addon.name,
			version: version,
			revision: revision,
			source: .manual
		) {
			_customVersion = ""
		} else {
			_alertMessage = "Não foi possível salvar a informação do tweak."
		}
	}
	
	private func _saveCustomPackage() {
		guard let record = _record else { return }
		let name = _customPackageName.trimmingCharacters(in: .whitespacesAndNewlines)
		let version = _customVersion.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty, !version.isEmpty else { return }
		if _registry.setInstalledPackage(
			recordID: record.id,
			name: name,
			version: version,
			revision: nil,
			source: .manual
		) {
			_customVersion = ""
		} else {
			_alertMessage = "Não foi possível salvar a informação do tweak."
		}
	}
}
