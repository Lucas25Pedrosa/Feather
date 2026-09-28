//
//  PredefinedCustomizationsView.swift
//  Feather
//
//  Feather 3.5.0 Beta 1
//

import SwiftUI
import PhotosUI
import AltSourceKit
import NimbleViews

struct PredefinedCustomizationsView: View {
	@StateObject private var _manager = CustomizationPresetManager.shared

	var body: some View {
		NBList("Personalizações") {
			Section {
				NavigationLink {
					CustomizationSourceAppPickerView()
				} label: {
					Label("Adicionar personalização", systemImage: "plus.circle")
				}
			} footer: {
				Text("As personalizações são vinculadas ao aplicativo da Source. Somente os campos escolhidos serão alterados; todo o restante permanece original.")
			}

			if _manager.presets.isEmpty {
				Section {
					Text("Nenhuma personalização predefinida.")
						.foregroundStyle(.secondary)
				}
			} else {
				Section {
					ForEach(_manager.presets) { preset in
						if let target = preset.target {
							NavigationLink {
								CustomizationPresetEditorView(target: target)
							} label: {
								VStack(alignment: .leading, spacing: 3) {
									Text(preset.sourceAppName)
										.foregroundStyle(.primary)
									Text(preset.customizationSummary)
										.font(.footnote)
										.foregroundStyle(.secondary)
										.lineLimit(2)
								}
							}
						}
					}
				} header: {
					Text("Aplicativos")
				}
			}
		}
	}
}

private struct CustomizationSourceAppPickerView: View {
	@StateObject private var _viewModel = SourcesViewModel.shared

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>

	var body: some View {
		NBList("Selecionar aplicativo") {
			if _sources.isEmpty {
				Section {
					Text("Nenhuma Source adicionada.")
						.foregroundStyle(.secondary)
				}
			} else {
				ForEach(Array(_sources), id: \.objectID) { source in
					if
						let repository = _viewModel.sources[source],
						let sourceURL = source.sourceURL
					{
						Section(source.name ?? repository.name ?? "Source") {
							ForEach(repository.apps, id: \.currentUniqueId) { app in
								if let appIdentifier = app.id {
									let target = SourceCustomizationTarget(
										sourceRepositoryURL: sourceURL,
										sourceRepositoryIdentifier: repository.id,
										sourceRepositoryName: repository.name ?? source.name,
										sourceAppIdentifier: appIdentifier,
										sourceAppName: app.currentName,
										sourceAppVersion: app.currentVersion,
										sourceIconURL: app.iconURL
									)

									NavigationLink {
										CustomizationPresetEditorView(target: target)
									} label: {
										HStack(spacing: 12) {
											SourceCustomizationIconView(
												customIcon: nil,
												sourceIconURL: app.iconURL,
												size: 42
											)
											VStack(alignment: .leading, spacing: 2) {
												Text(app.currentName)
													.foregroundStyle(.primary)
												Text(appIdentifier)
													.font(.footnote)
													.foregroundStyle(.secondary)
													.lineLimit(1)
											}
										}
									}
								}
							}
						}
					}
				}
			}
		}
		.task {
			await _viewModel.fetchSources(_sources)
		}
		.refreshable {
			await _viewModel.fetchSources(_sources, refresh: true)
		}
	}
}

private struct CustomizationPresetEditorView: View {
	@Environment(\.dismiss) private var dismiss
	@StateObject private var _manager = CustomizationPresetManager.shared

	let target: SourceCustomizationTarget

	@State private var _customizeName = false
	@State private var _customizeBundleIdentifier = false
	@State private var _customizeVersion = false
	@State private var _name = ""
	@State private var _bundleIdentifier = ""
	@State private var _version = ""

	@State private var _appAppearance: Options.AppAppearance?
	@State private var _minimumAppRequirement: Options.MinimumAppRequirement?
	@State private var _signingOption: Options.SigningOption?

	@State private var _fileSharing: Bool?
	@State private var _itunesFileSharing: Bool?
	@State private var _proMotion: Bool?
	@State private var _gameMode: Bool?
	@State private var _ipadFullscreen: Bool?

	@State private var _removeURLScheme: Bool?
	@State private var _removeProvisioning: Bool?

	@State private var _icon: UIImage?
	@State private var _hasStoredCustomIcon = false
	@State private var _iconWasChanged = false
	@State private var _isFilePickerPresenting = false
	@State private var _isImagePickerPresenting = false
	@State private var _selectedPhoto: PhotosPickerItem?
	@State private var _didLoad = false
	@State private var _showDeleteConfirmation = false

