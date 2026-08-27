//
//  TabbarView.swift
//  feather
//
//  Created by samara on 23.03.2025.
//

import SwiftUI
import CoreData
import UIKit

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
		.background(_TabBarBadgePositionConfigurator().frame(width: 0, height: 0))
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
		.onReceive(NotificationCenter.default.publisher(for: .featherSourceMonitoringChanged)) { _ in
			updateManager.applyMonitoringPreferences()
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


struct _TabBarBadgePositionConfigurator: UIViewControllerRepresentable {
	func makeUIViewController(context: Context) -> Controller {
		Controller()
	}

	func updateUIViewController(_ uiViewController: Controller, context: Context) {
		uiViewController.scheduleBadgePositionUpdate()
	}

	final class Controller: UIViewController {
		override func viewDidAppear(_ animated: Bool) {
			super.viewDidAppear(animated)
			scheduleBadgePositionUpdate()
		}

		override func viewDidLayoutSubviews() {
			super.viewDidLayoutSubviews()
			scheduleBadgePositionUpdate()
		}

		func scheduleBadgePositionUpdate() {
			// SwiftUI/iOS 27 may rebuild the Liquid Glass tab-bar appearance after
			// this representable first appears. Reapply after those layout passes.
			_applyBadgePosition(after: 0)
			_applyBadgePosition(after: 0.05)
			_applyBadgePosition(after: 0.20)
		}

		private func _applyBadgePosition(after delay: TimeInterval) {
			DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
				guard
					let root = self?.view.window?.rootViewController,
					let tabBarController = Self.findTabBarController(in: root)
				else {
					return
				}

				let tabBar = tabBarController.tabBar
				let appearance = tabBar.standardAppearance
				let offset = UIOffset(horizontal: 18, vertical: -11)
				let layouts = [
					appearance.stackedLayoutAppearance,
					appearance.inlineLayoutAppearance,
					appearance.compactInlineLayoutAppearance,
				]
				for layout in layouts {
					layout.normal.badgePositionAdjustment = offset
					layout.selected.badgePositionAdjustment = offset
					layout.focused.badgePositionAdjustment = offset
					layout.disabled.badgePositionAdjustment = offset
				}
				tabBar.standardAppearance = appearance
				tabBar.scrollEdgeAppearance = appearance

				// Runtime fallback for the floating selected-tab presentation, which
				// can ignore/rewrite badgePositionAdjustment on iOS 27.
				for badgeView in Self.outermostBadgeViews(in: tabBar) {
					badgeView.transform = CGAffineTransform(translationX: 5, y: -4)
				}
			}
		}

		private static func outermostBadgeViews(in view: UIView) -> [UIView] {
			var result: [UIView] = []
			for subview in view.subviews {
				let className = NSStringFromClass(type(of: subview)).lowercased()
				if className.contains("badge") {
					// Move only the badge container, not its text/background children.
					result.append(subview)
					continue
				}
				result.append(contentsOf: outermostBadgeViews(in: subview))
			}
			return result
		}

		private static func findTabBarController(in controller: UIViewController) -> UITabBarController? {
			if let tabBarController = controller as? UITabBarController {
				return tabBarController
			}
			if let presented = controller.presentedViewController,
			   let match = findTabBarController(in: presented) {
				return match
			}
			for child in controller.children {
				if let match = findTabBarController(in: child) {
					return match
				}
			}
			return nil
		}
	}
}
