//
//  BackupManager.swift
//  Feather
//
//  Encrypted cloud backup for the source-linked installation registry.
//

import Combine
import CryptoKit
import Foundation
import Security

private struct FeatherBackupPayload: Codable {
	let schemaVersion: Int
	let createdAt: Date
	let records: [InstalledSourceAppRecord]
}

private struct FeatherBackupHealthResponse: Decodable {
	let ok: Bool?
	let service: String?
}

enum BackupConnectionState: Equatable {
	case idle
	case checking
	case connected
	case failed(String)
}

enum FeatherBackupError: LocalizedError {
	case invalidRecoveryKey
	case unableToGenerateKey
	case unableToStoreKey
	case missingRecoveryKey
	case missingServer
	case notConnected
	case invalidEndpoint
	case invalidBackupService
	case encryptionFailed
	case invalidServerResponse
	case backupNotFound
	case unauthorized
	case serverError(Int)
	case invalidBackup
	case unsupportedBackupVersion
	case busy
	
	var errorDescription: String? {
		switch self {
		case .invalidRecoveryKey:
			return "The recovery key is invalid."
		case .unableToGenerateKey:
			return "A recovery key could not be generated."
		case .unableToStoreKey:
			return "The recovery key could not be stored securely on this device."
		case .missingRecoveryKey:
			return "Add or generate a recovery key first."
		case .missingServer:
			return "Add the backup server URL first."
		case .notConnected:
			return "Connect to the backup server first."
		case .invalidEndpoint:
			return "The backup service address is invalid. Use an HTTPS address."
		case .invalidBackupService:
			return "This address is not a compatible Feather backup service."
		case .encryptionFailed:
			return "The backup could not be encrypted."
		case .invalidServerResponse:
			return "The backup service returned an invalid response."
		case .backupNotFound:
			return "No backup was found for this recovery key."
		case .unauthorized:
			return "The recovery key was not accepted by the backup service."
		case .serverError(let status):
			return "The backup service returned HTTP \(status)."
		case .invalidBackup:
			return "The downloaded backup is invalid or the recovery key is incorrect."
		case .unsupportedBackupVersion:
			return "This backup was created by an unsupported backup format."
		case .busy:
			return "A backup operation is already in progress."
		}
	}
}

@MainActor
final class BackupManager: ObservableObject {
	static let shared = BackupManager()
	
	private static let _serverURLKey = "Feather.cloudBackup.serverURL"
	private static let _enabledKey = "Feather.cloudBackup.enabled"
	private static let _lastBackupKey = "Feather.cloudBackup.lastBackupDate"
	private static let _keychainAccount = "Feather.CloudBackup.RecoveryKey"
	private static let _keyLengthBytes = 20
	
	@Published private(set) var recoveryKey: String?
	@Published private(set) var serverURLString: String
	@Published private(set) var connectionState: BackupConnectionState = .idle
	@Published private(set) var isEnabled: Bool
	@Published private(set) var lastBackupDate: Date?
	@Published private(set) var isBusy = false
	
	private var _automaticBackupTask: Task<Void, Never>?
	
