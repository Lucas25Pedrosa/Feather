//
//  TabbarView.swift
//  feather
//
//  Created by samara on 23.03.2025.
//

import SwiftUI
import CoreData

struct TabbarView: View {
	@StateObject private var tabPreferences = TabPreferences.shared
	@StateObject private var updateManager = UpdateManager.shared
	@State private var selectedTab: TabEnum = .sources
	@State private var _didResolveInitialTab = false

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>

	var body: some View {
		TabView(selection: $selectedTab) {
			ForEach(tabPreferences.orderedVisibleTabs, id: \.self) { tab in
				TabEnum.view(for: tab)
					.tabItem {
						Label(tab.title, systemImage: tab.icon)
					}
					.badge(tab == .updates ? updateManager.availableUpdates.count : 0)
					.tag(tab)
			}
		}
		.onAppear {
			guard !_didResolveInitialTab else { return }
			_didResolveInitialTab = true
			selectedTab = tabPreferences.defaultTab
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
			selectedTab = tab
		}
		.onChange(of: tabPreferences.visibleTabs) { _ in
			if !tabPreferences.isVisible(selectedTab) {
				selectedTab = tabPreferences.defaultTab
			}
		}
	}

	private func _checkForUpdates() async {
		await updateManager.checkForUpdates(sources: Array(_sources))
	}
}
