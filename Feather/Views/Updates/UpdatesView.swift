//
//  UpdatesView.swift
//  Feather
//
//  Source-based update flow.
//

import SwiftUI
import CoreData
import NimbleViews

private struct UpdateSigningIdentity {
	let sourceRepositoryURL: URL
	let sourceAppIdentifier: String
	let sourceAppVersion: String?
}

struct UpdatesView: View {
	@StateObject private var updateManager = UpdateManager.shared
	@StateObject private var updateEngine = UpdateEngineManager.shared
	@StateObject private var updatePreferences = UpdateEnginePreferences.shared
	@State private var _selectedSigningAppPresenting: AnyApp?
	@State private var _updateSigningIdentity: UpdateSigningIdentity?
	@State private var _signedUUIDsBeforeSigning: Set<String> = []
	@State private var _isHiddenUpdatesPresenting = false

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>

	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
		animation: .snappy
	) private var _importedApps: FetchedResults<Imported>

	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var _signedApps: FetchedResults<Signed>

	private var _updateEntries: [AppUpdate] {
		updateManager.availableUpdates
	}

	private var _updateCount: Int {
		_updateEntries.count
	}

	private var _canShowBatchControl: Bool {
		(_updateCount > 1 || updateEngine.isBatchRunning)
			&& (updatePreferences.usableCertificate() != nil || updateEngine.isBatchRunning)
	}

	var body: some View {
		NBNavigationView(.localized("Updates")) {
			NBListAdaptable {
				if updateManager.lastCheckFailedSourceCount > 0 {
					NBSection("") {
						Label {
							Text(
								verbatim: .localized(
									"%d source(s) could not be checked. Existing update information was preserved.",
									arguments: updateManager.lastCheckFailedSourceCount
								)
							)
							.font(.footnote)
							.foregroundStyle(.secondary)
						} icon: {
							Image(systemName: "exclamationmark.triangle")
								.foregroundStyle(.orange)
						}
					}
				}

				if _canShowBatchControl {
					NBSection("") {
						_batchControl
					}
				}

				if updateEngine.hasFinishedBatchSummary {
					NBSection("") {
						Label {
							VStack(alignment: .leading, spacing: 3) {
								Text("Atualização em massa concluída")
									.font(.headline)
								Text(_batchSummaryText)
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						} icon: {
							Image(systemName: updateEngine.batchFailed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
								.foregroundStyle(updateEngine.batchFailed == 0 ? Color.green : Color.orange)
						}
					}
				}

				if _updateCount > 0 {
					NBSection(
						.localized("Available Updates"),
						secondary: _updateCount.description
					) {
						ForEach(_updateEntries) { update in
							UpdateCellView(update: update)
						}
					}
				}
			}
			.refreshable {
				await _checkForUpdates()
			}
			.overlay {
				if updateManager.isChecking && _updateCount == 0 {
					ProgressView()
				} else if !updateManager.isChecking
					&& _updateCount == 0
					&& updateManager.lastCheckFailedSourceCount == 0
					&& !updateEngine.hasFinishedBatchSummary {
					if #available(iOS 17, *) {
						ContentUnavailableView {
							Label(.localized("No Updates Available"), systemImage: "checkmark.circle.fill")
						} description: {
							Text(.localized("Apps installed from your sources are up to date."))
						}
					} else {
						Text(.localized("No Updates Available"))
							.foregroundColor(.secondary)
					}
				}
			}
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Menu {
						Button(.localized("Hidden Updates"), systemImage: "eye.slash") {
							_isHiddenUpdatesPresenting = true
						}
					} label: {
						Image(systemName: "ellipsis.circle")
					}
					.accessibilityLabel(.localized("Update Options"))
				}
			}
			.sheet(isPresented: $_isHiddenUpdatesPresenting) {
				HiddenUpdatesView {
					Task {
						await _checkForUpdates()
					}
				}
			}
			.fullScreenCover(item: $_selectedSigningAppPresenting) { app in
				SigningView(app: app.base)
					.onDisappear {
						_handleUpdateSigningDismissal()
					}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.updateImported"))) { notification in
				guard let uuid = notification.userInfo?["uuid"] as? String else { return }
				_openSigningView(for: uuid)
			}
			.task {
				await _checkForUpdates()
			}
		}
	}

	@ViewBuilder
	private var _batchControl: some View {
		if updateEngine.isBatchRunning {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Label("Atualizando tudo", systemImage: "arrow.triangle.2.circlepath")
						.font(.headline)
					Spacer()
					Text("\(updateEngine.batchProcessed)/\(updateEngine.batchTotal)")
						.font(.subheadline.monospacedDigit())
						.foregroundStyle(.secondary)
				}

				ProgressView(
					value: Double(updateEngine.batchProcessed),
					total: Double(max(1, updateEngine.batchTotal))
				)

				if let current = updateEngine.batchCurrentAppName {
					Text("Processando: \(current)")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
		} else {
			Button {
				_ = updateEngine.startAll(_updateEntries)
			} label: {
				HStack {
					Label("Atualizar Tudo", systemImage: "arrow.triangle.2.circlepath")
					Spacer()
					Text(_updateCount.description)
						.foregroundStyle(.secondary)
				}
			}
			.buttonStyle(.borderless)
		}
	}

	private var _batchSummaryText: String {
		if updateEngine.batchFailed == 0 {
			return "\(updateEngine.batchSucceeded) app(s) atualizado(s) com sucesso."
		}
		return "\(updateEngine.batchSucceeded) concluído(s) • \(updateEngine.batchFailed) falhou/falharam."
	}

	private func _checkForUpdates() async {
		await updateManager.checkForUpdates(
			sources: Array(_sources)
		)
	}

	private func _openSigningView(for uuid: String) {
		Task { @MainActor in
			for _ in 0..<8 {
				if let imported = _importedApps.first(where: { $0.uuid == uuid }) {
					if
						let metadata = Storage.shared.sourceMetadata(for: imported),
						let sourceRepositoryURL = metadata.sourceRepositoryURL,
						let sourceAppIdentifier = metadata.sourceAppIdentifier
					{
						_updateSigningIdentity = UpdateSigningIdentity(
							sourceRepositoryURL: sourceRepositoryURL,
							sourceAppIdentifier: sourceAppIdentifier,
							sourceAppVersion: metadata.sourceAppVersion
						)
					}

					_signedUUIDsBeforeSigning = Set(_signedApps.compactMap { $0.uuid })
					_selectedSigningAppPresenting = AnyApp(base: imported)
					return
				}
				try? await Task.sleep(nanoseconds: 100_000_000)
			}
		}
	}

	private func _handleUpdateSigningDismissal() {
		guard let identity = _updateSigningIdentity else {
			_resetUpdateSigningState()
			return
		}

		let previousSignedUUIDs = _signedUUIDsBeforeSigning
		Task { @MainActor in
			for _ in 0..<8 {
				let didSignUpdate = _signedApps.contains { signed in
					guard
						let uuid = signed.uuid,
						!previousSignedUUIDs.contains(uuid),
						let metadata = Storage.shared.sourceMetadata(for: signed),
						metadata.sourceRepositoryURL == identity.sourceRepositoryURL,
						metadata.sourceAppIdentifier == identity.sourceAppIdentifier
					else {
						return false
					}

					if let expectedVersion = identity.sourceAppVersion {
						return metadata.sourceAppVersion == expectedVersion
					}
					return true
				}

				if didSignUpdate {
					NotificationCenter.default.post(
						name: Notification.Name("Feather.selectTab"),
						object: TabEnum.library.rawValue
					)
					_resetUpdateSigningState()
					return
				}

				try? await Task.sleep(nanoseconds: 100_000_000)
			}

			_resetUpdateSigningState()
		}
	}

	private func _resetUpdateSigningState() {
		_updateSigningIdentity = nil
		_signedUUIDsBeforeSigning.removeAll()
	}
}

