from pathlib import Path
import re


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding="utf-8")


def replace_once(path: str, old: str, new: str, label: str) -> None:
    text = read(path)
    if old in text:
        text = text.replace(old, new, 1)
        write(path, text)
        return
    if new in text:
        return
    raise SystemExit(f"ERRO: ponto de alteração não encontrado: {label} ({path})")


# 1) Settings: clearer update-engine name, keep manual cache button only at root,
# remove duplicate StorageCleanup navigation and guarantee Portuguese footer.
settings = "Feather/Views/Settings/SettingsView.swift"
replace_once(
    settings,
    'Label("Atualizações automáticas", systemImage: "arrow.triangle.2.circlepath")',
    'Label("Atualizações e instalação", systemImage: "arrow.triangle.2.circlepath")',
    "nome de Atualizações",
)
replace_once(
    settings,
    '\t\t\t\t\tNavigationLink(destination: StorageCleanupView()) {\n\t\t\t\t\t\tLabel("Cache e armazenamento", systemImage: "internaldrive")\n\t\t\t\t\t}\n',
    '',
    "atalho duplicado de Cache e armazenamento",
)
replace_once(
    settings,
    'Text(.localized("Configure signing, installation, archives, encrypted update-history backups, and cache cleanup."))',
    'Text("Configure assinatura, instalação, arquivos, backups criptografados do histórico de atualizações e limpeza de cache.")',
    "rodapé em português",
)

# 2) Installation: keep Cache e armazenamento here, using one consistent name.
installation = "Feather/Views/Settings/Installation/InstallationView.swift"
replace_once(
    installation,
    'Label("Armazenamento e cache", systemImage: "internaldrive")',
    'Label("Cache e armazenamento", systemImage: "internaldrive")',
    "nome do armazenamento dentro de Instalação",
)

# 3) Storage cleanup: this screen now contains automatic cleanup controls only.
# The one-tap manual cleanup remains in the root Settings screen.
storage_cleanup = "Feather/Views/Settings/StorageCleanupView.swift"
storage_cleanup_text = '''//
//  StorageCleanupView.swift
//  Feather
//
//  Feather 3.2 storage cleanup controls.
//

import SwiftUI
import NimbleViews

struct StorageCleanupView: View {
\t@AppStorage(StorageCleanupManager.automaticCleanupKey) private var _automaticCleanup = false
\t@AppStorage(StorageCleanupManager.automaticPurgeAppsKey) private var _automaticPurgeApps = false

\tvar body: some View {
\t\tNBList("Cache e armazenamento") {
\t\t\tSection {
\t\t\t\tToggle(isOn: $_automaticCleanup) {
\t\t\t\t\tLabel("Limpar cache após instalação", systemImage: "sparkles")
\t\t\t\t}

\t\t\t\tToggle(isOn: $_automaticPurgeApps) {
\t\t\t\t\tLabel("Também apagar importados e assinados", systemImage: "trash")
\t\t\t\t}
\t\t\t\t.disabled(!_automaticCleanup)
\t\t\t} footer: {
\t\t\t\tif _automaticPurgeApps && _automaticCleanup {
\t\t\t\t\tText("Após uma instalação concluída, o Feather também remove da própria biblioteca todas as cópias em Importados e Assinados. O aplicativo já instalado no iOS não é apagado. Certificados, sources, registro de tweaks, histórico de atualizações e backups são preservados.")
\t\t\t\t} else {
\t\t\t\t\tText("A segunda opção é destrutiva e fica desativada por padrão. Ela só atua na limpeza automática após uma instalação concluída.")
\t\t\t\t}
\t\t\t}
\t\t}
\t}
}
'''
if read(storage_cleanup) != storage_cleanup_text:
    write(storage_cleanup, storage_cleanup_text)

# 4) Update engine title.
update_settings = "Feather/Views/Settings/UpdateEngineSettingsView.swift"
replace_once(
    update_settings,
    '.navigationTitle("Atualizações automáticas")',
    '.navigationTitle("Atualizações e instalação")',
    "título interno de Atualizações",
)

