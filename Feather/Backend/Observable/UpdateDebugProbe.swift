//
//  UpdateDebugProbe.swift
//  Feather
//
//  Temporary diagnostics for source/update cache investigation.
//

import Foundation

actor UpdateDebugProbe {
	static let shared = UpdateDebugProbe()
	
	private let _session: URLSession
	private let _fileURL: URL
	private let _formatter: ISO8601DateFormatter
	
	private init() {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.urlCache = nil
		configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		configuration.httpCookieStorage = nil
		_session = URLSession(configuration: configuration)
		
		let documents = FileManager.default.urls(
			for: .documentDirectory,
			in: .userDomainMask
		).first!
		_fileURL = documents.appendingPathComponent("Feather-Update-Debug.log")
		
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		_formatter = formatter
	}
	
	func capture(sourceURLs: [URL]) async {
		let captureID = String(UUID().uuidString.prefix(8))
		_append("===== NETWORK CAPTURE \(captureID) START | sources=\(sourceURLs.count) =====")
		
		for sourceURL in sourceURLs {
			let requestedURL = _cacheBustedURL(sourceURL)
			var request = URLRequest(
				url: requestedURL,
				cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
				timeoutInterval: 30
			)
			request.setValue("no-cache, no-store, max-age=0, must-revalidate", forHTTPHeaderField: "Cache-Control")
			request.setValue("no-cache", forHTTPHeaderField: "Pragma")
			request.setValue("0", forHTTPHeaderField: "Expires")
			
			_append("SOURCE original=\(sourceURL.absoluteString)")
			_append("REQUEST url=\(requestedURL.absoluteString)")
			
			do {
				let (data, response) = try await _session.data(for: request)
				
				if let http = response as? HTTPURLResponse {
					_append(
						"RESPONSE status=\(http.statusCode) finalURL=\(http.url?.absoluteString ?? "-") bytes=\(data.count) "
						+ "cacheControl=\(_header("Cache-Control", from: http)) "
						+ "age=\(_header("Age", from: http)) "
						+ "etag=\(_header("ETag", from: http)) "
						+ "lastModified=\(_header("Last-Modified", from: http)) "
						+ "xCache=\(_header("X-Cache", from: http)) "
						+ "xCacheHits=\(_header("X-Cache-Hits", from: http)) "
						+ "cfCacheStatus=\(_header("CF-Cache-Status", from: http))"
					)
				}
				
				_logRepositorySummary(from: data)
			} catch {
				_append("NETWORK ERROR \(error.localizedDescription)")
			}
		}
		
		_append("===== NETWORK CAPTURE \(captureID) END =====")
	}
	
	func recordFeatherState(
		installed: [InstalledSourceAppRecord],
		updates: [AppUpdate]
	) {
		let stateID = String(UUID().uuidString.prefix(8))
		_append("===== FEATHER STATE \(stateID) START =====")
		_append("installedRecords=\(installed.count) availableUpdates=\(updates.count)")
		
		for record in installed {
			_append(
				"INSTALLED app=\(_safe(record.appName ?? record.localBundleIdentifier)) "
				+ "localBundle=\(_safe(record.localBundleIdentifier)) "
				+ "sourceApp=\(_safe(record.sourceAppIdentifier)) "
				+ "version=\(_safe(record.installedVersion)) "
				+ "ignored=\(_safe(record.ignoredRemoteVersion ?? "-")) "
				+ "disabled=\(record.updatesDisabled == true) "
				+ "source=\(_safe(record.sourceRepositoryURL.absoluteString))"
			)
		}
		
		for update in updates {
			_append(
				"UPDATE app=\(_safe(update.appName)) "
				+ "local=\(_safe(update.localVersion ?? "-")) "
				+ "remote=\(_safe(update.remoteVersion)) "
				+ "localBundle=\(_safe(update.localBundleIdentifier)) "
				+ "sourceApp=\(_safe(update.bundleIdentifier)) "
				+ "source=\(_safe(update.sourceURL.absoluteString))"
			)
		}
		
		_append("===== FEATHER STATE \(stateID) END =====")
	}
	
	private func _logRepositorySummary(from data: Data) {
		guard
			let object = try? JSONSerialization.jsonObject(with: data),
			let dictionary = object as? [String: Any]
		else {
			_append("PARSE raw source is not a JSON object")
			return
		}
		
		let repositoryName = dictionary["name"] as? String ?? "-"
		guard let apps = dictionary["apps"] as? [[String: Any]] else {
			_append("PARSE repository=\(_safe(repositoryName)) apps=missing")
			return
		}
		
		_append("PARSE repository=\(_safe(repositoryName)) apps=\(apps.count)")
		
		for app in apps {
			let name = app["name"] as? String ?? "-"
			let bundleIdentifier = app["bundleIdentifier"] as? String ?? "-"
			let topLevelVersion = app["version"] as? String
			let versions = app["versions"] as? [[String: Any]]
			let firstVersion = versions?.first?["version"] as? String
			let resolvedVersion = topLevelVersion ?? firstVersion ?? "-"
			
			_append(
				"REMOTE app=\(_safe(name)) bundle=\(_safe(bundleIdentifier)) version=\(_safe(resolvedVersion))"
			)
		}
	}
	
	private func _cacheBustedURL(_ url: URL) -> URL {
		guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
			return url
		}
		
		var queryItems = components.queryItems ?? []
		queryItems.removeAll { $0.name == "_feather_debug" }
		queryItems.append(
			URLQueryItem(
				name: "_feather_debug",
				value: UUID().uuidString
			)
		)
		components.queryItems = queryItems
		return components.url ?? url
	}
	
	private func _header(_ name: String, from response: HTTPURLResponse) -> String {
		_safe(response.value(forHTTPHeaderField: name) ?? "-")
	}
	
	private func _safe(_ value: String) -> String {
		value
			.replacingOccurrences(of: "\n", with: " ")
			.replacingOccurrences(of: "\r", with: " ")
	}
	
	private func _append(_ message: String) {
		let timestamp = _formatter.string(from: Date())
		guard let line = "[\(timestamp)] \(message)\n".data(using: .utf8) else {
			return
		}
		
		var existing = (try? Data(contentsOf: _fileURL)) ?? Data()
		if existing.count > 1_000_000 {
			existing = Data()
		}
		existing.append(line)
		try? existing.write(to: _fileURL, options: .atomic)
	}
}
