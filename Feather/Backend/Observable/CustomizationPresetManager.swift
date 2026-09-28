//
//  CustomizationPresetManager.swift
//  Feather
//
//  Feather 3.5.0 Beta 1
//

import Combine
import Foundation
import UIKit

struct SourceCustomizationTarget: Hashable {
	let sourceRepositoryURL: URL
	let sourceRepositoryIdentifier: String?
	let sourceRepositoryName: String?
	let sourceAppIdentifier: String
	let sourceAppName: String
	let sourceAppVersion: String?
	let sourceIconURL: URL?
}

struct SourceCustomizationPreset: Codable, Identifiable, Equatable {
	let sourceRepositoryURL: String
	let sourceRepositoryIdentifier: String?
	let sourceRepositoryName: String?
	let sourceAppIdentifier: String
	let sourceAppName: String
	let sourceAppVersion: String?
	let sourceIconURL: String?

	var customName: String?
	var customBundleIdentifier: String?
	var customVersion: String?
	var iconFileName: String?

	// General signing overrides
	var appAppearance: Options.AppAppearance?
	var minimumAppRequirement: Options.MinimumAppRequirement?
	var signingOption: Options.SigningOption?

	// App feature overrides
	var fileSharing: Bool?
	var itunesFileSharing: Bool?
	var proMotion: Bool?
	var gameMode: Bool?
	var ipadFullscreen: Bool?

	// Removal overrides
	var removeURLScheme: Bool?
	var removeProvisioning: Bool?

	var id: String {
		Self.makeID(
			repositoryIdentifier: sourceRepositoryIdentifier,
			repositoryURL: sourceRepositoryURL,
			appIdentifier: sourceAppIdentifier
		)
	}

	var hasCustomizations: Bool {
		customName != nil ||
		customBundleIdentifier != nil ||
		customVersion != nil ||
		iconFileName != nil ||
		appAppearance != nil ||
		minimumAppRequirement != nil ||
		signingOption != nil ||
		fileSharing != nil ||
		itunesFileSharing != nil ||
		proMotion != nil ||
		gameMode != nil ||
		ipadFullscreen != nil ||
		removeURLScheme != nil ||
		removeProvisioning != nil
	}

	var customizationSummary: String {
		var values: [String] = []
		if iconFileName != nil { values.append("Ícone") }
		if customName != nil { values.append("Nome") }
		if customBundleIdentifier != nil { values.append("Identificador") }
		if customVersion != nil { values.append("Versão") }
		if appAppearance != nil { values.append("Aparência") }
		if minimumAppRequirement != nil { values.append("Requisito mínimo") }
		if signingOption != nil { values.append("Tipo de assinatura") }
		if fileSharing != nil { values.append("Compartilhamento") }
		if itunesFileSharing != nil { values.append("iTunes") }
		if proMotion != nil { values.append("ProMotion") }
		if gameMode != nil { values.append("Modo de Jogo") }
		if ipadFullscreen != nil { values.append("iPad") }
		if removeURLScheme != nil { values.append("URL Scheme") }
		if removeProvisioning != nil { values.append("Provisioning") }
		return values.joined(separator: ", ")
	}

	var target: SourceCustomizationTarget? {
		guard let url = URL(string: sourceRepositoryURL) else { return nil }
		return SourceCustomizationTarget(
			sourceRepositoryURL: url,
			sourceRepositoryIdentifier: sourceRepositoryIdentifier,
			sourceRepositoryName: sourceRepositoryName,
			sourceAppIdentifier: sourceAppIdentifier,
			sourceAppName: sourceAppName,
			sourceAppVersion: sourceAppVersion,
			sourceIconURL: sourceIconURL.flatMap(URL.init(string:))
		)
	}

	static func makeID(
		repositoryIdentifier: String?,
		repositoryURL: String,
		appIdentifier: String
	) -> String {
		let repositoryKey = repositoryIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
		let normalizedRepository = (repositoryKey?.isEmpty == false)
			? repositoryKey!
			: repositoryURL
		return normalizedRepository + "|" + appIdentifier
	}
}

final class CustomizationPresetManager: ObservableObject {
	static let shared = CustomizationPresetManager()

	@Published private(set) var presets: [SourceCustomizationPreset] = []

	private let _fileManager = FileManager.default
	private let _encoder: JSONEncoder
	private let _decoder = JSONDecoder()

	private init() {
		_encoder = JSONEncoder()
		_encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		_load()
	}

	var presetCount: Int {
		presets.count
	}

	var customIconCount: Int {
		presets.filter { $0.iconFileName != nil }.count
	}

	func preset(for target: SourceCustomizationTarget) -> SourceCustomizationPreset? {
		presets.first { _matches($0, target: target) }
	}

