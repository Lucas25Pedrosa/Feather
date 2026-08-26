//
//  ManuallyInstalledAppsView.swift
//  Feather
//
//  Manual installed-app registration for source-based update tracking.
//

import AltSourceKit
import CoreData
import NimbleViews
import SwiftUI

struct ManuallyInstalledAppsView: View {
	@ObservedObject private var _registry = InstallationRegistry.shared
	@State private var _isAddingApp = false
	
	private var _records: [InstalledSourceAppRecord] {
		_registry.records.sorted {
			($0.appName ?? $0.localBundleIdentifier)
				.localizedCaseInsensitiveCompare($1.appName ?? $1.localBundleIdentifier) == .orderedAscending
		}
	}
	
	var body: some View {
		List {
			if _records.isEmpty {
				Section {
					VStack(alignment: .leading, spacing: 6) {
						Text(.localized("No installed apps registered."))
							.font(.headline)
						Text(.localized("Add apps that are already on this iPhone so Feather can compare their installed versions with your sources."))
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
					.padding(.vertical, 4)
				}
			} else {
				Section {
					ForEach(_records) { record in
						NavigationLink(destination: ManualInstalledRecordEditView(record: record)) {
							VStack(alignment: .leading, spacing: 3) {
								Text(record.appName ?? record.localBundleIdentifier)
								Text("\(record.installedVersion) · \(record.localBundleIdentifier)")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
						.swipeActions(edge: .trailing, allowsFullSwipe: true) {
							Button(role: .destructive) {
								_ = _registry.remove(recordID: record.id)
							} label: {
								Label(.localized("Remove"), systemImage: "trash")
							}
						}
					}
				} header: {
					Text(.localized("Tracked Apps"))
				} footer: {
					Text(.localized("The version shown here is the version Feather considers installed for update detection."))
				}
			}
		}
		.navigationTitle(.localized("Installed Apps"))
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Button {
					_isAddingApp = true
				} label: {
					Image(systemName: "plus")
				}
				.accessibilityLabel(.localized("Add Installed App"))
			}
		}
		.sheet(isPresented: $_isAddingApp) {
			ManualSourceAppPickerView()
		}
	}
}

private struct ManualInstalledRecordEditView: View {
	@Environment(\.dismiss) private var _dismiss
	@ObservedObject private var _registry = InstallationRegistry.shared
	let record: InstalledSourceAppRecord
	@State private var _version: String
	@State private var _confirmRemove = false
	
	init(record: InstalledSourceAppRecord) {
		self.record = record
		__version = State(initialValue: record.installedVersion)
	}
	
	var body: some View {
		Form {
			Section {
				_infoRow(.localized("App"), value: record.appName ?? record.localBundleIdentifier)
				_infoRow(.localized("Bundle ID"), value: record.localBundleIdentifier)
				_infoRow(.localized("Source"), value: record.sourceRepositoryName ?? record.sourceRepositoryURL.host ?? record.sourceRepositoryURL.absoluteString)
			}
			
			Section {
				TextField(.localized("Installed Version"), text: $_version)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
				Button(.localized("Save Installed Version")) {
					if _registry.updateInstalledVersion(recordID: record.id, version: _version) {
						_dismiss()
					}
				}
				.disabled(_version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			} footer: {
				Text(.localized("Feather will only offer an update when the newest source version is greater than this version."))
			}
			
			Section {
				Button(.localized("Stop Tracking This App"), role: .destructive) {
					_confirmRemove = true
				}
			}
		}
		.navigationTitle(record.appName ?? .localized("Installed App"))
		.confirmationDialog(
			.localized("Stop tracking this app?"),
			isPresented: $_confirmRemove,
			titleVisibility: .visible
		) {
			Button(.localized("Stop Tracking"), role: .destructive) {
				if _registry.remove(recordID: record.id) {
					_dismiss()
				}
			}
			Button(.localized("Cancel"), role: .cancel) { }
		}
	}
	
	@ViewBuilder
	private func _infoRow(_ title: String, value: String) -> some View {
		HStack(alignment: .firstTextBaseline) {
			Text(title)
			Spacer()
			Text(value)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.trailing)
		}
	}
}

private struct ManualSourceAppCandidate: Identifiable {
	let sourceURL: URL
	let repository: ASRepository
	let app: ASRepository.App
	
	var id: String {
		"\(sourceURL.absoluteString)|\(app.id ?? app.uuid.uuidString)"
	}
}

private struct ManualSourceAppPickerView: View {
	@Environment(\.dismiss) private var _dismiss
	@ObservedObject private var _viewModel = SourcesViewModel.shared
	@State private var _searchText = ""
	@State private var _isLoading = true
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
	
	private var _candidates: [ManualSourceAppCandidate] {
		let search = _searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		return _sources.flatMap { source -> [ManualSourceAppCandidate] in
			guard
				let sourceURL = source.sourceURL,
				let repository = _viewModel.sources[source]
			else {
				return []
			}
			return repository.apps.compactMap { app in
				guard let bundleIdentifier = app.id, !bundleIdentifier.isEmpty else {
					return nil
				}
				if !search.isEmpty {
					let nameMatches = app.currentName.localizedCaseInsensitiveContains(search)
					let bundleMatches = bundleIdentifier.localizedCaseInsensitiveContains(search)
					guard nameMatches || bundleMatches else { return nil }
				}
				return ManualSourceAppCandidate(sourceURL: sourceURL, repository: repository, app: app)
			}
		}
		.sorted {
			$0.app.currentName.localizedCaseInsensitiveCompare($1.app.currentName) == .orderedAscending
		}
	}
	
