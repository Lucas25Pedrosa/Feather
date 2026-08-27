//
//  TweakCatalogManager.swift
//  Feather
//
//  Public tweak/package catalog used by Feather Beta update tracking.
//

import Combine
import Foundation

struct FeatherTweakCatalog: Codable, Equatable {
	let schemaVersion: Int
	let apps: [String: FeatherTweakCatalogApp]
}

struct FeatherTweakCatalogApp: Codable, Equatable {
	let name: String
	let addons: [FeatherTweakCatalogAddon]
}

struct FeatherTweakCatalogAddon: Codable, Equatable, Identifiable {
	let name: String
	let currentVersion: String
	let knownVersions: [String]
	let currentRevision: String?
	let packageLabel: String?
	let components: [FeatherTweakCatalogComponent]?
	
	var id: String { name }
}

struct FeatherTweakCatalogComponent: Codable, Equatable, Identifiable {
	let name: String
	let version: String
	
	var id: String { "\(name)@\(version)" }
}

enum TweakCatalogError: LocalizedError {
	case invalidURL
	case invalidResponse
	case invalidCatalog
	case serverError(Int)
	
	var errorDescription: String? {
		switch self {
		case .invalidURL:
			return "A URL do catálogo precisa ser um endereço HTTPS válido."
		case .invalidResponse:
			return "O servidor do catálogo retornou uma resposta inválida."
		case .invalidCatalog:
			return "O arquivo informado não é um catálogo de tweaks compatível."
		case .serverError(let status):
			return "O catálogo retornou HTTP \(status)."
		}
	}
}

@MainActor
final class TweakCatalogManager: ObservableObject {
	static let shared = TweakCatalogManager()
	static let defaultCatalogURLString = "https://raw.githubusercontent.com/Lucas25Pedrosa/ipa-r2-automation/main/Feather/tweaks.json"
	
	private static let _catalogURLKey = "Feather.tweakCatalog.url"
	private static let _lastUpdatedKey = "Feather.tweakCatalog.lastUpdated"
	private static let _minimumRefreshInterval: TimeInterval = 15 * 60
	
	@Published private(set) var catalog: FeatherTweakCatalog?
	@Published private(set) var catalogURLString: String
	@Published private(set) var lastUpdated: Date?
	@Published private(set) var isRefreshing = false
	@Published private(set) var lastError: String?
	
	private let _cacheURL: URL
	
	private init() {
		let defaults = UserDefaults.standard
		catalogURLString = defaults.string(forKey: Self._catalogURLKey)
			?? Self.defaultCatalogURLString
		lastUpdated = defaults.object(forKey: Self._lastUpdatedKey) as? Date
		
		let applicationSupport = FileManager.default.urls(
			for: .applicationSupportDirectory,
			in: .userDomainMask
		).first!
		let directory = applicationSupport
			.appendingPathComponent("Feather", isDirectory: true)
		try? FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		_cacheURL = directory.appendingPathComponent(
			"TweakCatalog.json",
			isDirectory: false
		)
		
		_loadCache()
	}
	
	func app(for bundleIdentifier: String) -> FeatherTweakCatalogApp? {
		guard let catalog else { return nil }
		if let exact = catalog.apps[bundleIdentifier] {
			return exact
		}
		return catalog.apps.first {
			$0.key.compare(bundleIdentifier, options: [.caseInsensitive]) == .orderedSame
		}?.value
	}
	
	func addons(for bundleIdentifier: String) -> [FeatherTweakCatalogAddon] {
		app(for: bundleIdentifier)?.addons ?? []
	}
	
	func saveCatalogURL(_ value: String) throws {
		let normalized = try Self._normalizedURLString(value)
		guard normalized != catalogURLString else { return }
		catalogURLString = normalized
		lastUpdated = nil
		lastError = nil
		UserDefaults.standard.set(normalized, forKey: Self._catalogURLKey)
		UserDefaults.standard.removeObject(forKey: Self._lastUpdatedKey)
	}
	
	func resetCatalogURL() {
		catalogURLString = Self.defaultCatalogURLString
		lastUpdated = nil
		lastError = nil
		UserDefaults.standard.removeObject(forKey: Self._catalogURLKey)
		UserDefaults.standard.removeObject(forKey: Self._lastUpdatedKey)
	}
	
	func refresh(force: Bool = false) async {
		if isRefreshing { return }
		if
			!force,
			catalog != nil,
			let lastUpdated,
			Date().timeIntervalSince(lastUpdated) < Self._minimumRefreshInterval
		{
			return
		}
		
		isRefreshing = true
		defer { isRefreshing = false }
		
		do {
			let normalized = try Self._normalizedURLString(catalogURLString)
			guard let url = URL(string: normalized) else {
				throw TweakCatalogError.invalidURL
			}
			var request = URLRequest(url: url)
			request.cachePolicy = .reloadIgnoringLocalCacheData
			request.timeoutInterval = 20
			request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
			
			let (data, response) = try await URLSession.shared.data(for: request)
			guard let http = response as? HTTPURLResponse else {
				throw TweakCatalogError.invalidResponse
			}
			guard (200..<300).contains(http.statusCode) else {
				throw TweakCatalogError.serverError(http.statusCode)
			}
			
			let decoded = try JSONDecoder().decode(FeatherTweakCatalog.self, from: data)
			guard decoded.schemaVersion == 1, !decoded.apps.isEmpty else {
				throw TweakCatalogError.invalidCatalog
			}
			
			try data.write(to: _cacheURL, options: .atomic)
			catalog = decoded
			catalogURLString = normalized
			lastError = nil
			let now = Date()
			lastUpdated = now
			UserDefaults.standard.set(normalized, forKey: Self._catalogURLKey)
			UserDefaults.standard.set(now, forKey: Self._lastUpdatedKey)
		} catch {
			// Keep the last valid catalog. A temporary outage must never erase
			// installed-package knowledge or block normal Feather operations.
			lastError = error.localizedDescription
		}
	}
	
	private func _loadCache() {
		guard
			let data = try? Data(contentsOf: _cacheURL),
			let decoded = try? JSONDecoder().decode(FeatherTweakCatalog.self, from: data),
			decoded.schemaVersion == 1
		else {
			return
		}
		catalog = decoded
	}
	
	private static func _normalizedURLString(_ value: String) throws -> String {
		let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard
			!candidate.isEmpty,
			var components = URLComponents(string: candidate),
			components.scheme?.lowercased() == "https",
			let host = components.host,
			!host.isEmpty
		else {
			throw TweakCatalogError.invalidURL
		}
		components.scheme = "https"
		components.host = host.lowercased()
		components.fragment = nil
		guard let url = components.url else {
			throw TweakCatalogError.invalidURL
		}
		return url.absoluteString
	}
}