# 5) Tweaks screen: Installed Apps is now the single tracking authority.
tweak_view = "Feather/Views/Settings/TweakCatalogView.swift"
text = read(tweak_view)

monitor_section_pattern = re.compile(
    r'\n\t\t\tSection \{\n\t\t\t\tNavigationLink\(destination: MonitoredAppsView\(\)\) \{\n'
    r'.*?'
    r'\n\t\t\t\}\n\t\t\t\n(?=\t\t\tSection \{\n\t\t\t\tNavigationLink\(destination: InstalledTweaksView\(\)\))',
    re.DOTALL,
)
text, count = monitor_section_pattern.subn('\n', text, count=1)
if count == 0 and 'Label("Apps monitorados", systemImage: "eye")' in text:
    raise SystemExit("ERRO: seção Apps monitorados não pôde ser removida.")

text = text.replace(
    '\t@StateObject private var _monitoring = SourceMonitoringPreferences.shared\n',
    '',
    1,
)
text = text.replace(
    '\t\t_registry.records\n\t\t\t.filter { _monitoring.isMonitored($0.localBundleIdentifier) }\n\t\t\t.sorted {',
    '\t\t_registry.records\n\t\t\t.sorted {',
    1,
)
text = text.replace(
    'Nenhum app monitorado possui informação de tweak disponível no momento.',
    'Nenhum app instalado possui informação de tweak disponível no momento.',
)
text = text.replace(
    'Consulte e ajuste o tweak registrado em cada app monitorado, mantendo separadas a versão instalada e a versão disponível no catálogo.',
    'Consulte e ajuste o tweak registrado em cada app instalado, mantendo separadas a versão instalada e a versão disponível no catálogo.',
)

monitor_view_pattern = re.compile(
    r'\nprivate struct MonitoredAppsView: View \{.*?\n\}\n\n(?=private struct InstalledTweakEditorView: View \{)',
    re.DOTALL,
)
text, _ = monitor_view_pattern.subn('\n', text, count=1)
if 'private struct MonitoredAppsView: View' in text:
    raise SystemExit("ERRO: tela interna MonitoredAppsView ainda está presente.")
if 'Label("Apps monitorados", systemImage: "eye")' in text:
    raise SystemExit("ERRO: entrada Apps monitorados ainda está presente.")
write(tweak_view, text)

# 6) Update detection: every InstallationRegistry record is tracked. Removing an
# app in Gerenciar apps instalados is therefore the single way to stop tracking.
update_manager = "Feather/Backend/Observable/UpdateManager.swift"
text = read(update_manager)
old_records = '''\t\tlet monitoredRecords = InstallationRegistry.shared.records.filter {
\t\t\tSourceMonitoringPreferences.shared.isMonitored($0.localBundleIdentifier)
\t\t}
\t\tlet freshUpdates = _findUpdates(
\t\t\trepositories: fetchResult.repositories,
\t\t\tinstalledApps: monitoredRecords
\t\t)'''
new_records = '''\t\tlet installedRecords = InstallationRegistry.shared.records
\t\tlet freshUpdates = _findUpdates(
\t\t\trepositories: fetchResult.repositories,
\t\t\tinstalledApps: installedRecords
\t\t)'''
if old_records in text:
    text = text.replace(old_records, new_records, 1)
elif new_records not in text:
    raise SystemExit("ERRO: filtro de monitoramento do UpdateManager não encontrado.")
old_apply = '''\tfunc applyMonitoringPreferences() {
\t\tupdates = updates.filter { _, update in
\t\t\tSourceMonitoringPreferences.shared.isMonitored(update.localBundleIdentifier)
\t\t}
\t}'''
new_apply = '''\tfunc applyMonitoringPreferences() {
\t\t// Feather 3.2.1: InstallationRegistry is the single tracking authority.
\t}'''
if old_apply in text:
    text = text.replace(old_apply, new_apply, 1)
write(update_manager, text)