	var body: some View {
		NBNavigationView(.localized("Add Installed App")) {
			List {
				if _isLoading {
					HStack {
						Spacer()
						ProgressView()
						Spacer()
					}
				} else if _candidates.isEmpty {
					Text(.localized("No apps were found in your sources."))
						.foregroundStyle(.secondary)
				} else {
					ForEach(_candidates) { candidate in
						NavigationLink {
							ManualInstalledVersionPickerView(candidate: candidate) {
								_dismiss()
							}
						} label: {
							HStack(spacing: 12) {
								AsyncImage(url: candidate.app.iconURL) { phase in
									switch phase {
									case .success(let image):
										image.resizable().scaledToFill()
									default:
										Image(systemName: "app.fill")
											.resizable()
											.scaledToFit()
											.padding(8)
											.foregroundStyle(.secondary)
									}
								}
								.frame(width: 40, height: 40)
								.clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
								
								VStack(alignment: .leading, spacing: 2) {
									Text(candidate.app.currentName)
									Text(candidate.repository.name ?? candidate.sourceURL.host ?? .localized("Source"))
										.font(.caption)
										.foregroundStyle(.secondary)
								}
							}
						}
					}
				}
			}
			.searchable(text: $_searchText, prompt: .localized("Search Apps"))
			.refreshable {
				await _loadSources(refresh: true)
			}
			.task {
				await _loadSources(refresh: false)
			}
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button(.localized("Cancel")) {
						_dismiss()
					}
				}
			}
		}
	}
	
	private func _loadSources(refresh: Bool) async {
		_isLoading = true
		await _viewModel.fetchSources(_sources, refresh: refresh)
		_isLoading = false
	}
}

private struct ManualVersionChoice: Identifiable {
	let version: String
	let provenance: SourceAppProvenance
	var id: String { version }
}

private struct ManualInstalledVersionPickerView: View {
	@ObservedObject private var _registry = InstallationRegistry.shared
	let candidate: ManualSourceAppCandidate
	let onSaved: () -> Void
	@State private var _customVersion = ""
	
	private var _knownVersions: [ManualVersionChoice] {
		var choices: [String: ManualVersionChoice] = [:]
		
		for version in candidate.app.versions ?? [] {
			guard let provenance = SourceAppProvenance(
				sourceURL: candidate.sourceURL,
				repository: candidate.repository,
				app: candidate.app,
				version: version
			) else {
				continue
			}
			choices[version.version] = ManualVersionChoice(version: version.version, provenance: provenance)
		}
		
		if
			let currentVersion = candidate.app.currentVersion,
			choices[currentVersion] == nil,
			let provenance = SourceAppProvenance(
				sourceURL: candidate.sourceURL,
				repository: candidate.repository,
				app: candidate.app
			)
		{
			choices[currentVersion] = ManualVersionChoice(version: currentVersion, provenance: provenance)
		}
		
		return choices.values.sorted {
			$0.version.compare($1.version, options: [.numeric, .caseInsensitive]) == .orderedDescending
		}
	}
	
	var body: some View {
		Form {
			Section {
				_infoRow(.localized("App"), value: candidate.app.currentName)
				_infoRow(.localized("Bundle ID"), value: candidate.app.id ?? .localized("Unknown"))
				_infoRow(.localized("Source"), value: candidate.repository.name ?? candidate.sourceURL.host ?? candidate.sourceURL.absoluteString)
			}
			
			if !_knownVersions.isEmpty {
				Section {
					ForEach(_knownVersions) { choice in
						Button {
							_save(version: choice.version, provenance: choice.provenance)
						} label: {
							HStack {
								Text(choice.version)
								Spacer()
								Image(systemName: "checkmark.circle")
									.foregroundStyle(Color.accentColor)
							}
						}
					}
				} header: {
					Text(.localized("Version Installed"))
				} footer: {
					Text(.localized("Choose the version that is currently installed on this iPhone."))
				}
			}
			
			Section {
				TextField(.localized("Other Version"), text: $_customVersion)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
				Button(.localized("Use This Version")) {
					_saveCustomVersion()
				}
				.disabled(_customVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			} header: {
				Text(.localized("Other Version"))
			} footer: {
				Text(.localized("Use this when the installed version is no longer listed in the source."))
			}
		}
		.navigationTitle(candidate.app.currentName)
	}
	
	@ViewBuilder
	private func _infoRow(_ title: String, value: String) -> some View {
		HStack(alignment: .firstTextBaseline) {
			Text(title)
			Spacer()
			Text(value)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.trailing)
		}
	}
	
	private func _saveCustomVersion() {
		guard let sourceAppIdentifier = candidate.app.id else { return }
		let version = _customVersion.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !version.isEmpty else { return }
		let provenance = SourceAppProvenance(
			sourceRepositoryURL: candidate.sourceURL,
			sourceRepositoryIdentifier: candidate.repository.id,
			sourceRepositoryName: candidate.repository.name,
			sourceAppIdentifier: sourceAppIdentifier,
			sourceAppName: candidate.app.currentName,
			sourceAppVersion: version,
			sourceAppVersionDate: nil,
			sourceAppDownloadURL: nil
		)
		_save(version: version, provenance: provenance)
	}
	
	private func _save(version: String, provenance: SourceAppProvenance) {
		guard let bundleIdentifier = candidate.app.id else { return }
		if _registry.recordManualInstallation(
			localBundleIdentifier: bundleIdentifier,
			installedVersion: version,
			provenance: provenance
		) {
			onSaved()
		}
	}
}
