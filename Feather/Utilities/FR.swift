//
//  FR.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation.NSURL
import UIKit.UIImage
import Zsign
import NimbleJSON
import AltSourceKit
import IDeviceSwift

enum FullyLocalAuthenticationError: LocalizedError {
	case invalidURL
	case invalidResponse
	case invalidPassword
	case incompleteResponse
	case server(String)
	
	var errorDescription: String? {
		switch self {
		case .invalidURL:
			return "The Fully Local authentication URL is invalid."
		case .invalidResponse:
			return "The Fully Local server returned an invalid response."
		case .invalidPassword:
			return "Invalid password."
		case .incompleteResponse:
			return "The Fully Local server returned incomplete TLS material."
		case .server(let message):
			return message
		}
	}
}

private struct FullyLocalAuthenticationResponse: Decodable {
	let authenticated: Bool
	let cert: String
	let ca: String
	let key: String
	let commonName: String
}

private struct FullyLocalAPIErrorResponse: Decodable {
	let error: String?
}

enum FR {
	static func handlePackageFile(
		_ ipa: URL,
		download: Download? = nil,
		sourceProvenance: SourceAppProvenance? = nil,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = AppFileHandler(
				file: ipa,
				download: download,
				sourceProvenance: sourceProvenance
			)
			
			do {
				try await handler.copy()
				try await handler.extract()
				try await handler.move()
				try await handler.addToDatabase()
				try? await handler.clean()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				try? await handler.clean()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func signPackageFile(
		_ app: AppInfoPresentable,
		using options: Options,
		icon: UIImage?,
		certificate: CertificatePair?,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = SigningHandler(app: app, options: options)
			handler.appCertificate = certificate
			handler.appIcon = icon
			
			do {
				try await handler.copy()
				try await handler.modify()
				try? await handler.clean()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				try? await handler.clean()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func handleCertificateFiles(
		p12URL: URL,
		provisionURL: URL,
		p12Password: String,
		certificateName: String = "",
		isDefault: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = CertificateFileHandler(
				key: p12URL,
				provision: provisionURL,
				password: p12Password,
				nickname: certificateName.isEmpty ? nil : certificateName,
				isDefault: isDefault
			)
			
			do {
				try await handler.copy()
				try await handler.addToDatabase()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func checkPasswordForCertificate(
		for key: URL,
		with password: String,
		using provision: URL
	) -> Bool {
		defer {
			password_check_fix_WHAT_THE_FUCK_free(provision.path)
		}
		
		password_check_fix_WHAT_THE_FUCK(provision.path)
		
		if (!p12_password_check(key.path, password)) {
			return false
		}
		
		return true
	}
	
	static func movePairing(_ url: URL) {
		let fileManager = FileManager.default
		let dest = URL.documentsDirectory.appendingPathComponent("pairingFile.plist")
		
		try? fileManager.removeFileIfNeeded(at: dest)
		
		try? fileManager.copyItem(at: url, to: dest)
		
		HeartbeatManager.shared.start(true)
	}
	
	static func authenticateFullyLocal(
		password: String,
		completion: @escaping (Result<Void, Error>) -> Void
	) {
		guard let url = URL(string: "https://feather-install.lucaspedrosa.shop/v1/auth") else {
			completion(.failure(FullyLocalAuthenticationError.invalidURL))
			return
		}
		
		var request = URLRequest(
			url: url,
			cachePolicy: .reloadIgnoringLocalCacheData,
			timeoutInterval: 30
		)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
		
		do {
			request.httpBody = try JSONSerialization.data(
				withJSONObject: ["password": password],
				options: []
			)
		} catch {
			completion(.failure(error))
			return
		}
		
		URLSession.shared.dataTask(with: request) { data, response, error in
			if let error {
				completion(.failure(error))
				return
			}
			
			guard
				let httpResponse = response as? HTTPURLResponse,
				let data
			else {
				completion(.failure(FullyLocalAuthenticationError.invalidResponse))
				return
			}
			
			guard (200...299).contains(httpResponse.statusCode) else {
				if httpResponse.statusCode == 401 {
					completion(.failure(FullyLocalAuthenticationError.invalidPassword))
					return
				}
				
				let apiError = try? JSONDecoder().decode(
					FullyLocalAPIErrorResponse.self,
					from: data
				)
				let message = apiError?.error ?? "Fully Local server error (HTTP \(httpResponse.statusCode))."
				completion(.failure(FullyLocalAuthenticationError.server(message)))
				return
			}
			
			do {
				let pack = try JSONDecoder().decode(
					FullyLocalAuthenticationResponse.self,
					from: data
				)
				
				let cert = pack.cert.trimmingCharacters(in: .whitespacesAndNewlines)
				let ca = pack.ca.trimmingCharacters(in: .whitespacesAndNewlines)
				let key = pack.key.trimmingCharacters(in: .whitespacesAndNewlines)
				let commonName = pack.commonName.trimmingCharacters(in: .whitespacesAndNewlines)
				
				guard
					pack.authenticated,
					!cert.isEmpty,
					!ca.isEmpty,
					!key.isEmpty,
					!commonName.isEmpty
				else {
					completion(.failure(FullyLocalAuthenticationError.incompleteResponse))
					return
				}
				
				let certificateChain = cert + "\n" + ca
				
				try FileManager.default.storeFullyLocalTLS(
					cert: certificateChain,
					key: key,
					commonName: commonName
				)
				
				completion(.success(()))
			} catch {
				completion(.failure(error))
			}
		}.resume()
	}
	
	static func downloadSSLCertificates(
		from urlString: String,
		completion: @escaping (Bool) -> Void
	) {
		let generator = UINotificationFeedbackGenerator()
		generator.prepare()
		
		NBFetchService().fetch(from: urlString) { (result: Result<ServerView.ServerPackModel, Error>) in
			switch result {
			case .success(let pack):
				do {
					try FileManager.forceWrite(content: pack.key, to: "server.pem")
					try FileManager.forceWrite(content: pack.cert, to: "server.crt")
					try FileManager.forceWrite(content: pack.info.domains.commonName, to: "commonName.txt")
					generator.notificationOccurred(.success)
					completion(true)
				} catch {
					completion(false)
				}
			case .failure(_):
				completion(false)
			}
		}
	}
	
	static func handleSource(
		_ urlString: String,
		competion: @escaping () -> Void
	) {
		guard let url = URL(string: urlString) else { return }
		
		NBFetchService().fetch<ASRepository>(from: url) { (result: Result<ASRepository, Error>) in
			switch result {
			case .success(let data):
				let id = data.id ?? url.absoluteString
				
				if !Storage.shared.sourceExists(id) {
					Storage.shared.addSource(url, repository: data, id: id) { _ in
						competion()
					}
				} else {
					DispatchQueue.main.async {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Repository already added."))
					}
				}
			case .failure(let error):
				DispatchQueue.main.async {
					UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
				}
			}
		}
	}
	
	static func exportCertificateAndOpenUrl(using template: String) {
		// Helper that performs the export for a given certificate
		func performExport(for certificate: CertificatePair) {
			guard
				let certificateKeyFile = Storage.shared.getFile(.certificate, from: certificate),
				let certificateKeyFileData = try? Data(contentsOf: certificateKeyFile)
			else {
				return
			}
			
			let base64encodedCert = certificateKeyFileData.base64EncodedString()
			
			var allowedQueryParamAndKey = NSCharacterSet.urlQueryAllowed
			allowedQueryParamAndKey.remove(charactersIn: ";/?:@&=+$, ")
			
			guard let encodedCert = base64encodedCert.addingPercentEncoding(withAllowedCharacters: allowedQueryParamAndKey) else {
				return
			}
			
			let urlStr = template
				.replacingOccurrences(of: "$(BASE64_CERT)", with: encodedCert)
				.replacingOccurrences(of: "$(PASSWORD)", with: certificate.password ?? "")
			
			guard let callbackUrl = URL(string: urlStr) else {
				return
			}
			
			UIApplication.shared.open(callbackUrl)
		}
		
		let certificates = Storage.shared.getAllCertificates()
		guard !certificates.isEmpty else { return }
		
		DispatchQueue.main.async {
			var selectionActions: [UIAlertAction] = []
			
			for cert in certificates {
				var title: String
				let decoded = Storage.shared.getProvisionFileDecoded(for: cert)
				
				title = cert.nickname ?? decoded?.Name ?? .localized("Unknown")
				
				if let getTaskAllow = decoded?.Entitlements?["get-task-allow"]?.value as? Bool, getTaskAllow == true {
					title = "🐞 \(title)"
				}
				
				let selectAction = UIAlertAction(title: title, style: .default) { _ in
					performExport(for: cert)
				}
				selectionActions.append(selectAction)
			}
			
			UIAlertController.showAlertWithCancel(
				title: .localized("Export Certificate"),
				message: .localized("Do you want to export your certificate to an external app? That app will be able to sign apps using your certificate."),
				style: .alert,
				actions: selectionActions
			)
		}
	}
}