	private init() {
		recoveryKey = Self._loadRecoveryKey()
		serverURLString = UserDefaults.standard.string(forKey: Self._serverURLKey) ?? ""
		isEnabled = UserDefaults.standard.bool(forKey: Self._enabledKey)
			&& recoveryKey != nil
			&& !serverURLString.isEmpty
		lastBackupDate = UserDefaults.standard.object(forKey: Self._lastBackupKey) as? Date
		
		NotificationCenter.default.addObserver(
			forName: .featherInstallationRegistryChanged,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.scheduleAutomaticBackup()
			}
		}
	}
	
	var formattedRecoveryKey: String? {
		guard let recoveryKey else { return nil }
		return Self._formatRecoveryKey(recoveryKey)
	}
	
	var isConnected: Bool {
		connectionState == .connected
	}
	
	func setEnabled(_ enabled: Bool) {
		let resolved = enabled
			&& recoveryKey != nil
			&& !serverURLString.isEmpty
			&& isConnected
		isEnabled = resolved
		UserDefaults.standard.set(resolved, forKey: Self._enabledKey)
		
		if !resolved {
			_automaticBackupTask?.cancel()
		}
	}
	
	func saveServerURL(_ value: String) throws {
		guard let normalized = Self._normalizeServerURL(value) else {
			throw FeatherBackupError.invalidEndpoint
		}
		
		if normalized != serverURLString {
			_automaticBackupTask?.cancel()
			connectionState = .idle
			isEnabled = false
			UserDefaults.standard.set(false, forKey: Self._enabledKey)
		}
		
		serverURLString = normalized
		UserDefaults.standard.set(normalized, forKey: Self._serverURLKey)
	}
	
	@discardableResult
	func generateRecoveryKey() throws -> String {
		var bytes = [UInt8](repeating: 0, count: Self._keyLengthBytes)
		let status = bytes.withUnsafeMutableBytes { buffer in
			guard let baseAddress = buffer.baseAddress else {
				return errSecParam
			}
			return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
		}
		guard status == errSecSuccess else {
			throw FeatherBackupError.unableToGenerateKey
		}
		
		let rawKey = bytes.map { String(format: "%02X", $0) }.joined()
		try _storeRecoveryKey(rawKey)
		return Self._formatRecoveryKey(rawKey)
	}
	
	func useRecoveryKey(_ value: String) throws {
		guard let normalized = Self._normalizeRecoveryKey(value) else {
			throw FeatherBackupError.invalidRecoveryKey
		}
		try _storeRecoveryKey(normalized)
	}
	
	func disconnect() {
		_automaticBackupTask?.cancel()
		Self._deleteRecoveryKey()
		recoveryKey = nil
		connectionState = .idle
		isEnabled = false
		UserDefaults.standard.set(false, forKey: Self._enabledKey)
	}
	
	func refreshConnection() async {
		guard recoveryKey != nil, !serverURLString.isEmpty else {
			connectionState = .idle
			return
		}
		
		do {
			try await connect(serverURL: serverURLString)
		} catch {
			// connect(serverURL:) already stores the visible failure state.
		}
	}
	
	func connect(serverURL: String) async throws {
		guard !isBusy else { throw FeatherBackupError.busy }
		guard let recoveryKey else { throw FeatherBackupError.missingRecoveryKey }
		try saveServerURL(serverURL)
		
		connectionState = .checking
		isBusy = true
		defer { isBusy = false }
		
		do {
			try await _validateServiceHealth()
			try await _validateCredentials(recoveryKey: recoveryKey)
			connectionState = .connected
		} catch {
			connectionState = .failed(error.localizedDescription)
			throw error
		}
	}
	
	func scheduleAutomaticBackup() {
		guard
			isEnabled,
			isConnected,
			recoveryKey != nil,
			!serverURLString.isEmpty
		else {
			return
		}
		
		_automaticBackupTask?.cancel()
		_automaticBackupTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: 1_250_000_000)
			guard !Task.isCancelled else { return }
			try? await self?.backupNow()
		}
	}
	
	func backupNow() async throws {
		guard !isBusy else { throw FeatherBackupError.busy }
		guard let recoveryKey else { throw FeatherBackupError.missingRecoveryKey }
		guard !serverURLString.isEmpty else { throw FeatherBackupError.missingServer }
		guard isConnected else { throw FeatherBackupError.notConnected }
		guard isEnabled else { throw FeatherBackupError.notConnected }
		
		isBusy = true
		defer { isBusy = false }
		
		let payload = FeatherBackupPayload(
			schemaVersion: 1,
			createdAt: Date(),
			records: InstallationRegistry.shared.records
		)
		
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.sortedKeys]
		let plainData = try encoder.encode(payload)
		let encryptedData = try Self._encrypt(plainData, recoveryKey: recoveryKey)
		
		let authToken = Self._authToken(for: recoveryKey)
		let backupID = Self._backupID(for: authToken)
		guard let url = Self._url(baseURLString: serverURLString, path: "/v1/backups/\(backupID)") else {
			throw FeatherBackupError.invalidEndpoint
		}
		
		var request = URLRequest(url: url)
		request.httpMethod = "PUT"
		request.timeoutInterval = 30
		request.httpBody = encryptedData
		request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
		request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
		request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
		
		do {
			let (_, response) = try await URLSession.shared.data(for: request)
			try Self._validate(response: response, allowNotFound: false)
			connectionState = .connected
		} catch {
			connectionState = .failed(error.localizedDescription)
			throw error
		}
		
		let now = Date()
		lastBackupDate = now
		UserDefaults.standard.set(now, forKey: Self._lastBackupKey)
	}
	
	@discardableResult
	func restoreCurrentBackup() async throws -> Int {
		guard !isBusy else { throw FeatherBackupError.busy }
		guard let recoveryKey else { throw FeatherBackupError.missingRecoveryKey }
		guard !serverURLString.isEmpty else { throw FeatherBackupError.missingServer }
		guard isConnected else { throw FeatherBackupError.notConnected }
		
		isBusy = true
		defer { isBusy = false }
		
		let authToken = Self._authToken(for: recoveryKey)
		let backupID = Self._backupID(for: authToken)
		guard let url = Self._url(baseURLString: serverURLString, path: "/v1/backups/\(backupID)/current") else {
			throw FeatherBackupError.invalidEndpoint
		}
		
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.timeoutInterval = 30
		request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
		request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
		
		let (encryptedData, response): (Data, URLResponse)
		do {
			(encryptedData, response) = try await URLSession.shared.data(for: request)
			try Self._validate(response: response, allowNotFound: true)
			connectionState = .connected
		} catch {
			connectionState = .failed(error.localizedDescription)
			throw error
		}
		
		let plainData: Data
		do {
			plainData = try Self._decrypt(encryptedData, recoveryKey: recoveryKey)
		} catch {
			throw FeatherBackupError.invalidBackup
		}
		
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let payload: FeatherBackupPayload
		do {
			payload = try decoder.decode(FeatherBackupPayload.self, from: plainData)
		} catch {
			throw FeatherBackupError.invalidBackup
		}
		
		guard payload.schemaVersion == 1 else {
			throw FeatherBackupError.unsupportedBackupVersion
		}
		
		InstallationRegistry.shared.restoreBackupRecords(payload.records)
		return payload.records.count
	}
	
	private func _validateServiceHealth() async throws {
		guard let url = Self._url(baseURLString: serverURLString, path: "/health") else {
			throw FeatherBackupError.invalidEndpoint
		}
		
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.timeoutInterval = 15
		request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		try Self._validate(response: response, allowNotFound: false)
		
		guard
			let health = try? JSONDecoder().decode(FeatherBackupHealthResponse.self, from: data),
			health.ok == true,
			health.service == "feather-backup"
		else {
			throw FeatherBackupError.invalidBackupService
		}
	}
	
	private func _validateCredentials(recoveryKey: String) async throws {
		let authToken = Self._authToken(for: recoveryKey)
		let backupID = Self._backupID(for: authToken)
		guard let url = Self._url(baseURLString: serverURLString, path: "/v1/backups/\(backupID)/current") else {
			throw FeatherBackupError.invalidEndpoint
		}
		
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.timeoutInterval = 15
		request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
		request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
		
		let (_, response) = try await URLSession.shared.data(for: request)
		guard let http = response as? HTTPURLResponse else {
			throw FeatherBackupError.invalidServerResponse
		}
		
		switch http.statusCode {
		case 200..<300, 404:
			return
		case 401, 403:
			throw FeatherBackupError.unauthorized
		default:
			throw FeatherBackupError.serverError(http.statusCode)
		}
	}
	
	private func _storeRecoveryKey(_ rawKey: String) throws {
		guard Self._saveRecoveryKey(rawKey) else {
			throw FeatherBackupError.unableToStoreKey
		}
		
		_automaticBackupTask?.cancel()
		recoveryKey = rawKey
		connectionState = .idle
		isEnabled = false
		UserDefaults.standard.set(false, forKey: Self._enabledKey)
	}
}

