//
//  UpdatesView.swift
//  Feather
//
//  Created for the IPA Library update flow.
//

import SwiftUI
import NimbleViews

struct UpdatesView: View {
	var body: some View {
		NBNavigationView(.localized("Updates")) {
			List {
				Section(.localized("Available Updates")) {
					Text(.localized("No Updates Available"))
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			}
		}
	}
}
