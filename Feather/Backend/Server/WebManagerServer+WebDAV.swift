//
//  WebManagerServer+WebDAV.swift
//  Feather
//

import Foundation
import Vapor

extension WebManagerServer {
	private static let davAllow = "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, MOVE, COPY, LOCK, UNLOCK"

	func _configureWebDAV(_ app: Application) {
		let all: [PathComponent] = ["**"]

		for path in [[PathComponent](), all] {
			app.on(.OPTIONS, path) { _ -> Response in
				var headers = HTTPHeaders()
				headers.replaceOrAdd(name: "DAV", value: "1, 2")
				headers.replaceOrAdd(name: "MS-Author-Via", value: "DAV")
				headers.replaceOrAdd(name: .allow, value: Self.davAllow)
				headers.replaceOrAdd(name: .contentLength, value: "0")
				return Response(status: .ok, headers: headers)
			}

			app.on(.init(rawValue: "PROPFIND"), path) { [weak self] request -> Response in
				self?._propfind(request)
					?? Response(status: .internalServerError)
			}
		}

		app.on(.init(rawValue: "PROPPATCH"), all) { [weak self] request -> Response in
			self?._proppatchOK(request) ?? Response(status: .ok)
		}

		for method in [HTTPMethod.GET, .HEAD] {
			app.on(method, all) { [weak self] request -> Response in
				self?._get(request, includeBody: method == .GET)
					?? Response(status: .notFound)
			}
		}

		app.on(.PUT, all, body: .stream) { [weak self] request -> EventLoopFuture<Response> in
			guard
				let self,
				let url = self.resolve(request.url.path)
			else {
				return request.eventLoop.makeSucceededFuture(
					Response(status: .forbidden)
				)
			}

			let path = request.url.path
			return self.streamToFile(
				request,
				destination: url,
				route: false,
				report: false,
				successStatus: .created
			).always { _ in
				self.scheduleDebouncedRoute(forPath: path, url: url)
			}
		}

		app.on(.init(rawValue: "MKCOL"), all) { [weak self] request -> Response in
			guard
				let self,
				let url = self.resolve(request.url.path)
			else {
				return Response(status: .forbidden)
			}

			do {
				try FileManager.default.createDirectory(
					at: url,
					withIntermediateDirectories: false
				)
				return Response(status: .created)
			} catch {
				return Response(status: .conflict)
			}
		}

		app.on(.DELETE, all) { [weak self] request -> Response in
			guard
				let self,
				let url = self.resolve(request.url.path)
			else {
				return Response(status: .forbidden)
			}

			guard FileManager.default.fileExists(atPath: url.path) else {
				return Response(status: .notFound)
			}

			try? FileManager.default.removeItem(at: url)
			return Response(status: .noContent)
		}

		app.on(.init(rawValue: "MOVE"), all) { [weak self] request -> Response in
			self?._moveOrCopy(request, move: true)
				?? Response(status: .forbidden)
		}

		app.on(.init(rawValue: "COPY"), all) { [weak self] request -> Response in
			self?._moveOrCopy(request, move: false)
				?? Response(status: .forbidden)
		}

		app.on(.init(rawValue: "LOCK"), all) { _ -> Response in
			let token = "opaquelocktoken:\(UUID().uuidString)"
			let xml = """
			<?xml version="1.0" encoding="utf-8"?>
			<D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>			<D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope>			<D:depth>infinity</D:depth><D:timeout>Second-3600</D:timeout>			<D:locktoken><D:href>\(token)</D:href></D:locktoken>			</D:activelock></D:lockdiscovery></D:prop>
			"""
			var headers = HTTPHeaders()
			headers.contentType = .xml
			headers.replaceOrAdd(name: "Lock-Token", value: "<\(token)>")
			return Response(
				status: .ok,
				headers: headers,
				body: .init(string: xml)
			)
		}

		app.on(.init(rawValue: "UNLOCK"), all) { _ in
			Response(status: .noContent)
		}
	}

