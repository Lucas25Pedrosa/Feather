from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    if new in text:
        return
    if old not in text:
        raise SystemExit(f"ERRO: ponto de alteração não encontrado em {path}: {old[:80]!r}")
    write(path, text.replace(old, new, 1))


monitoring_manager = r'''//
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
'''
write("Feather/Backend/Observable/SourceMonitoringPreferences.swift", monitoring_manager)

# UpdateManager: publish a deduplicated source-app catalog and filter hidden apps.
replace_once(
    "Feather/Backend/Observable/UpdateManager.swift",
    "@MainActor\nfinal class UpdateManager: ObservableObject {",
    '''struct MonitoredSourceApp: Identifiable, Equatable {\n\tlet bundleIdentifier: String\n\tlet name: String\n\tlet iconURL: URL?\n\t\n\tvar id: String { bundleIdentifier.lowercased() }\n}\n\n@MainActor\nfinal class UpdateManager: ObservableObject {''',
)

replace_once(
    "Feather/Backend/Observable/UpdateManager.swift",
    "\t@Published private(set) var lastCheckFailedSourceCount = 0\n",
    "\t@Published private(set) var lastCheckFailedSourceCount = 0\n\t@Published private(set) var sourceApps: [MonitoredSourceApp] = []\n",
)

replace_once(
    "Feather/Backend/Observable/UpdateManager.swift",
    '''\t\tif !sources.isEmpty && fetchResult.repositories.isEmpty && !fetchResult.failedSourceURLs.isEmpty {\n\t\t\treturn\n\t\t}\n\n\t\tlet freshUpdates = _findUpdates(\n\t\t\trepositories: fetchResult.repositories,\n\t\t\tinstalledApps: InstallationRegistry.shared.records\n\t\t)''',
    '''\t\tif !sources.isEmpty && fetchResult.repositories.isEmpty && !fetchResult.failedSourceURLs.isEmpty {\n\t\t\treturn\n\t\t}\n\n\t\tlet discoveredSourceApps = _sourceApps(from: fetchResult.repositories)\n\t\tif fetchResult.failedSourceURLs.isEmpty || sourceApps.isEmpty {\n\t\t\tsourceApps = discoveredSourceApps\n\t\t}\n\n\t\tlet monitoredRecords = InstallationRegistry.shared.records.filter {\n\t\t\tSourceMonitoringPreferences.shared.isMonitored($0.localBundleIdentifier)\n\t\t}\n\t\tlet freshUpdates = _findUpdates(\n\t\t\trepositories: fetchResult.repositories,\n\t\t\tinstalledApps: monitoredRecords\n\t\t)''',
)

replace_once(
    "Feather/Backend/Observable/UpdateManager.swift",
    "\tprivate func _candidateUpdate(for app: AppInfoPresentable) -> AppUpdate? {",
    '''\tfunc applyMonitoringPreferences() {\n\t\tupdates = updates.filter { _, update in\n\t\t\tSourceMonitoringPreferences.shared.isMonitored(update.localBundleIdentifier)\n\t\t}\n\t}\n\n\tprivate func _candidateUpdate(for app: AppInfoPresentable) -> AppUpdate? {''',
)

replace_once(
    "Feather/Backend/Observable/UpdateManager.swift",
    "\tprivate func _canonicalInstalledApps(\n",
    '''\tprivate func _sourceApps(\n\t\tfrom repositories: [(AltSource, ASRepository)]\n\t) -> [MonitoredSourceApp] {\n\t\tvar canonical: [String: MonitoredSourceApp] = [:]\n\t\t\n\t\tfor (_, repository) in repositories {\n\t\t\tfor app in repository.apps {\n\t\t\t\tguard let rawBundleIdentifier = app.id else { continue }\n\t\t\t\tlet bundleIdentifier = rawBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)\n\t\t\t\tguard !bundleIdentifier.isEmpty else { continue }\n\t\t\t\tlet key = bundleIdentifier.lowercased()\n\t\t\t\tlet candidate = MonitoredSourceApp(\n\t\t\t\t\tbundleIdentifier: bundleIdentifier,\n\t\t\t\t\tname: app.currentName,\n\t\t\t\t\ticonURL: app.iconURL\n\t\t\t\t)\n\t\t\t\t\n\t\t\t\tif let current = canonical[key] {\n\t\t\t\t\tlet currentIsUnknown = current.name.caseInsensitiveCompare("Unknown") == .orderedSame\n\t\t\t\t\tlet candidateIsKnown = candidate.name.caseInsensitiveCompare("Unknown") != .orderedSame\n\t\t\t\t\tif currentIsUnknown && candidateIsKnown {\n\t\t\t\t\t\tcanonical[key] = candidate\n\t\t\t\t\t}\n\t\t\t\t} else {\n\t\t\t\t\tcanonical[key] = candidate\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t\t\n\t\treturn canonical.values.sorted {\n\t\t\t$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending\n\t\t}\n\t}\n\n\tprivate func _canonicalInstalledApps(\n''',
)