private struct UpdateCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@ObservedObject private var downloadManager = DownloadManager.shared
	@ObservedObject private var updateManager = UpdateManager.shared
	@ObservedObject private var updateEngine = UpdateEngineManager.shared
	@State private var _isChangelogExpanded = false

	let update: AppUpdate

	private var _downloadID: String {
		"FeatherManualDownload_Update_\(update.localUUID)"
	}

	private var _isManualDownloading: Bool {
		downloadManager.getDownload(by: _downloadID) != nil
	}

	private var _engineState: UpdateEngineJobState {
		updateEngine.state(for: update)
	}

	private var _isBusy: Bool {
		_isManualDownloading || _engineState.isActive || updateEngine.isBatchRunning
	}

	private var _subtitle: String {
		if update.isPackageOnlyUpdate {
			if
				let localLabel = update.localPackageLabel,
				let remoteLabel = update.remotePackageLabel,
				localLabel != remoteLabel
			{
				return "\(localLabel) → \(remoteLabel)"
			}
			if let remoteLabel = update.remotePackageLabel {
				if
					let localRevision = update.localPackageRevision,
					let remoteRevision = update.remotePackageRevision,
					localRevision.compare(remoteRevision, options: [.caseInsensitive]) != .orderedSame
				{
					return "\(remoteLabel) • Nova revisão disponível"
				}
				return remoteLabel
			}
			if
				let localRevision = update.localPackageRevision,
				let remoteRevision = update.remotePackageRevision
			{
				return "pkg \(localRevision) → \(remoteRevision)"
			}
			if let remoteRevision = update.remotePackageRevision {
				let release = _releaseText(
					version: update.remoteVersion,
					build: update.remoteBuildVersion
				)
				return "\(release) • pkg \(remoteRevision)"
			}
		}

		let local = _releaseText(
			version: update.localVersion ?? .localized("Unknown"),
			build: update.localBuildVersion
		)
		let remote = _releaseText(
			version: update.remoteVersion,
			build: update.remoteBuildVersion
		)
		return "\(local) → \(remote)"
	}

	private var _changelog: String? {
		guard let value = update.changelog?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
			return nil
		}
		return value
	}

	private var _engineTitle: String {
		switch _engineState.phase {
		case .downloading: return "Baixando"
		case .signing: return "Assinando"
		case .installing: return "Instalando"
		case .completed: return "Concluído"
		case .failed: return "Tentar novamente"
		case .idle: return .localized("Update")
		}
	}

	var body: some View {
		let isRegular = horizontalSizeClass != .compact

		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .top, spacing: 18) {
				UpdateAppIconView(url: update.iconURL)

				VStack(alignment: .leading, spacing: 8) {
					HStack(spacing: 8) {
						Text(update.appName)
							.font(.headline)
							.lineLimit(1)
							.layoutPriority(1)

						Spacer(minLength: 8)

						Button {
							_startUpdate()
						} label: {
							Group {
								if _isManualDownloading {
									ProgressView()
										.frame(minWidth: 48)
								} else if _engineState.isActive {
									HStack(spacing: 7) {
										ProgressView()
										Text(_engineTitle)
											.lineLimit(1)
									}
									.font(.subheadline.weight(.semibold))
									.padding(.horizontal, 12)
									.padding(.vertical, 6)
									.background(Color(uiColor: .quaternarySystemFill))
									.clipShape(Capsule())
								} else {
									Text(_engineTitle)
										.lineLimit(1)
										.font(.headline.bold())
										.foregroundStyle(_engineState.phase == .failed ? Color.orange : Color.accentColor)
										.padding(.horizontal, 18)
										.padding(.vertical, 6)
										.background(Color(uiColor: .quaternarySystemFill))
										.clipShape(Capsule())
								}
							}
						}
						.buttonStyle(.borderless)
						.disabled(_isBusy || _engineState.phase == .completed)

						Menu {
							Button(.localized("Hide This Update"), systemImage: "eye.slash") {
								updateManager.hideCurrentUpdate(update)
							}
							Button(.localized("Hide Updates for This App"), systemImage: "bell.slash") {
								updateManager.hideUpdatesForApp(update)
							}
						} label: {
							Image(systemName: "ellipsis")
								.frame(width: 24, height: 32)
						}
						.buttonStyle(.borderless)
						.disabled(_engineState.isActive || updateEngine.isBatchRunning)
					}

					Text(_subtitle)
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.lineLimit(2)
						.fixedSize(horizontal: false, vertical: true)

					if _engineState.phase != .idle {
						_engineStatusView
					}
				}
			}

			if let changelog = _changelog {
				Text(changelog)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(_isChangelogExpanded ? nil : 3)
					.fixedSize(horizontal: false, vertical: true)
					.padding(.leading, 75)
					.contentShape(Rectangle())
					.onTapGesture {
						withAnimation(.easeInOut(duration: 0.2)) {
							_isChangelogExpanded.toggle()
						}
					}
			}
		}
		.padding(isRegular ? 12 : 0)
		.background(
			isRegular
				? RoundedRectangle(cornerRadius: 18, style: .continuous)
					.fill(Color(uiColor: .quaternarySystemFill))
				: nil
		)
	}

	@ViewBuilder
	private var _engineStatusView: some View {
		switch _engineState.phase {
		case .downloading:
			VStack(alignment: .leading, spacing: 4) {
				ProgressView(value: _engineState.progress)
				Text("Baixando • \(Int(_engineState.progress * 100))%")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		case .signing:
			Label("Assinando", systemImage: "signature")
				.font(.caption)
				.foregroundStyle(.secondary)
		case .installing:
			VStack(alignment: .leading, spacing: 4) {
				if _engineState.progress > 0 {
					ProgressView(value: _engineState.progress)
				}
				Label("Instalando", systemImage: "arrow.down.app")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		case .completed:
			Label("Atualização concluída", systemImage: "checkmark.circle.fill")
				.font(.caption)
				.foregroundStyle(.green)
		case .failed:
			Label(_engineState.detail ?? "A atualização falhou.", systemImage: "exclamationmark.triangle.fill")
				.font(.caption)
				.foregroundStyle(.orange)
				.fixedSize(horizontal: false, vertical: true)
		case .idle:
			EmptyView()
		}
	}

	private func _releaseText(version: String, build: String?) -> String {
		guard let build, !build.isEmpty else { return version }
		return "\(version) (\(build))"
	}

	private func _startUpdate() {
		guard !updateEngine.isBatchRunning else { return }

		if updateEngine.start(update) {
			return
		}

		_ = downloadManager.startDownload(
			from: update.downloadURL,
			id: _downloadID,
			sourceProvenance: update.sourceProvenance
		)
	}
}

private struct HiddenUpdatesView: View {
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var registry = InstallationRegistry.shared
	@ObservedObject private var updateManager = UpdateManager.shared

	let onChanged: () -> Void

	private var _records: [InstalledSourceAppRecord] {
		registry.hiddenRecords
	}

	var body: some View {
		NBNavigationView(.localized("Hidden Updates")) {
			NBListAdaptable {
				if !_records.isEmpty {
					NBSection(
						"",
						secondary: _records.count.description
					) {
						ForEach(_records) { record in
							HStack(spacing: 12) {
								VStack(alignment: .leading, spacing: 3) {
									Text(record.appName ?? record.localBundleIdentifier)
										.font(.body)

									Text(_subtitle(for: record))
										.font(.caption)
										.foregroundStyle(.secondary)
								}

								Spacer()

								Button(.localized("Show Updates")) {
									updateManager.showUpdatesForApp(recordID: record.id)
									onChanged()
								}
								.buttonStyle(.borderless)
							}
						}
					}
				}
			}
			.overlay {
				if _records.isEmpty {
					if #available(iOS 17, *) {
						ContentUnavailableView {
							Label(.localized("No Hidden Updates"), systemImage: "eye")
						}
					} else {
						Text(.localized("No Hidden Updates"))
							.foregroundStyle(.secondary)
					}
				}
			}
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button(.localized("Done")) {
						dismiss()
					}
				}
			}
		}
	}

	private func _subtitle(for record: InstalledSourceAppRecord) -> String {
		if record.updatesDisabled == true {
			return .localized("All updates hidden")
		}
		if let version = record.ignoredRemoteVersion {
			return .localized("Version %@ hidden", arguments: version)
		}
		return .localized("Updates hidden")
	}
}

private struct UpdateAppIconView: View {
	let url: URL?

	var body: some View {
		AsyncImage(url: url) { phase in
			switch phase {
			case .success(let image):
				image
					.resizable()
					.scaledToFill()
			default:
				Image(systemName: "app.fill")
					.resizable()
					.scaledToFit()
					.padding(12)
					.foregroundStyle(.secondary)
			}
		}
		.frame(width: 57, height: 57)
		.background(Color(uiColor: .tertiarySystemFill))
		.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
	}
}
