
//
//  ServerView.swift
//  Feather
//
//  Created by samara on 6.05.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct ServerView: View {
	@AppStorage("Feather.ipFix") private var _ipFix: Bool = false
	@AppStorage("Feather.serverMethod") private var _serverMethod: Int = 0
	
	@State private var _password: String = ""
	@State private var _isAuthenticating: Bool = false
	@State private var _isAuthenticated: Bool = FileManager.default.hasFullyLocalTLS
	
	private let _serverMethods: [String] = [
		.localized("Fully Local"),
		.localized("Semi Local")
	]
	
	// MARK: Body
	var body: some View {
		Group {
			Section {
				Picker(.localized("Server Type"), systemImage: "server.rack", selection: $_serverMethod) {
					ForEach(_serverMethods.indices, id: \.description) { index in
						Text(_serverMethods[index]).tag(index)
					}
				}
				
				Toggle(
					.localized("Only use localhost address"),
					systemImage: "lifepreserver",
					isOn: $_ipFix
				)
				.disabled(_serverMethod != 1)
			}
			
			if _serverMethod == 0 {
				Section {
					HStack {
						Text(.localized("Authentication Status"))
						
						Spacer()
						
						Text(
							_isAuthenticated
								? .localized("Authenticated")
								: .localized("Not Authenticated")
						)
						.foregroundColor(_isAuthenticated ? .green : .red)
					}
					
					if !_isAuthenticated {
						SecureField(
							.localized("Enter Password"),
							text: $_password
						)
						.textContentType(.password)
						
						Button(
							.localized("Authenticate"),
							systemImage: "lock.open"
						) {
							_authenticate()
						}
						.disabled(_password.isEmpty || _isAuthenticating)
					}
				}
			}
		}
		.onAppear {
			_refreshAuthenticationState()
		}
	}
}

// MARK: - Extension: Authentication
extension ServerView {
	private func _refreshAuthenticationState() {
		_isAuthenticated = FileManager.default.hasFullyLocalTLS
	}
	
	private func _authenticate() {
		guard !_password.isEmpty else {
			return
		}
		
		_isAuthenticating = true
		let password = _password
		
		FR.authenticateFullyLocal(password: password) { result in
			DispatchQueue.main.async {
				_isAuthenticating = false
				
				switch result {
				case .success:
					_password = ""
					_refreshAuthenticationState()
					
					UIAlertController.showAlertWithOk(
						title: .localized("Authentication"),
						message: .localized("Authentication successful.")
					)
					
				case .failure(let error):
					UIAlertController.showAlertWithOk(
						title: .localized("Authentication"),
						message: error.localizedDescription
					)
				}
			}
		}
	}
}
