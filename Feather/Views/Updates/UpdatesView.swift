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
	
	var body: some View {
		NBNavigationView(.localized("Updates")) {
			NBListAdaptable {
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
				} else if !updateManager.isChecking && _updateCount == 0 {
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
	
	let update: AppUpdate
	
	private var _downloadID: String {
		"FeatherManualDownload_Update_\(update.localUUID)"
	}
	
	private var _isDownloading: Bool {
		downloadManager.getDownload(by: _downloadID) != nil
	}
	
	private var _subtitle: String {
		let localVersion = update.localVersion ?? .localized("Unknown")
		return "\(localVersion) → \(update.remoteVersion)"
	}
	
	var body: some View {
		let isRegular = horizontalSizeClass != .compact
		
		HStack(spacing: 18) {
			UpdateAppIconView(url: update.iconURL)
			
			NBTitleWithSubtitleView(
				title: update.appName,
				subtitle: _subtitle,
				linelimit: 0
			)
			
			Button {
				_startUpdateDownload()
			} label: {
				Group {
					if _isDownloading {
						ProgressView()
							.frame(minWidth: 48)
					} else {
						Text(.localized("Update"))
							.lineLimit(1)
							.font(.headline.bold())
							.foregroundStyle(Color.accentColor)
							.padding(.horizontal, 18)
							.padding(.vertical, 6)
							.background(Color(uiColor: .quaternarySystemFill))
							.clipShape(Capsule())
					}
				}
			}
			.buttonStyle(.borderless)
			.disabled(_isDownloading)
			
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
		}
		.padding(isRegular ? 12 : 0)
		.background(
			isRegular
				? RoundedRectangle(cornerRadius: 18, style: .continuous)
					.fill(Color(uiColor: .quaternarySystemFill))
				: nil
		)
	}
	
	private func _startUpdateDownload() {
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
						.localized("Hidden Updates"),
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
