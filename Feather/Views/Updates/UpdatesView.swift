//
//  UpdatesView.swift
//  Feather
//
//  Source-based update flow.
//

import SwiftUI
import CoreData
import NimbleViews

struct UpdatesView: View {
	@StateObject private var updateManager = UpdateManager.shared
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
	
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
					Button {
						Task {
							await _checkForUpdates()
						}
					} label: {
						if updateManager.isChecking {
							ProgressView()
						} else {
							Image(systemName: "arrow.triangle.2.circlepath")
						}
					}
					.disabled(updateManager.isChecking)
					.accessibilityLabel(.localized("Check for Updates"))
				}
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
}

private struct UpdateCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@ObservedObject private var downloadManager = DownloadManager.shared
	
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
		}
		.padding(isRegular ? 12 : 0)
		.background(
			isRegular
				? RoundedRectangle(cornerRadius: 18, style: .continuous)
					.fill(Color(.quaternarySystemFill))
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