	private func _get(_ request: Request, includeBody: Bool) -> Response {
		guard let url = resolve(request.url.path) else {
			return Response(status: .forbidden)
		}

		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(
			atPath: url.path,
			isDirectory: &isDirectory
		) else {
			return Response(status: .notFound)
		}

		if isDirectory.boolValue {
			return Response(status: .ok)
		}

		if !includeBody {
			let size =
				((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue
				?? 0
			var headers = HTTPHeaders()
			headers.replaceOrAdd(name: .contentLength, value: "\(size)")
			return Response(status: .ok, headers: headers)
		}

		return request.fileio.streamFile(at: url.path)
	}

	private func _moveOrCopy(_ request: Request, move: Bool) -> Response {
		guard
			let source = resolve(request.url.path),
			let destinationHeader = request.headers.first(name: "Destination"),
			let destinationPath = _path(fromDestination: destinationHeader),
			let destination = resolve(destinationPath)
		else {
			return Response(status: .forbidden)
		}

		let manager = FileManager.default
		guard manager.fileExists(atPath: source.path) else {
			return Response(status: .notFound)
		}

		let existed = manager.fileExists(atPath: destination.path)
		if existed {
			try? manager.removeItem(at: destination)
		}

		do {
			if move {
				try manager.moveItem(at: source, to: destination)
			} else {
				try manager.copyItem(at: source, to: destination)
			}

			if WebManagerRouter.shouldImport(destination) {
				scheduleDebouncedRoute(
					forPath: destination.path,
					url: destination
				)
			}

			return Response(status: existed ? .noContent : .created)
		} catch {
			return Response(status: .conflict)
		}
	}

	private func _proppatchOK(_ request: Request) -> Response {
		let href = _xmlEscape(request.url.path)
		let xml = """
		<?xml version="1.0" encoding="utf-8"?>
		<D:multistatus xmlns:D="DAV:"><D:response><D:href>\(href)</D:href>		<D:propstat><D:status>HTTP/1.1 200 OK</D:status></D:propstat>		</D:response></D:multistatus>
		"""
		var headers = HTTPHeaders()
		headers.contentType = .xml
		return Response(
			status: .init(statusCode: 207),
			headers: headers,
			body: .init(string: xml)
		)
	}

	private func _propfind(_ request: Request) -> Response {
		guard let url = resolve(request.url.path) else {
			return Response(status: .forbidden)
		}

		let manager = FileManager.default
		var isDirectory: ObjCBool = false

		guard manager.fileExists(
			atPath: url.path,
			isDirectory: &isDirectory
		) else {
			return Response(status: .notFound)
		}

		let depth = request.headers.first(name: "Depth") ?? "1"
		var basePath = request.url.path
		if isDirectory.boolValue && !basePath.hasSuffix("/") {
			basePath += "/"
		}

		var entries = _propEntry(
			for: url,
			href: basePath,
			isDirectory: isDirectory.boolValue
		)

		if isDirectory.boolValue && depth != "0" {
			let children = (try? manager.contentsOfDirectory(
				at: url,
				includingPropertiesForKeys: nil,
				options: [.skipsHiddenFiles]
			)) ?? []

			for child in children {
				var childIsDirectory: ObjCBool = false
				manager.fileExists(
					atPath: child.path,
					isDirectory: &childIsDirectory
				)

				let childHref =
					basePath
					+ _urlEncode(child.lastPathComponent)
					+ (childIsDirectory.boolValue ? "/" : "")

				entries += _propEntry(
					for: child,
					href: childHref,
					isDirectory: childIsDirectory.boolValue
				)
			}
		}

		let xml = """
		<?xml version="1.0" encoding="utf-8"?>
		<D:multistatus xmlns:D="DAV:">\(entries)</D:multistatus>
		"""
		var headers = HTTPHeaders()
		headers.contentType = .xml
		return Response(
			status: .init(statusCode: 207),
			headers: headers,
			body: .init(string: xml)
		)
	}

	private func _propEntry(
		for url: URL,
		href: String,
		isDirectory: Bool
	) -> String {
		let attributes =
			(try? FileManager.default.attributesOfItem(atPath: url.path))
			?? [:]
		let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
		let modified =
			(attributes[.modificationDate] as? Date)
			?? Date(timeIntervalSince1970: 0)

		let resourceType = isDirectory ? "<D:collection/>" : ""
		let length =
			isDirectory
			? ""
			: "<D:getcontentlength>\(size)</D:getcontentlength>"

		return """
		<D:response><D:href>\(_xmlEscape(href))</D:href><D:propstat><D:prop>		<D:displayname>\(_xmlEscape(url.lastPathComponent))</D:displayname>		\(length)<D:getlastmodified>\(Self.httpDate(modified))</D:getlastmodified>		<D:resourcetype>\(resourceType)</D:resourcetype></D:prop>		<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
		"""
	}

	private func _path(fromDestination header: String) -> String? {
		if let components = URLComponents(string: header),
		   components.scheme != nil {
			return components.percentEncodedPath
		}
		return header
	}

	private func _urlEncode(_ component: String) -> String {
		component.addingPercentEncoding(
			withAllowedCharacters: .urlPathAllowed
		) ?? component
	}

	private func _xmlEscape(_ string: String) -> String {
		string
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
	}

	static func httpDate(_ date: Date) -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(identifier: "GMT")
		formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
		return formatter.string(from: date)
	}
}
