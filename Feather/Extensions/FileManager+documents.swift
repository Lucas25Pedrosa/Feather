//
//  FileManager+documents.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import Foundation

extension FileManager {


	/// Private storage for Fully Local TLS material.
	var fullyLocalTLS: URL {
		let applicationSupport =
			urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL.documentsDirectory.appendingPathComponent("Application Support", isDirectory: true)

		return applicationSupport.appendingPathComponent("FeatherTLS", isDirectory: true)
	}

	/// Returns a file inside the private Fully Local TLS directory.
	func fullyLocalTLS(_ filename: String) -> URL {
		fullyLocalTLS.appendingPathComponent(filename)
	}

	/// Stores the Fully Local certificate, private key and common name outside Documents.
	func storeFullyLocalTLS(
		cert: String,
		key: String,
		commonName: String
	) throws {
		let directory = fullyLocalTLS
		if !fileExists(atPath: directory.path) {
			try createDirectory(
				at: directory,
				withIntermediateDirectories: true,
				attributes: nil
			)
		}

		let files: [(URL, String)] = [
			(fullyLocalTLS("server.crt"), cert),
			(fullyLocalTLS("server.pem"), key),
			(fullyLocalTLS("commonName.txt"), commonName),
		]

		for (url, content) in files {
			try content.write(to: url, atomically: true, encoding: .utf8)
			try setAttributes(
				[.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
				ofItemAtPath: url.path
			)
		}
	}

	/// Removes all locally stored Fully Local TLS material.
	func removeFullyLocalTLS() throws {
		let directory = fullyLocalTLS
		if fileExists(atPath: directory.path) {
			try removeItem(at: directory)
		}
	}
	/// Gives apps Signed directory
	var archives: URL {
		URL.documentsDirectory.appendingPathComponent("Archives")
	}
	
	/// Gives apps Signed directory
	var signed: URL {
		URL.documentsDirectory.appendingPathComponent("Signed")
	}
	
	/// Gives apps Signed directory with a UUID appending path
	func signed(_ uuid: String) -> URL {
		signed.appendingPathComponent(uuid)
	}
	
	/// Gives apps Unsigned directory
	var unsigned: URL {
		URL.documentsDirectory.appendingPathComponent("Unsigned")
	}
	
	/// Gives apps Unsigned directory with a UUID appending path
	func unsigned(_ uuid: String) -> URL {
		unsigned.appendingPathComponent(uuid)
	}
	
	/// Gives apps Certificates directory
	var certificates: URL {
		URL.documentsDirectory.appendingPathComponent("Certificates")
	}
	/// Gives apps Certificates directory with a UUID appending path
	func certificates(_ uuid: String) -> URL {
		certificates.appendingPathComponent(uuid)
	}
}