# 7) Backup UI: make explicit that the update record set includes installed app
# and tweak versions; the existing toggle is the safe on/off switch for that data.
backup_view = "Feather/Views/Settings/Backup/BackupView.swift"
text = read(backup_view)
text = text.replace(
    '\t\t\t\t\t\t.localized("Updates"),\n\t\t\t\t\t\tisOn: Binding(\n\t\t\t\t\t\t\tget: { backupManager.includeUpdateHistory },',
    '\t\t\t\t\t\t"Versões e atualizações",\n\t\t\t\t\t\tisOn: Binding(\n\t\t\t\t\t\t\tget: { backupManager.includeUpdateHistory },',
    1,
)
text = text.replace(
    'Text(.localized("Choose Sources, Updates, or both. Sources are restored by merging and existing sources are not duplicated."))',
    'Text("Escolha Fontes, Versões e atualizações, ou ambos. Versões e atualizações incluem as versões registradas dos apps e tweaks usadas para detectar novas versões. As fontes são restauradas por mesclagem e não são duplicadas.")',
    1,
)
text = text.replace(
    'Toggle(.localized("Updates"), isOn: $_restoreUpdates)',
    'Toggle("Versões e atualizações", isOn: $_restoreUpdates)',
    1,
)
if '"Versões e atualizações"' not in text:
    raise SystemExit("ERRO: opção de versões do backup não foi aplicada.")
write(backup_view, text)

# 8) IPA Library: seed it once as Feather's default Source. If the user removes
# it afterwards, it stays removed. Existing installations that already have it
# are detected by identifier or URL and are not duplicated.
app_file = "Feather/FeatherApp.swift"
text = read(app_file)
call_old = '''\t\t_createDocumentsDirectories()
\t\tResetView.clearWorkCache()
\t\t_addDefaultCertificates()
\t\treturn true'''
call_new = '''\t\t_createDocumentsDirectories()
\t\tResetView.clearWorkCache()
\t\t_addDefaultIPALibrarySource()
\t\t_addDefaultCertificates()
\t\treturn true'''
if call_old in text:
    text = text.replace(call_old, call_new, 1)
elif '_addDefaultIPALibrarySource()' not in text:
    raise SystemExit("ERRO: ponto de inicialização da IPA Library não encontrado.")

method_marker = '\n\tprivate func _addDefaultCertificates() {'
method = '''
\tprivate func _addDefaultIPALibrarySource() {
\t\tlet defaults = UserDefaults.standard
\t\tlet didSeedKey = "Feather.didAddDefaultIPALibrarySource"
\t\tguard !defaults.bool(forKey: didSeedKey) else { return }

\t\tguard let sourceURL = URL(string: "https://feather-source.f8s79jzkbk.workers.dev/") else {
\t\t\treturn
\t\t}
\t\tlet identifier = "com.lucas.ipa.repository"

\t\tlet alreadyExists = Storage.shared.sourceExists(identifier)
\t\t\t|| Storage.shared.getSources().contains { $0.sourceURL == sourceURL }
\t\tif alreadyExists {
\t\t\tdefaults.set(true, forKey: didSeedKey)
\t\t\treturn
\t\t}

\t\tStorage.shared.addSource(
\t\t\tsourceURL,
\t\t\tname: "IPA Library",
\t\t\tidentifier: identifier,
\t\t\ticonURL: URL(string: "https://raw.githubusercontent.com/Lucas25Pedrosa/ipa-r2-automation/main/Feather/icons/repo.png")
\t\t) { error in
\t\t\tif error == nil {
\t\t\t\tdefaults.set(true, forKey: didSeedKey)
\t\t\t} else if let error {
\t\t\t\tLogger.misc.error("Failed to seed IPA Library source: \\(error)")
\t\t\t}
\t\t}
\t}
'''
if 'private func _addDefaultIPALibrarySource() {' not in text:
    if method_marker not in text:
        raise SystemExit("ERRO: ponto de inserção do método da IPA Library não encontrado.")
    text = text.replace(method_marker, method + method_marker, 1)
write(app_file, text)

# 9) Stable patch version. Bundle ID remains the stable one.
xcconfig = "Feather.xcconfig"
replace_once(
    xcconfig,
    "FEATHER_PROJECT_VERSION=3.2.0",
    "FEATHER_PROJECT_VERSION=3.2.1",
    "versão 3.2.1",
)

print("Feather 3.2.1 refinements applied successfully.")
