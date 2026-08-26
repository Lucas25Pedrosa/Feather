//
//  FetchService.swift
//  Loader
//
//  Created by samara on 14.03.2025.
//

import Foundation

// MARK: - Class
public class NBFetchService {
	
	public enum NBFetchServiceError: Error, LocalizedError {
		case invalidURL
		case networkError(Error)
		case noData
		case parsingError(Error)
		
		public var errorDescription: String? {
			switch self {
			case .invalidURL: "The URL is invalid."
			case .networkError(let error): "Network error: \(error.localizedDescription)"
			case .noData: "No data received."
			case .parsingError(let error): "Failed to parse data: \(error.localizedDescription)"
			}
		}
	}
	
	private static let _ephemeralSession: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.urlCache = nil
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.httpCookieStorage = nil
		return URLSession(configuration: configuration)
	}()
	
	public init() {}
}

// MARK: - Class extension: fetch
extension NBFetchService {
	public func fetch<T: Decodable>(
		from urlString: String,
		forceReload: Bool = false,
		completion: @escaping (Result<T, Error>) -> Void
	) {
		guard let url = URL(string: urlString) else {
			completion(.failure(NBFetchServiceError.invalidURL))
			return
		}
		
		fetch(from: url, forceReload: forceReload, completion: completion)
	}
	
	public func fetch<T: Decodable>(
		from url: URL,
		forceReload: Bool = false,
		completion: @escaping (Result<T, Error>) -> Void
	) {
		DispatchQueue.global(qos: .userInitiated).async {
			if forceReload {
				let refreshedURL = self._cacheBustedURL(url)
				self._performFetch(
					from: refreshedURL,
					forceReload: true,
					session: Self._ephemeralSession
				) { (result: Result<T, Error>) in
					switch result {
					case .success:
						completion(result)
					case .failure where refreshedURL != url:
						// Some signed or strict endpoints reject unknown query items.
						// Fall back to the original URL while still bypassing local cache.
						self._performFetch(
							from: url,
							forceReload: true,
							session: Self._ephemeralSession,
							completion: completion
						)
					case .failure:
						completion(result)
					}
				}
			} else {
				self._performFetch(
					from: url,
					forceReload: false,
					session: .shared,
					completion: completion
				)
			}
		}
	}
	
	private func _performFetch<T: Decodable>(
		from url: URL,
		forceReload: Bool,
		session: URLSession,
		completion: @escaping (Result<T, Error>) -> Void
	) {
		var request = URLRequest(
			url: url,
			cachePolicy: forceReload ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
		)
		
		if forceReload {
			request.setValue("no-cache, no-store, max-age=0, must-revalidate", forHTTPHeaderField: "Cache-Control")
			request.setValue("no-cache", forHTTPHeaderField: "Pragma")
		}
		
		let task = session.dataTask(with: request) { data, _, error in
			if let error = error {
				completion(.failure(NBFetchServiceError.networkError(error)))
				return
			}
			
			guard let data = data else {
				completion(.failure(NBFetchServiceError.noData))
				return
			}
			
			do {
				let decoder = JSONDecoder()
				let decodedData = try decoder.decode(T.self, from: data)
				completion(.success(decodedData))
			} catch {
				completion(.failure(NBFetchServiceError.parsingError(error)))
			}
		}
		
		task.resume()
	}
	
	private func _cacheBustedURL(_ url: URL) -> URL {
		guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
			return url
		}
		
		var queryItems = components.queryItems ?? []
		queryItems.removeAll { $0.name == "_feather_refresh" }
		queryItems.append(
			URLQueryItem(
				name: "_feather_refresh",
				value: String(Int(Date().timeIntervalSince1970 * 1000))
			)
		)
		components.queryItems = queryItems
		return components.url ?? url
	}
}