	func preset(for provenance: SourceAppProvenance) -> SourceCustomizationPreset? {
		let target = SourceCustomizationTarget(
			sourceRepositoryURL: provenance.sourceRepositoryURL,
			sourceRepositoryIdentifier: provenance.sourceRepositoryIdentifier,
			sourceRepositoryName: provenance.sourceRepositoryName,
			sourceAppIdentifier: provenance.sourceAppIdentifier,
			sourceAppName: provenance.sourceAppName ?? provenance.sourceAppIdentifier,
			sourceAppVersion: provenance.sourceAppVersion,
			sourceIconURL: nil
		)
		return preset(for: target)
	}

	func preset(for app: AppInfoPresentable) -> SourceCustomizationPreset? {
		guard
			let uuid = app.uuid,
			let metadata = Storage.shared.sourceMetadata(for: uuid),
			let repositoryURL = metadata.sourceRepositoryURL,
			let appIdentifier = metadata.sourceAppIdentifier
		else {
			return nil
		}

		let target = SourceCustomizationTarget(
			sourceRepositoryURL: repositoryURL,
			sourceRepositoryIdentifier: metadata.sourceRepositoryIdentifier,
			sourceRepositoryName: metadata.sourceRepositoryName,
			sourceAppIdentifier: appIdentifier,
			sourceAppName: metadata.sourceAppName ?? app.name ?? appIdentifier,
			sourceAppVersion: metadata.sourceAppVersion,
			sourceIconURL: nil
		)
		return preset(for: target)
	}

	func apply(to options: inout Options, for app: AppInfoPresentable) {
		guard let preset = preset(for: app) else { return }
		_apply(preset, to: &options)
	}

	func apply(to options: inout Options, for provenance: SourceAppProvenance) {
		guard let preset = preset(for: provenance) else { return }
		_apply(preset, to: &options)
	}

	func customIcon(for provenance: SourceAppProvenance) -> UIImage? {
		guard let preset = preset(for: provenance) else { return nil }
		return customIcon(for: preset)
	}

	func customIcon(for app: AppInfoPresentable) -> UIImage? {
		guard let preset = preset(for: app) else { return nil }
		return customIcon(for: preset)
	}

	func customIcon(for target: SourceCustomizationTarget) -> UIImage? {
		guard let preset = preset(for: target) else { return nil }
		return customIcon(for: preset)
	}

	func customIcon(for preset: SourceCustomizationPreset) -> UIImage? {
		guard let iconFileName = preset.iconFileName else { return nil }
		let url = _iconsDirectory.appendingPathComponent(iconFileName)
		return UIImage(contentsOfFile: url.path)
	}

	func save(
		target: SourceCustomizationTarget,
		customName: String?,
		customBundleIdentifier: String?,
		customVersion: String?,
		icon: UIImage?,
		replaceIcon: Bool,
		appAppearance: Options.AppAppearance? = nil,
		minimumAppRequirement: Options.MinimumAppRequirement? = nil,
		signingOption: Options.SigningOption? = nil,
		fileSharing: Bool? = nil,
		itunesFileSharing: Bool? = nil,
		proMotion: Bool? = nil,
		gameMode: Bool? = nil,
		ipadFullscreen: Bool? = nil,
		removeURLScheme: Bool? = nil,
		removeProvisioning: Bool? = nil
	) {
		let current = preset(for: target)
		var iconFileName = current?.iconFileName

		if replaceIcon {
			if let oldName = iconFileName {
				try? _fileManager.removeItem(at: _iconsDirectory.appendingPathComponent(oldName))
			}
			iconFileName = nil

			if let icon,
			   let resizedIcon = icon.resizeToSquare(),
			   let data = resizedIcon.pngData() {
				_prepareDirectories()
				let fileName = "icon-\(UUID().uuidString).png"
				let destination = _iconsDirectory.appendingPathComponent(fileName)
				do {
					try data.write(to: destination, options: Data.WritingOptions.atomic)
					iconFileName = fileName
				} catch {
					iconFileName = nil
				}
			}
		}

		let updated = SourceCustomizationPreset(
			sourceRepositoryURL: target.sourceRepositoryURL.absoluteString,
			sourceRepositoryIdentifier: target.sourceRepositoryIdentifier,
			sourceRepositoryName: target.sourceRepositoryName,
			sourceAppIdentifier: target.sourceAppIdentifier,
			sourceAppName: target.sourceAppName,
			sourceAppVersion: target.sourceAppVersion,
			sourceIconURL: target.sourceIconURL?.absoluteString,
			customName: _normalized(customName),
			customBundleIdentifier: _normalized(customBundleIdentifier),
			customVersion: _normalized(customVersion),
			iconFileName: iconFileName,
			appAppearance: appAppearance,
			minimumAppRequirement: minimumAppRequirement,
			signingOption: signingOption,
			fileSharing: fileSharing,
			itunesFileSharing: itunesFileSharing,
			proMotion: proMotion,
			gameMode: gameMode,
			ipadFullscreen: ipadFullscreen,
			removeURLScheme: removeURLScheme,
			removeProvisioning: removeProvisioning
		)

		_upsertOrRemove(updated)
	}

