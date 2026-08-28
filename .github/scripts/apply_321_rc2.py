from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding="utf-8")


# Feather 3.2.1 RC2: Installation is the single home for install-related
# configuration. Keep the one-tap manual cache cleanup in root Settings.
settings_path = "Feather/Views/Settings/SettingsView.swift"
settings = read(settings_path)
update_link = '''\t\t\t\t\tNavigationLink(destination: UpdateEngineSettingsView()) {
\t\t\t\t\t\tLabel("Atualizações e instalação", systemImage: "arrow.triangle.2.circlepath")
\t\t\t\t\t}
'''
settings = settings.replace(update_link, "", 1)
if "NavigationLink(destination: UpdateEngineSettingsView())" in settings:
    raise SystemExit("ERRO: submenu Atualizações e instalação ainda está em Ajustes.")
if 'Label("Limpar cache agora", systemImage: "trash.slash")' not in settings:
    raise SystemExit("ERRO: limpeza manual do cache deve permanecer no menu principal.")
write(settings_path, settings)

installation_path = "Feather/Views/Settings/Installation/InstallationView.swift"
installation = '''//
//  InstallationView.swift
//  Feather
//
//  Created by samara on 3.06.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct InstallationView: View {
\t@AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
\t@AppStorage(StorageCleanupManager.automaticCleanupKey) private var _automaticCleanup = false
\t@AppStorage(StorageCleanupManager.automaticPurgeAppsKey) private var _automaticPurgeApps = false
\t@State private var _showMethodChangedAlert = false
\t@StateObject private var _preferences = UpdateEnginePreferences.shared

\t@FetchRequest(
\t\tentity: CertificatePair.entity(),
\t\tsortDescriptors: [NSSortDescriptor(keyPath: \\CertificatePair.date, ascending: false)],
\t\tanimation: .snappy
\t) private var _certificates: FetchedResults<CertificatePair>

\tprivate let _installationMethods: [String] = [
\t\t.localized("Server"),
\t\t.localized("idevice")
\t]
\t
\t// MARK: Body
\tvar body: some View {
\t\tNBList(.localized("Installation")) {
\t\t\tSection {
\t\t\t\tPicker(.localized("Installation Type"), systemImage: "arrow.down.app", selection: $_installationMethod) {
\t\t\t\t\tForEach(_installationMethods.indices, id: \\.description) { index in
\t\t\t\t\t\tText(_installationMethods[index]).tag(index)
\t\t\t\t\t}
\t\t\t\t}
\t\t\t} footer: {
\t\t\t\tText(.localized("Server (Recommended):\\nUses a locally hosted server and itms-services:// to install applications.\\n\\nIDevice (advanced):\\nUses a VPN and a pairing file. Writes to AFC and manually calls installd, while monitoring install progress by using a callback\\nAdvantage: It is very reliable, does not need SSL certificates or a externally hosted server. Rather, works similarly to a computer."))
\t\t\t}

\t\t\tif _installationMethod == 0 {
\t\t\t\tServerView()
\t\t\t} else if _installationMethod == 1 {
\t\t\t\tTunnelView()
\t\t\t}

\t\t\tSection {
\t\t\t\tButton {
\t\t\t\t\t_preferences.selectCertificate(nil)
\t\t\t\t} label: {
\t\t\t\t\tHStack {
\t\t\t\t\t\tLabel("Assinatura manual", systemImage: "hand.tap")
\t\t\t\t\t\tSpacer()
\t\t\t\t\t\tif _preferences.defaultCertificateUUID == nil {
\t\t\t\t\t\t\tImage(systemName: "checkmark")
\t\t\t\t\t\t\t\t.foregroundStyle(Color.accentColor)
\t\t\t\t\t\t}
\t\t\t\t\t}
\t\t\t\t}
\t\t\t\t.buttonStyle(.plain)
\t\t\t} header: {
\t\t\t\tText("Comportamento")
\t\t\t} footer: {
\t\t\t\tText("Sem um certificado padrão, Atualizar mantém o fluxo manual e abre a tela de assinatura depois do download.")
\t\t\t}

\t\t\tSection {
\t\t\t\tif _certificates.isEmpty {
\t\t\t\t\tText("Nenhum certificado importado.")
\t\t\t\t\t\t.foregroundStyle(.secondary)
\t\t\t\t} else {
\t\t\t\t\tForEach(_certificates, id: \\.objectID) { certificate in
\t\t\t\t\t\tButton {
\t\t\t\t\t\t\t_preferences.selectCertificate(certificate)
\t\t\t\t\t\t} label: {
\t\t\t\t\t\t\tHStack(spacing: 12) {
\t\t\t\t\t\t\t\tCertificatesCellView(cert: certificate)
\t\t\t\t\t\t\t\tSpacer(minLength: 8)
\t\t\t\t\t\t\t\tif _preferences.defaultCertificateUUID == certificate.uuid {
\t\t\t\t\t\t\t\t\tImage(systemName: "checkmark.circle.fill")
\t\t\t\t\t\t\t\t\t\t.foregroundStyle(Color.accentColor)
\t\t\t\t\t\t\t\t}
\t\t\t\t\t\t\t}
\t\t\t\t\t\t\t.contentShape(Rectangle())
\t\t\t\t\t\t}
\t\t\t\t\t\t.buttonStyle(.plain)
\t\t\t\t\t\t.disabled(certificate.revoked == true || _isExpired(certificate))
\t\t\t\t\t}
\t\t\t\t}
\t\t\t} header: {
\t\t\t\tText("Certificado padrão")
\t\t\t} footer: {
\t\t\t\tText("Quando um certificado válido é escolhido, Atualizar executa baixar → assinar → instalar. A preferência é vinculada ao UUID do certificado e não muda se a lista for reordenada.")
\t\t\t}

\t\t\tif let selected = _preferences.selectedCertificate(),
\t\t\t   selected.revoked == true || _isExpired(selected) {
\t\t\t\tSection {
\t\t\t\t\tLabel("O certificado selecionado não está mais válido. As atualizações voltarão ao modo manual até você escolher outro.", systemImage: "exclamationmark.triangle.fill")
\t\t\t\t\t\t.foregroundStyle(.orange)
\t\t\t\t}
\t\t\t}

\t\t\tSection {
\t\t\t\tToggle(isOn: $_automaticCleanup) {
\t\t\t\t\tLabel("Limpar cache após instalação", systemImage: "sparkles")
\t\t\t\t}

\t\t\t\tToggle(isOn: $_automaticPurgeApps) {
\t\t\t\t\tLabel("Também apagar importados e assinados", systemImage: "trash")
\t\t\t\t}
\t\t\t\t.disabled(!_automaticCleanup)
\t\t\t} header: {
\t\t\t\tText("Limpeza automática")
\t\t\t} footer: {
\t\t\t\tif _automaticPurgeApps && _automaticCleanup {
\t\t\t\t\tText("Após uma instalação concluída, o Feather também remove da própria biblioteca todas as cópias em Importados e Assinados. O aplicativo já instalado no iOS não é apagado. Certificados, sources, registro de tweaks, histórico de atualizações e backups são preservados.")
\t\t\t\t} else {
\t\t\t\t\tText("A segunda opção é destrutiva e fica desativada por padrão. Ela só atua na limpeza automática após uma instalação concluída.")
\t\t\t\t}
\t\t\t}
\t\t}
\t\t.onChange(of: _installationMethod) { newValue in
\t\t\tguard newValue == 1 else { return }
\t\t\t_showMethodChangedAlert = true
\t\t}
\t\t.alert(.localized("Advanced Installation Method"), isPresented: $_showMethodChangedAlert) {
\t\t\tButton(.localized("Switch Back"), role: .destructive) {
\t\t\t\t_installationMethod = 0
\t\t\t}
\t\t\tButton(.localized("OK"), role: .cancel) {}
\t\t} message: {
\t\t\tText(.localized("idevice warning"))
\t\t}
\t\t.animation(.default, value: _installationMethod)
\t}

\tprivate func _isExpired(_ certificate: CertificatePair) -> Bool {
\t\tguard let expiration = certificate.expiration else { return true }
\t\treturn expiration <= Date()
\t}
}
'''
write(installation_path, installation)

print("Feather 3.2.1 RC2 installation layout applied successfully.")