# Tweak catalog screen: new Apps monitorados section, deduplicated from sourceApps.
replace_once(
    "Feather/Views/Settings/TweakCatalogView.swift",
    "\t@StateObject private var _catalog = TweakCatalogManager.shared\n\t@ObservedObject private var _registry = InstallationRegistry.shared\n",
    "\t@StateObject private var _catalog = TweakCatalogManager.shared\n\t@StateObject private var _monitoring = SourceMonitoringPreferences.shared\n\t@StateObject private var _updates = UpdateManager.shared\n\t@ObservedObject private var _registry = InstallationRegistry.shared\n",
)

replace_once(
    "Feather/Views/Settings/TweakCatalogView.swift",
    '''\tprivate var _records: [InstalledSourceAppRecord] {\n\t\t_registry.records.sorted {''',
    '''\tprivate var _records: [InstalledSourceAppRecord] {\n\t\t_registry.records\n\t\t\t.filter { _monitoring.isMonitored($0.localBundleIdentifier) }\n\t\t\t.sorted {''',
)

replace_once(
    "Feather/Views/Settings/TweakCatalogView.swift",
    '''\t\t\tSection {\n\t\t\t\tNavigationLink(destination: ManuallyInstalledAppsView()) {\n\t\t\t\t\tLabel("Gerenciar apps instalados", systemImage: "app.badge.checkmark")\n\t\t\t\t}\n\t\t\t} footer: {\n\t\t\t\tText("Cadastre aqui um app que já estava instalado antes do Feather começar a acompanhá-lo. Depois você poderá informar o tweak instalado.")\n\t\t\t}\n\t\t\t\n\t\t\tif !_records.isEmpty {''',
    '''\t\t\tSection {\n\t\t\t\tNavigationLink(destination: ManuallyInstalledAppsView()) {\n\t\t\t\t\tLabel("Gerenciar apps instalados", systemImage: "app.badge.checkmark")\n\t\t\t\t}\n\t\t\t} footer: {\n\t\t\t\tText("Cadastre aqui um app que já estava instalado antes do Feather começar a acompanhá-lo. Depois você poderá informar o tweak instalado.")\n\t\t\t}\n\t\t\t\n\t\t\tif !_updates.sourceApps.isEmpty {\n\t\t\t\tSection {\n\t\t\t\t\tForEach(_updates.sourceApps) { app in\n\t\t\t\t\t\tToggle(\n\t\t\t\t\t\t\tisOn: Binding(\n\t\t\t\t\t\t\t\tget: { _monitoring.isMonitored(app.bundleIdentifier) },\n\t\t\t\t\t\t\t\tset: { enabled in\n\t\t\t\t\t\t\t\t\t_monitoring.setMonitored(enabled, bundleIdentifier: app.bundleIdentifier)\n\t\t\t\t\t\t\t\t\t_updates.applyMonitoringPreferences()\n\t\t\t\t\t\t\t\t\tif enabled {\n\t\t\t\t\t\t\t\t\t\tTask {\n\t\t\t\t\t\t\t\t\t\t\tawait _updates.checkForUpdates(sources: Storage.shared.getSources())\n\t\t\t\t\t\t\t\t\t\t}\n\t\t\t\t\t\t\t\t\t}\n\t\t\t\t\t\t\t\t}\n\t\t\t\t\t\t\t)\n\t\t\t\t\t\t) {\n\t\t\t\t\t\t\tVStack(alignment: .leading, spacing: 2) {\n\t\t\t\t\t\t\t\tText(app.name)\n\t\t\t\t\t\t\t\tText(app.bundleIdentifier)\n\t\t\t\t\t\t\t\t\t.font(.caption2)\n\t\t\t\t\t\t\t\t\t.foregroundStyle(.secondary)\n\t\t\t\t\t\t\t}\n\t\t\t\t\t\t}\n\t\t\t\t\t}\n\t\t\t\t} header: {\n\t\t\t\t\tText("Apps monitorados")\n\t\t\t\t} footer: {\n\t\t\t\t\tText("Escolha quais aplicativos das suas fontes serão monitorados para tweaks e atualizações. Apps ocultados continuam disponíveis normalmente nas Fontes e podem ser reativados a qualquer momento.")\n\t\t\t\t}\n\t\t\t}\n\t\t\t\n\t\t\tif !_records.isEmpty {''',
)

replace_once(
    "Feather/Views/Settings/TweakCatalogView.swift",
    '''\t\t.task {\n\t\t\tawait _catalog.refresh(force: false)\n\t\t}\n''',
    '''\t\t.task {\n\t\t\tawait _catalog.refresh(force: false)\n\t\t\tawait _updates.checkForUpdates(sources: Storage.shared.getSources())\n\t\t}\n''',
)

