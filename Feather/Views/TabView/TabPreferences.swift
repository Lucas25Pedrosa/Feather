//
//  TabPreferences.swift
//  Feather
//
//  Feather 3.1 Beta 1
//

import SwiftUI

@MainActor
final class TabPreferences: ObservableObject {
	static let shared = TabPreferences()

	private static let _orderKey = "Feather.tabOrder"
	private static let _visibleKey = "Feather.visibleTabs"
	private static let _defaultKey = "Feather.defaultLaunchTab"

	@Published private(set) var order: [TabEnum]
	@Published private(set) var visibleTabs: Set<TabEnum>
	@Published private(set) var defaultTab: TabEnum

	private init() {
		let defaults = UserDefaults.standard
		let storedOrder = (defaults.array(forKey: Self._orderKey) as? [String] ?? [])
			.compactMap(TabEnum.init(rawValue:))
		let storedVisible = (defaults.array(forKey: Self._visibleKey) as? [String] ?? [])
			.compactMap(TabEnum.init(rawValue:))

		var resolvedOrder = storedOrder
		for tab in TabEnum.allMainTabs where !resolvedOrder.contains(tab) {
			resolvedOrder.append(tab)
		}
		resolvedOrder = resolvedOrder.filter { TabEnum.allMainTabs.contains($0) }

		let resolvedVisible: Set<TabEnum>
		if storedVisible.isEmpty {
			resolvedVisible = Set(TabEnum.defaultTabs)
		} else {
			resolvedVisible = Set(storedVisible).intersection(Set(TabEnum.allMainTabs))
		}

		order = resolvedOrder
		visibleTabs = resolvedVisible.union([.settings])

		let storedDefault = defaults.string(forKey: Self._defaultKey)
			.flatMap(TabEnum.init(rawValue:))
		if let storedDefault, visibleTabs.contains(storedDefault) {
			defaultTab = storedDefault
		} else if visibleTabs.contains(.sources) {
			defaultTab = .sources
		} else {
			defaultTab = .settings
		}

		_persist()
	}

	var orderedVisibleTabs: [TabEnum] {
		let tabs = order.filter { visibleTabs.contains($0) }
		return tabs.isEmpty ? [.settings] : tabs
	}

	func isVisible(_ tab: TabEnum) -> Bool {
		tab == .settings || visibleTabs.contains(tab)
	}

	func setVisible(_ visible: Bool, for tab: TabEnum) {
		guard tab != .settings else { return }
		if visible {
			visibleTabs.insert(tab)
		} else {
			visibleTabs.remove(tab)
			if defaultTab == tab {
				defaultTab = orderedVisibleTabs.first ?? .settings
			}
		}
		visibleTabs.insert(.settings)
		_persist()
		objectWillChange.send()
	}

	func move(from source: IndexSet, to destination: Int) {
		order.move(fromOffsets: source, toOffset: destination)
		_persist()
	}

	func setDefaultTab(_ tab: TabEnum) {
		guard isVisible(tab) else { return }
		defaultTab = tab
		_persist()
	}

	func reset() {
		order = TabEnum.allMainTabs
		visibleTabs = Set(TabEnum.defaultTabs).union([.settings])
		defaultTab = .sources
		_persist()
	}

	private func _persist() {
		let defaults = UserDefaults.standard
		defaults.set(order.map(\.rawValue), forKey: Self._orderKey)
		defaults.set(visibleTabs.map(\.rawValue).sorted(), forKey: Self._visibleKey)
		defaults.set(defaultTab.rawValue, forKey: Self._defaultKey)
	}
}