	func removeIcon(for target: SourceCustomizationTarget) {
		guard var current = preset(for: target) else { return }
		if let fileName = current.iconFileName {
			try? _fileManager.removeItem(at: _iconsDirectory.appendingPathComponent(fileName))
		}
		current.iconFileName = nil
		_upsertOrRemove(current)
	}

	func deletePreset(_ preset: SourceCustomizationPreset) {
		if let fileName = preset.iconFileName {
			try? _fileManager.removeItem(at: _iconsDirectory.appendingPathComponent(fileName))
		}
		presets.removeAll { $0.id == preset.id }
		_save()
	}

	func removeAllIcons() {
		try? _fileManager.removeItem(at: _iconsDirectory)
		_prepareDirectories()

		presets = presets.compactMap { preset in
			var value = preset
			value.iconFileName = nil
			return value.hasCustomizations ? value : nil
		}
		_save()
	}

	func resetAll() {
		try? _fileManager.removeItem(at: _rootDirectory)
		presets = []
		_prepareDirectories()
		_save()
	}

	private func _apply(_ preset: SourceCustomizationPreset, to options: inout Options) {
		if let customName = preset.customName {
			options.appName = customName
		}
		if let customBundleIdentifier = preset.customBundleIdentifier {
			options.appIdentifier = customBundleIdentifier
		}
		if let customVersion = preset.customVersion {
			options.appVersion = customVersion
		}

		if let appAppearance = preset.appAppearance {
			options.appAppearance = appAppearance
		}
		if let minimumAppRequirement = preset.minimumAppRequirement {
			options.minimumAppRequirement = minimumAppRequirement
		}
		if let signingOption = preset.signingOption {
			options.signingOption = signingOption
		}

		if let fileSharing = preset.fileSharing {
			options.fileSharing = fileSharing
		}
		if let itunesFileSharing = preset.itunesFileSharing {
			options.itunesFileSharing = itunesFileSharing
		}
		if let proMotion = preset.proMotion {
			options.proMotion = proMotion
		}
		if let gameMode = preset.gameMode {
			options.gameMode = gameMode
		}
		if let ipadFullscreen = preset.ipadFullscreen {
			options.ipadFullscreen = ipadFullscreen
		}

		if let removeURLScheme = preset.removeURLScheme {
			options.removeURLScheme = removeURLScheme
		}
		if let removeProvisioning = preset.removeProvisioning {
			options.removeProvisioning = removeProvisioning
		}
	}

	private func _matches(
		_ preset: SourceCustomizationPreset,
		target: SourceCustomizationTarget
	) -> Bool {
		guard preset.sourceAppIdentifier == target.sourceAppIdentifier else {
			return false
		}

		let presetRepositoryID = preset.sourceRepositoryIdentifier?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let targetRepositoryID = target.sourceRepositoryIdentifier?
			.trimmingCharacters(in: .whitespacesAndNewlines)

		if let presetRepositoryID,
		   !presetRepositoryID.isEmpty,
		   let targetRepositoryID,
		   !targetRepositoryID.isEmpty {
			return presetRepositoryID == targetRepositoryID
		}

		return preset.sourceRepositoryURL == target.sourceRepositoryURL.absoluteString
	}

	private func _upsertOrRemove(_ preset: SourceCustomizationPreset) {
		presets.removeAll { $0.id == preset.id }
		if preset.hasCustomizations {
			presets.append(preset)
		}
		presets.sort {
			$0.sourceAppName.localizedCaseInsensitiveCompare($1.sourceAppName) == .orderedAscending
		}
		_save()
	}

	private func _normalized(_ value: String?) -> String? {
		guard let value else { return nil }
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}

	private var _rootDirectory: URL {
		let base = _fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL.documentsDirectory
		return base.appendingPathComponent("FeatherCustomizations", isDirectory: true)
	}

	private var _iconsDirectory: URL {
		_rootDirectory.appendingPathComponent("Icons", isDirectory: true)
	}

	private var _presetsFile: URL {
		_rootDirectory.appendingPathComponent("presets.json")
	}

	private func _prepareDirectories() {
		try? _fileManager.createDirectory(
			at: _iconsDirectory,
			withIntermediateDirectories: true
		)
	}

	private func _load() {
		_prepareDirectories()
		guard
			let data = try? Data(contentsOf: _presetsFile),
			let decoded = try? _decoder.decode([SourceCustomizationPreset].self, from: data)
		else {
			presets = []
			return
		}

		presets = decoded.filter(\.hasCustomizations).sorted {
			$0.sourceAppName.localizedCaseInsensitiveCompare($1.sourceAppName) == .orderedAscending
		}
	}

	private func _save() {
		_prepareDirectories()
		guard let data = try? _encoder.encode(presets) else { return }
		try? data.write(to: _presetsFile, options: .atomic)
	}
}
