//
//  UpdateEnginePreferences.swift
//  Feather
//
//  Feather 3.2 automatic update preferences.
//

import Foundation

@MainActor
final class UpdateEnginePreferences: ObservableObject {
	static let shared = UpdateEnginePreferences()

	private static let _certificateKey = "Feather.updateEngine.defaultCertificateUUID"

	@Published private(set) var defaultCertificateUUID: String?

	private init() {
		defaultCertificateUUID = UserDefaults.standard.string(forKey: Self._certificateKey)
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
		guard let certificate = selectedCertificate() else { return nil }
		guard certificate.revoked != true else { return nil }
		if let expiration = certificate.expiration, expiration <= Date() {
			return nil
		}
		return certificate
	}
}
