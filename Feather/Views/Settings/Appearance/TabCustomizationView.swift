//
//  TabCustomizationView.swift
//  Feather
//
//  Feather 3.1 Beta 1
//

import NimbleViews
import SwiftUI

struct TabCustomizationView: View {
	@StateObject private var preferences = TabPreferences.shared

	var body: some View {
		NBNavigationView(.localized("Tabs")) {
			List {
				Section {
					ForEach(preferences.order, id: \.self) { tab in
						Toggle(
							isOn: Binding(
								get: { preferences.isVisible(tab) },
								set: { preferences.setVisible($0, for: tab) }
							)
						) {
							Label(tab.title, systemImage: tab.icon)
						}
						.disabled(tab == .settings)
					}
					.onMove(perform: preferences.move)
				} header: {
					Text(.localized("Tabs"))
				} footer: {
					Text(.localized("Settings is always available. Drag tabs to change their order."))
				}

				Section {
					Picker(
						.localized("Default Launch Tab"),
						selection: Binding(
							get: { preferences.defaultTab },
							set: { preferences.setDefaultTab($0) }
						)
					) {
						ForEach(preferences.orderedVisibleTabs, id: \.self) { tab in
							Label(tab.title, systemImage: tab.icon)
								.tag(tab)
						}
					}
				} header: {
					Text(.localized("Launch"))
				}

				Section {
					Button(.localized("Reset"), role: .destructive) {
						preferences.reset()
					}
				}
			}
			.toolbar {
				EditButton()
			}
		}
	}
}
