//
//  TabbarView.swift
//  feather
//
//  Created by samara on 23.03.2025.
//

import SwiftUI

struct TabbarView: View {
	@State private var selectedTab: TabEnum = .sources

	var body: some View {
		TabView(selection: $selectedTab) {
			ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
				TabEnum.view(for: tab)
					.tabItem {
						Label(tab.title, systemImage: tab.icon)
					}
					.tag(tab)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.selectTab"))) { notification in
			guard
				let rawValue = notification.object as? String,
				let tab = TabEnum(rawValue: rawValue)
			else {
				return
			}
			selectedTab = tab
		}
	}
}
