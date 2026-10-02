//
//  WebManagerServer+HTTP.swift
//  Feather
//

import Foundation
import Vapor

private struct WebManagerFileInfo: Content {
	let name: String
	let size: Int
}

extension WebManagerServer {
	func _configureHTTP(_ app: Application) {
		app.get { _ -> Response in
			var headers = HTTPHeaders()
			headers.contentType = .html
			return Response(
				status: .ok,
				headers: headers,
				body: .init(string: Self.pageHTML)
			)
		}

		app.get("health") { _ in
			Response(status: .ok, body: .init(string: "Feather Web Manager"))
		}

		app.on(.POST, "upload", ":name", body: .stream) { [weak self] request -> EventLoopFuture<Response> in
			guard let self else {
				return request.eventLoop.makeSucceededFuture(
					Response(status: .internalServerError)
				)
			}

			let name = self.sanitizedFilename(
				request.parameters.get("name") ?? "upload.bin"
			)
			let destination = self.inbox.appendingPathComponent(name)

			return self.streamToFile(
				request,
				destination: destination,
				route: true,
				successStatus: .ok
			)
		}

		app.get("api", "files") { [weak self] _ -> Response in
			guard let self else {
				return Response(status: .internalServerError)
			}

			let data = (try? JSONEncoder().encode(self._inboxFiles()))
				?? Data("[]".utf8)
			var headers = HTTPHeaders()
			headers.contentType = .json
			return Response(
				status: .ok,
				headers: headers,
				body: .init(data: data)
			)
		}

		app.get("download", ":name") { [weak self] request -> Response in
			guard
				let self,
				let raw = request.parameters.get("name")
			else {
				return Response(status: .badRequest)
			}

			let url = self.inbox.appendingPathComponent(
				self.sanitizedFilename(raw)
			)
			guard FileManager.default.fileExists(atPath: url.path) else {
				return Response(status: .notFound)
			}

			let response = request.fileio.streamFile(at: url.path)
			response.headers.replaceOrAdd(
				name: .contentDisposition,
				value: "attachment; filename=\"\(url.lastPathComponent)\""
			)
			return response
		}

		app.on(.DELETE, "api", "files", ":name") { [weak self] request -> Response in
			guard
				let self,
				let raw = request.parameters.get("name")
			else {
				return Response(status: .badRequest)
			}

			try? FileManager.default.removeItem(
				at: self.inbox.appendingPathComponent(
					self.sanitizedFilename(raw)
				)
			)
			return Response(status: .noContent)
		}
	}

	private func _inboxFiles() -> [WebManagerFileInfo] {
		let manager = FileManager.default
		guard let contents = try? manager.contentsOfDirectory(
			at: inbox,
			includingPropertiesForKeys: [.fileSizeKey],
			options: [.skipsHiddenFiles]
		) else {
			return []
		}

		return contents
			.filter { !$0.hasDirectoryPath }
			.map { url in
				let size =
					(try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
					?? 0
				return WebManagerFileInfo(
					name: url.lastPathComponent,
					size: size
				)
			}
			.sorted {
				$0.name.localizedCaseInsensitiveCompare($1.name)
					== .orderedAscending
			}
	}

	private static let pageHTML: String = {
		guard
			let url = Bundle.main.url(
				forResource: "WebManager",
				withExtension: "html"
			),
			let html = try? String(contentsOf: url, encoding: .utf8)
		else {
			return "<h1>Feather Web Manager</h1>"
		}
		return html
	}()
}
