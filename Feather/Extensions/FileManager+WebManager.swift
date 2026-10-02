//
//  FileManager+WebManager.swift
//  Feather
//

import Foundation

extension FileManager {
	var webManagerInbox: URL {
		let support = urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL.documentsDirectory
		return support
			.appendingPathComponent("WebManager", isDirectory: true)
			.appendingPathComponent("Inbox", isDirectory: true)
	}
}
