//
//  DownloadButtonView.swift
//  Feather
//
//  Created by samsam on 7/25/25.
//

import SwiftUI
import Combine
import AltSourceKit
import NimbleViews

struct DownloadButtonView: View {
	let sourceURL: URL?
	let source: ASRepository?
	let app: ASRepository.App
	@ObservedObject private var downloadManager = DownloadManager.shared
	@ObservedObject private var quickInstall = QuickInstallManager.shared
	@ObservedObject private var updatePreferences = UpdateEnginePreferences.shared

	@State private var downloadProgress: Double = 0
	@State private var cancellable: AnyCancellable?

	private var _quickJobID: String {
		let identifier = app.id ?? app.uuid.uuidString
		let version = app.currentVersion ?? "current"
		return "source:\(identifier):\(version)"
	}

	private var _quickState: QuickInstallJobState {
		quickInstall.state(for: _quickJobID)
	}

	private var _usesQuickInstall: Bool {
		updatePreferences.usableCertificate() != nil || _quickState.phase != .idle
	}

	var body: some View {
		ZStack {
			if _usesQuickInstall {
				_quickInstallControl
			} else {
				_manualDownloadControl
			}
		}
		.onAppear(perform: setupObserver)
		.onDisappear { cancellable?.cancel() }
		.onChange(of: downloadManager.downloads.description) { _ in
			setupObserver()
		}
		.animation(.easeInOut(duration: 0.3), value: _quickState.phase)
		.animation(.easeInOut(duration: 0.3), value: downloadManager.getDownload(by: app.currentUniqueId) != nil)
	}

	@ViewBuilder
	private var _quickInstallControl: some View {
		if _quickState.isActive {
			HStack(spacing: 7) {
				ProgressView()
				Text(_quickTitle)
					.lineLimit(1)
			}
			.font(.subheadline.weight(.semibold))
			.foregroundStyle(.secondary)
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
			.background(Color(uiColor: .quaternarySystemFill))
			.clipShape(Capsule())
			.compatTransition()
		} else {
			Button {
				_startQuickInstall()
			} label: {
				Text(_quickTitle)
					.lineLimit(1)
					.font(.headline.bold())
					.foregroundStyle(_quickState.phase == .failed ? Color.orange : Color.accentColor)
					.padding(.horizontal, 18)
					.padding(.vertical, 6)
					.background(Color(uiColor: .quaternarySystemFill))
					.clipShape(Capsule())
			}
			.buttonStyle(.borderless)
			.disabled(_quickState.phase == .completed)
			.compatTransition()
		}
	}

	@ViewBuilder
	private var _manualDownloadControl: some View {
		if let currentDownload = downloadManager.getDownload(by: app.currentUniqueId) {
			ZStack {
				Circle()
					.trim(from: 0, to: downloadProgress)
					.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
					.rotationEffect(.degrees(-90))
					.frame(width: 31, height: 31)
					.animation(.smooth, value: downloadProgress)

				Image(systemName: downloadProgress >= 0.75 ? "archivebox" : "square.fill")
					.foregroundStyle(.tint)
					.font(.footnote).bold()
			}
			.onTapGesture {
				if downloadProgress <= 0.75 {
					downloadManager.cancelDownload(currentDownload)
				}
			}
			.compatTransition()
		} else {
			Button {
				_startManualDownload()
			} label: {
				Text(.localized("Get"))
					.lineLimit(0)
					.font(.headline.bold())
					.foregroundStyle(Color.accentColor)
					.padding(.horizontal, 24)
					.padding(.vertical, 6)
					.background(Color(uiColor: .quaternarySystemFill))
					.clipShape(Capsule())
			}
			.buttonStyle(.borderless)
			.compatTransition()
		}
	}

	private var _quickTitle: String {
		switch _quickState.phase {
		case .downloading: return "Baixando"
		case .signing: return "Assinando"
		case .installing: return "Instalando"
		case .completed: return "Concluído"
		case .failed: return "Tentar novamente"
		case .idle: return .localized("Install")
		}
	}

	private func _startQuickInstall() {
		guard let url = app.currentDownloadUrl else { return }
		if !quickInstall.startSourceDownload(
			from: url,
			jobID: _quickJobID,
			expectedBundleIdentifier: app.id,
			sourceProvenance: _sourceProvenance()
		) {
			_startManualDownload()
		}
	}

	private func _startManualDownload() {
		guard let url = app.currentDownloadUrl else { return }
		_ = downloadManager.startDownload(
			from: url,
			id: app.currentUniqueId,
			sourceProvenance: _sourceProvenance()
		)
	}

	private func setupObserver() {
		cancellable?.cancel()
		guard let download = downloadManager.getDownload(by: app.currentUniqueId) else {
			downloadProgress = 0
			return
		}
		downloadProgress = download.overallProgress

		let publisher = Publishers.CombineLatest(
			download.$progress,
			download.$unpackageProgress
		)

		cancellable = publisher.sink { _, _ in
			downloadProgress = download.overallProgress
		}
	}
	
	private func _sourceProvenance() -> SourceAppProvenance? {
		guard let source else { return nil }
		return SourceAppProvenance(sourceURL: sourceURL, repository: source, app: app)
	}
}
