//
//  WebManager.swift
//  Feather
//

import Foundation
import UIKit
import OSLog
import Darwin

@MainActor
final class WebManager: ObservableObject {
	static let shared = WebManager()

	@Published private(set) var isRunning = false
	@Published private(set) var recentUploads: [String] = []
	@Published var lastError: String?

	@Published var port: Int {
		didSet { UserDefaults.standard.set(port, forKey: "Feather.webManager.port") }
	}
	@Published var requireAuth: Bool {
		didSet { UserDefaults.standard.set(requireAuth, forKey: "Feather.webManager.auth") }
	}
	@Published var username: String {
		didSet { UserDefaults.standard.set(username, forKey: "Feather.webManager.user") }
	}
	@Published var password: String {
		didSet { UserDefaults.standard.set(password, forKey: "Feather.webManager.pass") }
	}
	@Published var keepAlive: Bool {
		didSet {
			UserDefaults.standard.set(keepAlive, forKey: "Feather.webManager.keepAlive")
			_applyKeepAlive()
		}
	}

	private var server: WebManagerServer?

	private init() {
		let defaults = UserDefaults.standard
		port = defaults.object(forKey: "Feather.webManager.port") as? Int ?? 8080
		requireAuth = defaults.bool(forKey: "Feather.webManager.auth")
		username = defaults.string(forKey: "Feather.webManager.user") ?? "feather"
		password = defaults.string(forKey: "Feather.webManager.pass") ?? ""
		keepAlive = defaults.bool(forKey: "Feather.webManager.keepAlive")

		NotificationCenter.default.addObserver(
			forName: UIApplication.didEnterBackgroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				guard let self else { return }
				if !self.keepAlive {
					self.stop()
				}
			}
		}
	}

	var authActive: Bool {
		requireAuth && !username.isEmpty && !password.isEmpty
	}

	var localAddress: String {
		Self._localNetworkAddress() ?? "127.0.0.1"
	}

	var httpURL: String {
		"http://\(localAddress):\(port)/"
	}

	var webdavURL: String {
		"http://\(localAddress):\(port)/"
	}

	func start() {
		guard !isRunning else { return }
		lastError = nil

		let auth: WebManagerServer.Auth? = authActive
			? .init(username: username, password: password)
			: nil

		do {
			server = try WebManagerServer(port: port, auth: auth) { [weak self] name in
				DispatchQueue.main.async {
					guard let self else { return }
					self.recentUploads.removeAll { $0 == name }
					self.recentUploads.insert(name, at: 0)
					if self.recentUploads.count > 20 {
						self.recentUploads = Array(self.recentUploads.prefix(20))
					}
				}
			}
			isRunning = true
			_applyKeepAlive()
		} catch {
			Logger.misc.error("Web Manager failed to start: \(error.localizedDescription)")
			lastError = error.localizedDescription
			server = nil
			isRunning = false
		}
	}

	func stop() {
		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.stop(owner: "web-manager")
		#endif
		server?.shutdown()
		server = nil
		isRunning = false
	}

	func toggle() {
		isRunning ? stop() : start()
	}

	func restartIfRunning() {
		guard isRunning else { return }
		stop()
		start()
	}

	func clearRecent() {
		recentUploads.removeAll()
	}

	private func _applyKeepAlive() {
		#if !targetEnvironment(macCatalyst)
		if isRunning && keepAlive {
			BackgroundAudioManager.shared.start(owner: "web-manager")
		} else {
			BackgroundAudioManager.shared.stop(owner: "web-manager")
		}
		#endif
	}
	private static func _localNetworkAddress() -> String? {
		var interfaces: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&interfaces) == 0, let first = interfaces else {
			return nil
		}
		defer { freeifaddrs(interfaces) }

		var fallback: String?
		var pointer: UnsafeMutablePointer<ifaddrs>? = first

		while let current = pointer {
			defer { pointer = current.pointee.ifa_next }

			guard let address = current.pointee.ifa_addr else { continue }
			guard address.pointee.sa_family == UInt8(AF_INET) else { continue }

			let name = String(cString: current.pointee.ifa_name)
			if name.hasPrefix("lo")
				|| name.hasPrefix("utun")
				|| name.hasPrefix("pdp_ip") {
				continue
			}

			var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
			let result = getnameinfo(
				address,
				socklen_t(address.pointee.sa_len),
				&host,
				socklen_t(host.count),
				nil,
				0,
				NI_NUMERICHOST
			)
			guard result == 0 else { continue }

			let value = String(cString: host)
			if name == "en0" {
				return value
			}
			if fallback == nil && (name.hasPrefix("en") || name.hasPrefix("bridge")) {
				fallback = value
			}
		}

		return fallback
	}

}
