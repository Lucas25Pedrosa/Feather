//
//  SourceMonitoringPreferences.swift
//  Feather
//
//  Beta 3 source-app monitoring preferences.
//

import Combine
import Foundation

extension Notification.Name {
	static let featherSourceMonitoringChanged = Notification.Name("Feather.sourceMonitoringChanged")
}

@MainActor
final class SourceMonitoringPreferences: ObservableObject {
	static let shared = SourceMonitoringPreferences()
	
	private static let _hiddenBundleIdentifiersKey = "Feather.sourceMonitoring.hiddenBundleIdentifiers"
	
	@Published private(set) var hiddenBundleIdentifiers: Set<String>
	
	private init() {
		let stored = UserDefaults.standard.stringArray(forKey: Self._hiddenBundleIdentifiersKey) ?? []
		hiddenBundleIdentifiers = Set(stored.map(Self._normalizedBundleIdentifier).filter { !$0.isEmpty })
	}
	
	func isMonitored(_ bundleIdentifier: String) -> Bool {
		let normalized = Self._normalizedBundleIdentifier(bundleIdentifier)
		guard !normalized.isEmpty else { return true }
		return !hiddenBundleIdentifiers.contains(normalized)
	}
	
	func setMonitored(_ monitored: Bool, bundleIdentifier: String) {
		let normalized = Self._normalizedBundleIdentifier(bundleIdentifier)
		guard !normalized.isEmpty else { return }
		
		let changed: Bool
		if monitored {
			changed = hiddenBundleIdentifiers.remove(normalized) != nil
		} else {
			changed = hiddenBundleIdentifiers.insert(normalized).inserted
		}
		guard changed else { return }
		_persistAndNotify()
	}
	
	func restoreHiddenBundleIdentifiers(_ values: [String]) {
		let restored = Set(values.map(Self._normalizedBundleIdentifier).filter { !$0.isEmpty })
		guard restored != hiddenBundleIdentifiers else { return }
		hiddenBundleIdentifiers = restored
		_persistAndNotify()
	}
	
	var backupHiddenBundleIdentifiers: [String] {
		hiddenBundleIdentifiers.sorted()
	}
	
	private func _persistAndNotify() {
		UserDefaults.standard.set(backupHiddenBundleIdentifiers, forKey: Self._hiddenBundleIdentifiersKey)
		NotificationCenter.default.post(name: .featherSourceMonitoringChanged, object: nil)
	}
	
	private static func _normalizedBundleIdentifier(_ value: String) -> String {
		value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}
}