private extension BackupManager {
	static func _normalizeServerURL(_ value: String) -> String? {
		var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !candidate.isEmpty else { return nil }
		
		if !candidate.contains("://") {
			candidate = "https://\(candidate)"
		}
		
		guard var components = URLComponents(string: candidate) else { return nil }
		guard components.scheme?.lowercased() == "https" else { return nil }
		guard let host = components.host, !host.isEmpty else { return nil }
		components.scheme = "https"
		components.host = host.lowercased()
		components.query = nil
		components.fragment = nil
		
		if components.path == "/" {
			components.path = ""
		} else {
			while components.path.hasSuffix("/") {
				components.path.removeLast()
			}
		}
		
		return components.url?.absoluteString
	}
	
	static func _url(baseURLString: String, path: String) -> URL? {
		guard
			let normalized = _normalizeServerURL(baseURLString),
			var components = URLComponents(string: normalized)
		else {
			return nil
		}
		
		let basePath = components.path
		let requestedPath = path.hasPrefix("/") ? path : "/\(path)"
		components.path = basePath + requestedPath
		components.query = nil
		components.fragment = nil
		return components.url
	}
	
	static func _normalizeRecoveryKey(_ value: String) -> String? {
		var normalized = value
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.uppercased()
		
		if normalized.hasPrefix("FTHR-") {
			normalized.removeFirst(5)
		} else if normalized.hasPrefix("FTHR") {
			normalized.removeFirst(4)
		}
		
		normalized = normalized.filter { character in
			"0123456789ABCDEF".contains(character)
		}
		
		guard normalized.count == _keyLengthBytes * 2 else { return nil }
		return normalized
	}
	
