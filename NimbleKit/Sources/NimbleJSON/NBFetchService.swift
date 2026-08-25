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
			var request = URLRequest(
				url: url,
				cachePolicy: forceReload ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
			)
			
			if forceReload {
				request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
				request.setValue("no-cache", forHTTPHeaderField: "Pragma")
			}
			
			let task = URLSession.shared.dataTask(with: request) { data, response, error in
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
	}
}
