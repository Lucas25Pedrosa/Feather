//
//  WebManagerServer.swift
//  Feather
//
//  Local HTTP + WebDAV transfer server.
//

import Foundation
import Vapor
import OSLog

struct WebManagerAuthMiddleware: AsyncMiddleware {
	let username: String
	let password: String

	func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
		if
			let basic = request.headers.basicAuthorization,
			Self.constantTimeEquals(basic.username, username),
			Self.constantTimeEquals(basic.password, password)
		{
			return try await next.respond(to: request)
		}

		var headers = HTTPHeaders()
		headers.replaceOrAdd(name: .wwwAuthenticate, value: "Basic realm=\"Feather Web Manager\"")
		return Response(status: .unauthorized, headers: headers)
	}

	private static func constantTimeEquals(_ lhsString: String, _ rhsString: String) -> Bool {
		let lhs = Array(lhsString.utf8)
		let rhs = Array(rhsString.utf8)
		var diff = lhs.count ^ rhs.count

		for index in 0..<lhs.count {
			diff |= Int(lhs[index]) ^ Int(rhs[index < rhs.count ? index : 0])
		}

		return diff == 0
	}
}

enum WebManagerRouter {
	static func shouldImport(_ url: URL) -> Bool {
		["ipa", "tipa"].contains(url.pathExtension.lowercased())
	}

	static func route(_ url: URL) {
		guard shouldImport(url) else { return }

		Task { @MainActor in
			FR.handlePackageFile(url) { error in
				if let error {
					Logger.misc.error("Web Manager import failed: \(error.localizedDescription)")
				} else {
					try? FileManager.default.removeItem(at: url)
				}
			}
		}
	}
}

final class WebManagerServer {
	struct Auth {
		let username: String
		let password: String
	}

	let port: Int
	let inbox: URL

	private let onReceive: (String) -> Void
	private var app: Application?
	private var needsShutdown = false
	private let debounceQueue = DispatchQueue(label: "feather.webmanager.debounce")
	private var pendingRoutes: [String: DispatchWorkItem] = [:]

	init(port: Int, auth: Auth?, onReceive: @escaping (String) -> Void) throws {
		self.port = port
		self.inbox = FileManager.default.webManagerInbox
		self.onReceive = onReceive

		try FileManager.default.createDirectoryIfNeeded(at: inbox)

		let app = Application(ServerInstaller.env)
		app.threadPool = .init(numberOfThreads: 2)
		app.http.server.configuration.hostname = "0.0.0.0"
		app.http.server.configuration.tcpNoDelay = true
		app.http.server.configuration.address = .hostname("0.0.0.0", port: port)
		app.http.server.configuration.port = port
		app.routes.defaultMaxBodySize = "2gb"
		app.routes.caseInsensitive = true

		if let auth {
			app.middleware.use(
				WebManagerAuthMiddleware(
					username: auth.username,
					password: auth.password
				)
			)
		}

		_configureHTTP(app)
		_configureWebDAV(app)

		try app.server.start()
		self.app = app
		needsShutdown = true
		Logger.misc.info("Feather Web Manager started on port \(port)")
	}

	deinit {
		shutdown()
	}

	func shutdown() {
		guard needsShutdown else { return }
		needsShutdown = false

		debounceQueue.async {
			self.pendingRoutes.values.forEach { $0.cancel() }
			self.pendingRoutes.removeAll()
		}

		app?.server.shutdown()
		app?.shutdown()
		app = nil
	}

	func reportReceived(_ name: String) {
		onReceive(name)
	}

	func resolve(_ path: String) -> URL? {
		let decoded = path.removingPercentEncoding ?? path
		let components = decoded
			.split(separator: "/", omittingEmptySubsequences: true)
			.map(String.init)

		guard !components.contains("..") else { return nil }

		var url = inbox
		for component in components {
			url.appendPathComponent(component)
		}
		return url
	}

	func sanitizedFilename(_ name: String) -> String {
		let decoded = name.removingPercentEncoding ?? name
		let last = (decoded as NSString).lastPathComponent
		let cleaned = last.replacingOccurrences(of: "/", with: "_")
		return cleaned.isEmpty ? "upload-\(UUID().uuidString).bin" : cleaned
	}

	func streamToFile(
		_ request: Request,
		destination: URL,
		route: Bool,
		keepOriginal: Bool = false,
		report: Bool = true,
		successStatus: HTTPResponseStatus
	) -> EventLoopFuture<Response> {
		let manager = FileManager.default
		try? manager.createDirectoryIfNeeded(at: destination.deletingLastPathComponent())
		try? manager.removeItem(at: destination)

		guard manager.createFile(atPath: destination.path, contents: nil) else {
			return request.eventLoop.makeSucceededFuture(Response(status: .internalServerError))
		}

		let handle: FileHandle
		do {
			handle = try FileHandle(forWritingTo: destination)
		} catch {
			return request.eventLoop.makeSucceededFuture(Response(status: .internalServerError))
		}

		let promise = request.eventLoop.makePromise(of: Response.self)

		request.body.drain { part in
			switch part {
			case .buffer(let buffer):
				do {
					try handle.write(contentsOf: Data(buffer.readableBytesView))
				} catch {
					try? handle.close()
					promise.fail(error)
				}
			case .error(let error):
				try? handle.close()
				try? manager.removeItem(at: destination)
				promise.fail(error)
			case .end:
				try? handle.close()

				if report {
					self.reportReceived(destination.lastPathComponent)
				}

				if route && WebManagerRouter.shouldImport(destination) {
					let target = keepOriginal
						? (Self.stagedCopy(of: destination) ?? destination)
						: destination
					WebManagerRouter.route(target)
				}

				promise.succeed(Response(status: successStatus))
			}

			return request.eventLoop.makeSucceededFuture(())
		}

		return promise.futureResult
	}

	func scheduleDebouncedRoute(forPath path: String, url: URL) {
		debounceQueue.async {
			self.pendingRoutes[path]?.cancel()

			let work = DispatchWorkItem { [weak self] in
				guard let self else { return }

				let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
				guard size > 0 else { return }

				if WebManagerRouter.shouldImport(url) {
					WebManagerRouter.route(Self.stagedCopy(of: url) ?? url)
				}

				self.reportReceived(url.lastPathComponent)
				self.debounceQueue.async {
					self.pendingRoutes[path] = nil
				}
			}

			self.pendingRoutes[path] = work
			self.debounceQueue.asyncAfter(
				deadline: .now() + 1.25,
				execute: work
			)
		}
	}

	static func stagedCopy(of url: URL) -> URL? {
		let manager = FileManager.default
		let directory = manager.temporaryDirectory
			.appendingPathComponent(
				"FeatherWebManager-\(UUID().uuidString)",
				isDirectory: true
			)
		let destination = directory.appendingPathComponent(url.lastPathComponent)

		do {
			try manager.createDirectoryIfNeeded(at: directory)
			try manager.copyItem(at: url, to: destination)
			return destination
		} catch {
			return nil
		}
	}
}