	static func _formatRecoveryKey(_ rawKey: String) -> String {
		let groups = stride(from: 0, to: rawKey.count, by: 5).map { start -> String in
			let startIndex = rawKey.index(rawKey.startIndex, offsetBy: start)
			let endOffset = min(start + 5, rawKey.count)
			let endIndex = rawKey.index(rawKey.startIndex, offsetBy: endOffset)
			return String(rawKey[startIndex..<endIndex])
		}
		return "FTHR-" + groups.joined(separator: "-")
	}
	
	static func _authToken(for recoveryKey: String) -> String {
		_sha256Hex("feather-backup-auth-v1\n\(recoveryKey)")
	}
	
	static func _backupID(for authToken: String) -> String {
		_sha256Hex("feather-backup-id-v1\n\(authToken)")
	}
	
	static func _encryptionKey(for recoveryKey: String) -> SymmetricKey {
		let digest = SHA256.hash(
			data: Data("feather-backup-encryption-v1\n\(recoveryKey)".utf8)
		)
		return SymmetricKey(data: Data(digest))
	}
	
	static func _encrypt(_ data: Data, recoveryKey: String) throws -> Data {
		let sealed = try AES.GCM.seal(data, using: _encryptionKey(for: recoveryKey))
		guard let combined = sealed.combined else {
			throw FeatherBackupError.encryptionFailed
		}
		return combined
	}
	
	static func _decrypt(_ data: Data, recoveryKey: String) throws -> Data {
		let sealed = try AES.GCM.SealedBox(combined: data)
		return try AES.GCM.open(sealed, using: _encryptionKey(for: recoveryKey))
	}
	
	static func _sha256Hex(_ value: String) -> String {
		let digest = SHA256.hash(data: Data(value.utf8))
		return digest.map { String(format: "%02x", $0) }.joined()
	}
	
	static func _validate(response: URLResponse, allowNotFound: Bool) throws {
		guard let http = response as? HTTPURLResponse else {
			throw FeatherBackupError.invalidServerResponse
		}
		
		switch http.statusCode {
		case 200..<300:
			return
		case 401, 403:
			throw FeatherBackupError.unauthorized
		case 404 where allowNotFound:
			throw FeatherBackupError.backupNotFound
		default:
			throw FeatherBackupError.serverError(http.statusCode)
		}
	}
	
	static func _keychainQuery() -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: Bundle.main.bundleIdentifier ?? "Feather",
			kSecAttrAccount as String: _keychainAccount,
		]
	}
	
	static func _loadRecoveryKey() -> String? {
		var query = _keychainQuery()
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		
		var item: CFTypeRef?
		guard
			SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
			let data = item as? Data,
			let value = String(data: data, encoding: .utf8),
			let normalized = _normalizeRecoveryKey(value)
		else {
			return nil
		}
		return normalized
	}
	
	static func _saveRecoveryKey(_ value: String) -> Bool {
		let query = _keychainQuery()
		SecItemDelete(query as CFDictionary)
		
		guard let data = value.data(using: .utf8) else { return false }
		var item = query
		item[kSecValueData as String] = data
		item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
	}
	
	static func _deleteRecoveryKey() {
		SecItemDelete(_keychainQuery() as CFDictionary)
	}
}