	var body: some View {
		Form {
			Section {
				HStack(spacing: 12) {
					SourceCustomizationIconView(
						customIcon: _icon,
						sourceIconURL: target.sourceIconURL,
						size: 56
					)
					VStack(alignment: .leading, spacing: 2) {
						Text(target.sourceAppName)
							.font(.headline)
						Text(target.sourceAppIdentifier)
							.font(.footnote)
							.foregroundStyle(.secondary)
							.lineLimit(1)
					}
				}
			}

			Section {
				Menu {
					Button("Escolher dos Arquivos", systemImage: "folder") {
						_isFilePickerPresenting = true
					}
					Button("Escolher das Fotos", systemImage: "photo") {
						_isImagePickerPresenting = true
					}
				} label: {
					HStack {
						Label("Ícone", systemImage: "app.dashed")
						Spacer()
						SourceCustomizationIconView(
							customIcon: _icon,
							sourceIconURL: target.sourceIconURL,
							size: 36
						)
					}
				}

				if _icon != nil || _hasStoredCustomIcon {
					Button("Remover ícone personalizado", systemImage: "trash", role: .destructive) {
						_manager.removeIcon(for: target)
						_icon = nil
						_hasStoredCustomIcon = false
						_iconWasChanged = true
					}
				}
			} header: {
				Text("Ícone")
			} footer: {
				Text("A imagem personalizada é salva localmente pelo Feather e aplicada antes da assinatura.")
			}

			Section {
				Toggle("Nome", isOn: $_customizeName)
				if _customizeName {
					TextField(target.sourceAppName, text: $_name)
				}

				Toggle("Identificador", isOn: $_customizeBundleIdentifier)
				if _customizeBundleIdentifier {
					TextField(target.sourceAppIdentifier, text: $_bundleIdentifier)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				}

				Toggle("Versão", isOn: $_customizeVersion)
				if _customizeVersion {
					TextField(target.sourceAppVersion ?? "1.0", text: $_version)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				}
			} header: {
				Text("Propriedades")
			} footer: {
				Text("Um campo desativado permanece exatamente como está no aplicativo original.")
			}

			Section {
				Picker(selection: $_appAppearance) {
					Text("Padrão").tag(nil as Options.AppAppearance?)
					ForEach(Options.AppAppearance.allCases, id: \.self) { value in
						Text(value.localizedDescription).tag(value as Options.AppAppearance?)
					}
				} label: {
					Label("Aparência", systemImage: "paintpalette")
				}

				Picker(selection: $_minimumAppRequirement) {
					Text("Padrão").tag(nil as Options.MinimumAppRequirement?)
					ForEach(Options.MinimumAppRequirement.allCases, id: \.self) { value in
						Text(value.localizedDescription).tag(value as Options.MinimumAppRequirement?)
					}
				} label: {
					Label("Requisito mínimo", systemImage: "ruler")
				}
			} header: {
				Text("Geral")
			} footer: {
				Text("Padrão significa que esta personalização não interfere na opção normal do Feather.")
			}

			Section {
				Picker(selection: $_signingOption) {
					Text("Padrão").tag(nil as Options.SigningOption?)
					ForEach(Options.SigningOption.allCases, id: \.self) { value in
						Text(value.localizedDescription).tag(value as Options.SigningOption?)
					}
				} label: {
					Label("Tipo de assinatura", systemImage: "signature")
				}
			}

			Section {
				_booleanPicker(
					"Compartilhamento de arquivos",
					systemImage: "folder.badge.person.crop",
					selection: $_fileSharing
				)
				_booleanPicker(
					"Compartilhamento de arquivos do iTunes",
					systemImage: "music.note.list",
					selection: $_itunesFileSharing
				)
				_booleanPicker(
					"ProMotion",
					systemImage: "speedometer",
					selection: $_proMotion
				)
				_booleanPicker(
					"Modo de Jogo",
					systemImage: "gamecontroller",
					selection: $_gameMode
				)
				_booleanPicker(
					"iPad em tela cheia",
					systemImage: "ipad.landscape",
					selection: $_ipadFullscreen
				)
			} header: {
				Text("Recursos do app")
			} footer: {
				Text("Padrão mantém a configuração normal. Ativado e Desativado forçam apenas esta opção para este aplicativo.")
			}

			Section {
				_booleanPicker(
					"Remover esquema de URL",
					systemImage: "ellipsis.curlybraces",
					selection: $_removeURLScheme
				)
				_booleanPicker(
					"Remover provisioning",
					systemImage: "doc.badge.gearshape",
					selection: $_removeProvisioning
				)
			} header: {
				Text("Remoção")
			}

			if _manager.preset(for: target) != nil {
				Section {
					Button("Excluir personalização deste aplicativo", systemImage: "trash", role: .destructive) {
						_showDeleteConfirmation = true
					}
				}
			}
		}
		.navigationTitle(target.sourceAppName)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Button("Salvar") {
					_save()
				}
			}
		}
		.sheet(isPresented: $_isFilePickerPresenting) {
			FileImporterRepresentableView(
				allowedContentTypes: [.image],
				onDocumentsPicked: { urls in
					guard
						let selectedFileURL = urls.first,
						let image = UIImage.fromFile(selectedFileURL)?.resizeToSquare()
					else {
						return
					}
					_icon = image
					_iconWasChanged = true
				}
			)
			.ignoresSafeArea()
		}
		.photosPicker(isPresented: $_isImagePickerPresenting, selection: $_selectedPhoto)
		.onChange(of: _selectedPhoto) { newValue in
			guard let newValue else { return }
			Task {
				if
					let data = try? await newValue.loadTransferable(type: Data.self),
					let image = UIImage(data: data)?.resizeToSquare()
				{
					await MainActor.run {
						_icon = image
						_iconWasChanged = true
					}
				}
			}
		}
		.onAppear {
			_loadIfNeeded()
		}
		.confirmationDialog(
			"Excluir personalização?",
			isPresented: $_showDeleteConfirmation,
			titleVisibility: .visible
		) {
			Button("Excluir", role: .destructive) {
				if let preset = _manager.preset(for: target) {
					_manager.deletePreset(preset)
				}
				dismiss()
			}
			Button("Cancelar", role: .cancel) {}
		} message: {
			Text("Todas as personalizações predefinidas deste aplicativo serão removidas.")
		}
	}

	@ViewBuilder
	private func _booleanPicker(
		_ title: String,
		systemImage: String,
		selection: Binding<Bool?>
	) -> some View {
		Picker(selection: selection) {
			Text("Padrão").tag(nil as Bool?)
			Text("Ativado").tag(true as Bool?)
			Text("Desativado").tag(false as Bool?)
		} label: {
			Label(title, systemImage: systemImage)
		}
	}

	private func _loadIfNeeded() {
		guard !_didLoad else { return }
		_didLoad = true

		let preset = _manager.preset(for: target)
		_name = preset?.customName ?? target.sourceAppName
		_bundleIdentifier = preset?.customBundleIdentifier ?? target.sourceAppIdentifier
		_version = preset?.customVersion ?? target.sourceAppVersion ?? ""

		_customizeName = preset?.customName != nil
		_customizeBundleIdentifier = preset?.customBundleIdentifier != nil
		_customizeVersion = preset?.customVersion != nil

		_appAppearance = preset?.appAppearance
		_minimumAppRequirement = preset?.minimumAppRequirement
		_signingOption = preset?.signingOption

		_fileSharing = preset?.fileSharing
		_itunesFileSharing = preset?.itunesFileSharing
		_proMotion = preset?.proMotion
		_gameMode = preset?.gameMode
		_ipadFullscreen = preset?.ipadFullscreen

		_removeURLScheme = preset?.removeURLScheme
		_removeProvisioning = preset?.removeProvisioning

		_icon = preset.flatMap { _manager.customIcon(for: $0) }
		_hasStoredCustomIcon = preset?.iconFileName != nil
	}

	private func _save() {
		_manager.save(
			target: target,
			customName: _customizeName ? _name : nil,
			customBundleIdentifier: _customizeBundleIdentifier ? _bundleIdentifier : nil,
			customVersion: _customizeVersion ? _version : nil,
			icon: _icon,
			replaceIcon: _iconWasChanged,
			appAppearance: _appAppearance,
			minimumAppRequirement: _minimumAppRequirement,
			signingOption: _signingOption,
			fileSharing: _fileSharing,
			itunesFileSharing: _itunesFileSharing,
			proMotion: _proMotion,
			gameMode: _gameMode,
			ipadFullscreen: _ipadFullscreen,
			removeURLScheme: _removeURLScheme,
			removeProvisioning: _removeProvisioning
		)
		dismiss()
	}
}

private struct SourceCustomizationIconView: View {
	let customIcon: UIImage?
	let sourceIconURL: URL?
	let size: CGFloat

	var body: some View {
		Group {
			if let customIcon {
				Image(uiImage: customIcon)
					.resizable()
					.scaledToFill()
			} else if let sourceIconURL {
				AsyncImage(url: sourceIconURL) { phase in
					if let image = phase.image {
						image
							.resizable()
							.scaledToFill()
					} else {
						Image("App_Unknown")
							.resizable()
							.scaledToFill()
					}
				}
			} else {
				Image("App_Unknown")
					.resizable()
					.scaledToFill()
			}
		}
		.frame(width: size, height: size)
		.clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
	}
}
