//
//  TabbarController.swift
//  feather
//
//  Created by samara on 5/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import SwiftUI
import NukeUI

@available(iOS 18, *)
struct ExtendedTabbarView: View {
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@StateObject private var tabPreferences = TabPreferences.shared
	@StateObject private var updateManager = UpdateManager.shared
	@StateObject var viewModel = SourcesViewModel.shared
	
	@State private var _isAddingPresenting = false
	@State private var _selectedTab = "tab.sources"
	@State private var _didResolveInitialTab = false
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
		
	var body: some View {
		TabView(selection: $_selectedTab) {
			ForEach(tabPreferences.orderedVisibleTabs, id: \.self) { tab in
				Tab(tab.title, systemImage: tab.icon, value: _tabSelectionValue(tab)) {
					TabEnum.view(for: tab)
				}
				.badge(tab == .updates ? updateManager.availableUpdates.count : 0)
			}
			
			TabSection("Sources") {
				Tab(.localized("All Repositories"), systemImage: "globe.desk", value: "source.all") {
					NavigationStack {
						SourceAppsView(object: Array(_sources), viewModel: viewModel)
					}
				}
				
				ForEach(_sources, id: \.identifier) { source in
					Tab(value: _sourceSelectionValue(source)) {
						NavigationStack {
							SourceAppsView(object: [source], viewModel: viewModel)
						}
					} label: {
						_icon(source.name ?? .localized("Unknown"), iconUrl: source.iconURL)
					}
					.swipeActions {
						Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
							Storage.shared.deleteSource(for: source)
						}
					}
				}
			}
			.sectionActions {
				Button(.localized("Add Source"), systemImage: "plus") {
					_isAddingPresenting = true
				}
			}
			.defaultVisibility(.hidden, for: .tabBar)
			.hidden(horizontalSizeClass == .compact)
		}
		.tabViewStyle(.sidebarAdaptable)
		.sheet(isPresented: $_isAddingPresenting) {
			SourcesAddView()
				.presentationDetents([.medium])
		}
		.onAppear {
			_resolveInitialTabIfNeeded()
		}
		.task {
			await _checkForUpdates()
		}
		.onReceive(NotificationCenter.default.publisher(for: .featherSourcesChanged)) { _ in
			Task { await _checkForUpdates() }
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.selectTab"))) { notification in
			guard
				let rawValue = notification.object as? String,
				let tab = TabEnum(rawValue: rawValue),
				tabPreferences.isVisible(tab)
			else {
				return
			}
			_selectedTab = _tabSelectionValue(tab)
		}
		.onChange(of: tabPreferences.visibleTabs) { _ in
			guard
				_selectedTab.hasPrefix("tab."),
				let rawValue = _selectedTab.split(separator: ".").last.map(String.init),
				let selected = TabEnum(rawValue: rawValue),
				!tabPreferences.isVisible(selected)
			else {
				return
			}
			_selectedTab = _tabSelectionValue(tabPreferences.defaultTab)
		}
	}
	
	private func _resolveInitialTabIfNeeded() {
		guard !_didResolveInitialTab else { return }
		_didResolveInitialTab = true
		_selectedTab = _tabSelectionValue(tabPreferences.defaultTab)
	}

	private func _checkForUpdates() async {
		await updateManager.checkForUpdates(sources: Array(_sources))
	}
	
	private func _tabSelectionValue(_ tab: TabEnum) -> String {
		"tab.\(tab.rawValue)"
	}
	
	private func _sourceSelectionValue(_ source: AltSource) -> String {
		"source.\(source.identifier ?? source.sourceURL?.absoluteString ?? source.name ?? "unknown")"
	}
	
	@ViewBuilder
	private func _icon(_ title: String, iconUrl: URL?) -> some View {
		Label {
			Text(title)
		} icon: {
			if let iconURL = iconUrl {
				LazyImage(url: iconURL) { state in
					if let image = state.image {
						image
					} else {
						standardIcon
					}
				}
				.processors([.resize(width: 14), .circle()])
			} else {
				standardIcon
			}
		}
	}

	var standardIcon: some View {
		Image(systemName: "app.dashed")
	}
}