# Tab bar: respond to preference changes so badge/update state remains synchronized.
replace_once(
    "Feather/Views/TabView/Bars/TabbarView.swift",
    '''\t\t.onReceive(NotificationCenter.default.publisher(for: .featherSourcesChanged)) { _ in\n\t\t\tTask { await _checkForUpdates() }\n\t\t}\n\t\t.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.selectTab"))) { notification in''',
    '''\t\t.onReceive(NotificationCenter.default.publisher(for: .featherSourcesChanged)) { _ in\n\t\t\tTask { await _checkForUpdates() }\n\t\t}\n\t\t.onReceive(NotificationCenter.default.publisher(for: .featherSourceMonitoringChanged)) { _ in\n\t\t\tupdateManager.applyMonitoringPreferences()\n\t\t\tTask { await _checkForUpdates() }\n\t\t}\n\t\t.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.selectTab"))) { notification in''',
)

# Backup: include monitoring choices with Updates and retain compatibility with schema 1/2.
replace_once(
    "Feather/Backend/Backup/BackupManager.swift",
    '''private struct FeatherBackupPayload: Codable {\n\tlet schemaVersion: Int\n\tlet createdAt: Date\n\tlet records: [InstalledSourceAppRecord]?\n\tlet sources: [FeatherBackupSourceRecord]?\n}''',
    '''private struct FeatherBackupPayload: Codable {\n\tlet schemaVersion: Int\n\tlet createdAt: Date\n\tlet records: [InstalledSourceAppRecord]?\n\tlet sources: [FeatherBackupSourceRecord]?\n\tlet hiddenMonitoredBundleIdentifiers: [String]?\n}''',
)

replace_once(
    "Feather/Backend/Backup/BackupManager.swift",
    '''\t\tNotificationCenter.default.addObserver(\n\t\t\tforName: .featherSourcesChanged,\n\t\t\tobject: nil,\n\t\t\tqueue: .main\n\t\t) { [weak self] _ in\n\t\t\tTask { @MainActor in\n\t\t\t\tself?.scheduleAutomaticBackup()\n\t\t\t}\n\t\t}\n''',
    '''\t\tNotificationCenter.default.addObserver(\n\t\t\tforName: .featherSourcesChanged,\n\t\t\tobject: nil,\n\t\t\tqueue: .main\n\t\t) { [weak self] _ in\n\t\t\tTask { @MainActor in\n\t\t\t\tself?.scheduleAutomaticBackup()\n\t\t\t}\n\t\t}\n\t\t\n\t\tNotificationCenter.default.addObserver(\n\t\t\tforName: .featherSourceMonitoringChanged,\n\t\t\tobject: nil,\n\t\t\tqueue: .main\n\t\t) { [weak self] _ in\n\t\t\tTask { @MainActor in\n\t\t\t\tself?.scheduleAutomaticBackup()\n\t\t\t}\n\t\t}\n''',
)

replace_once(
    "Feather/Backend/Backup/BackupManager.swift",
    '''\t\tlet payload = FeatherBackupPayload(\n\t\t\tschemaVersion: 2,\n\t\t\tcreatedAt: Date(),\n\t\t\trecords: includeUpdateHistory ? InstallationRegistry.shared.records : nil,\n\t\t\tsources: sourceRecords\n\t\t)''',
    '''\t\tlet payload = FeatherBackupPayload(\n\t\t\tschemaVersion: 3,\n\t\t\tcreatedAt: Date(),\n\t\t\trecords: includeUpdateHistory ? InstallationRegistry.shared.records : nil,\n\t\t\tsources: sourceRecords,\n\t\t\thiddenMonitoredBundleIdentifiers: includeUpdateHistory\n\t\t\t\t? SourceMonitoringPreferences.shared.backupHiddenBundleIdentifiers\n\t\t\t\t: nil\n\t\t)''',
)

replace_once(
    "Feather/Backend/Backup/BackupManager.swift",
    '''\t\tguard payload.schemaVersion == 1 || payload.schemaVersion == 2 else {\n\t\t\tthrow FeatherBackupError.unsupportedBackupVersion\n\t\t}\n\t\t\n\t\tvar restoredRecordCount = 0\n\t\tif restoreUpdateHistory, let records = payload.records {\n\t\t\tInstallationRegistry.shared.restoreBackupRecords(records)\n\t\t\trestoredRecordCount = records.count\n\t\t}\n''',
    '''\t\tguard [1, 2, 3].contains(payload.schemaVersion) else {\n\t\t\tthrow FeatherBackupError.unsupportedBackupVersion\n\t\t}\n\t\t\n\t\tvar restoredRecordCount = 0\n\t\tif restoreUpdateHistory {\n\t\t\tif let records = payload.records {\n\t\t\t\tInstallationRegistry.shared.restoreBackupRecords(records)\n\t\t\t\trestoredRecordCount = records.count\n\t\t\t}\n\t\t\tSourceMonitoringPreferences.shared.restoreHiddenBundleIdentifiers(\n\t\t\t\tpayload.hiddenMonitoredBundleIdentifiers ?? []\n\t\t\t)\n\t\t}\n''',
)

print("✅ Feather 3.1 Beta 3 aplicado: Apps monitorados, filtros, badge e backup.")
