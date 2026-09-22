//
//  UpdateEnginePreferences.swift
//  Feather
//
//  Feather 3.4 automatic installation preferences.
//

import Combine
import Foundation

@MainActor
final class UpdateEnginePreferences: ObservableObject {
	static let shared = UpdateEnginePreferences()

	static let quickInstallKey = "Feather.quickInstall.enabled"
	private static let _certificateKey = "Feather.updateEngine.defaultCertificateUUID"

	@Published private(set) var defaultCertificateUUID: String?
	@Published var quickInstallEnabled: Bool {
		didSet {
			UserDefaults.standard.set(quickInstallEnabled, forKey: Self.quickInstallKey)
		}
	}

	private init() {
		let defaults = UserDefaults.standard
		defaultCertificateUUID = defaults.string(forKey: Self._certificateKey)

		if defaults.object(forKey: Self.quickInstallKey) != nil {
			quickInstallEnabled = defaults.bool(forKey: Self.quickInstallKey)
		} else {
			quickInstallEnabled = defaultCertificateUUID != nil
		}
	}

	func selectCertificate(_ certificate: CertificatePair?) {
		let uuid = certificate?.uuid
		defaultCertificateUUID = uuid

		if let uuid, !uuid.isEmpty {
			UserDefaults.standard.set(uuid, forKey: Self._certificateKey)
		} else {
			UserDefaults.standard.removeObject(forKey: Self._certificateKey)
		}
	}

	func selectedCertificate() -> CertificatePair? {
		guard let uuid = defaultCertificateUUID, !uuid.isEmpty else { return nil }
		return Storage.shared.getAllCertificates().first { $0.uuid == uuid }
	}

	func usableCertificate() -> CertificatePair? {
		let certificates = Storage.shared.getAllCertificates()

		if certificates.count == 1 {
			let onlyCertificate = certificates[0]
			return _isUsable(onlyCertificate) ? onlyCertificate : nil
		}

		guard certificates.count >= 2, let certificate = selectedCertificate() else {
			return nil
		}
		return _isUsable(certificate) ? certificate : nil
	}

	private func _isUsable(_ certificate: CertificatePair) -> Bool {
		guard certificate.revoked != true else { return false }
		guard let expiration = certificate.expiration else { return false }
		return expiration > Date()
	}
}
