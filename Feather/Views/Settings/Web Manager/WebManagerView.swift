//
//  WebManagerView.swift
//  Feather
//

import SwiftUI
import NimbleViews
import CoreImage.CIFilterBuiltins

struct WebManagerView: View {
	@ObservedObject private var manager = WebManager.shared

	var body: some View {
		NBList("Web Manager") {
			_serverSection

			if manager.isRunning {
				_connectSection
			}

			_settingsSection

			if !manager.recentUploads.isEmpty {
				NBSection("Uploads recentes", secondary: "\(manager.recentUploads.count)") {
					ForEach(manager.recentUploads, id: \.self) { name in
						Label(name, systemImage: _icon(for: name))
							.lineLimit(1)
					}

					Button(role: .destructive) {
						manager.clearRecent()
					} label: {
						Label("Limpar", systemImage: "trash")
					}
				}
			}
		}
		.animation(.smooth, value: manager.isRunning)
		.animation(.smooth, value: manager.recentUploads)
	}

	private var _serverSection: some View {
		NBSection("Servidor") {
			Toggle(isOn: Binding(
				get: { manager.isRunning },
				set: { _ in manager.toggle() }
			)) {
				Label("Ativar servidor", systemImage: "externaldrive.badge.wifi")
			}

			if let error = manager.lastError {
				Label(error, systemImage: "exclamationmark.triangle")
					.foregroundStyle(.red)
					.font(.footnote)
			}

			if manager.isRunning && !manager.authActive {
				Label(
					"Sem senha: qualquer dispositivo na mesma rede pode acessar o Web Manager.",
					systemImage: "lock.open"
				)
				.foregroundStyle(.orange)
				.font(.footnote)
			}
		} footer: {
			Text("Envie IPAs pelo navegador ou monte a pasta pelo WebDAV. Arquivos .ipa e .tipa são importados automaticamente para a Biblioteca.")
		}
	}

	private var _connectSection: some View {
		NBSection("Conectar") {
			_urlRow("Navegador", value: manager.httpURL, systemImage: "safari")
			_urlRow("WebDAV", value: manager.webdavURL, systemImage: "externaldrive.connected.to.line.below")

			HStack {
				Spacer()
				if let qr = QRCode.generate(from: manager.httpURL) {
					Image(uiImage: qr)
						.interpolation(.none)
						.resizable()
						.frame(width: 160, height: 160)
						.padding(8)
						.background(Color.white)
						.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
				}
				Spacer()
			}
			.listRowBackground(EmptyView())
		} footer: {
			Text("Toque em um endereço para copiá-lo. No macOS, use Finder → Ir → Conectar ao Servidor para o WebDAV.")
		}
	}

	private func _urlRow(
		_ title: String,
		value: String,
		systemImage: String
	) -> some View {
		Button {
			UIPasteboard.general.string = value
		} label: {
			HStack {
				Label(title, systemImage: systemImage)
				Spacer()
				Text(value)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
				Image(systemName: "doc.on.doc")
					.font(.footnote)
			}
		}
	}

	private var _settingsSection: some View {
		Group {
			NBSection("Acesso") {
				HStack {
					Label("Porta", systemImage: "number")
					Spacer()
					TextField("8080", text: Binding(
						get: { String(manager.port) },
						set: {
							let value = Int($0.filter(\.isNumber)) ?? manager.port
							manager.port = min(65535, max(1024, value))
						}
					))
					.keyboardType(.numberPad)
					.multilineTextAlignment(.trailing)
					.frame(width: 80)
					.onSubmit { manager.restartIfRunning() }
				}

				Toggle(isOn: Binding(
					get: { manager.requireAuth },
					set: {
						manager.requireAuth = $0
						manager.restartIfRunning()
					}
				)) {
					Label("Exigir senha", systemImage: "lock")
				}

				if manager.requireAuth {
					HStack {
						Label("Usuário", systemImage: "person")
						Spacer()
						TextField("Usuário", text: Binding(
							get: { manager.username },
							set: { manager.username = $0 }
						))
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.multilineTextAlignment(.trailing)
						.onSubmit { manager.restartIfRunning() }
					}

					HStack {
						Label("Senha", systemImage: "key")
						Spacer()
						SecureField("Senha", text: Binding(
							get: { manager.password },
							set: { manager.password = $0 }
						))
						.multilineTextAlignment(.trailing)
						.onSubmit { manager.restartIfRunning() }
					}
				}
			} footer: {
				Text("O tráfego HTTP/WebDAV não é criptografado. Use o recurso apenas em uma rede local confiável.")
			}

			NBSection("Segundo plano") {
				Toggle(isOn: Binding(
					get: { manager.keepAlive },
					set: { manager.keepAlive = $0 }
				)) {
					Label("Manter servidor ativo", systemImage: "bolt.badge.clock")
				}
			} footer: {
				Text("Mantém o Web Manager acessível enquanto o Feather está em segundo plano. Desative quando terminar para reduzir o consumo de bateria.")
			}
		}
	}

	private func _icon(for name: String) -> String {
		let value = name.lowercased()
		if value.hasSuffix(".ipa") || value.hasSuffix(".tipa") {
			return "app.badge"
		}
		return "doc"
	}
}

enum QRCode {
	static func generate(from string: String) -> UIImage? {
		let context = CIContext()
		let filter = CIFilter.qrCodeGenerator()
		filter.message = Data(string.utf8)
		filter.correctionLevel = "M"

		guard let output = filter.outputImage?.transformed(
			by: CGAffineTransform(scaleX: 10, y: 10)
		) else {
			return nil
		}

		guard let image = context.createCGImage(
			output,
			from: output.extent
		) else {
			return nil
		}

		return UIImage(cgImage: image)
	}
}
