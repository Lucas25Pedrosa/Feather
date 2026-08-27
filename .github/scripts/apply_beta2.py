from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: esperado 1 ponto de alteração, encontrado {count}")
    return text.replace(old, new, 1)


def patch_registry() -> None:
    path = ROOT / "Feather/Backend/Storage/InstallationRegistry.swift"
    text = path.read_text(encoding="utf-8")
    if "enum InstalledPackageMetadataSource" in text:
        print("InstallationRegistry já contém Beta 2.")
        return

    text = replace_once(
        text,
        '''extension Notification.Name {\n\tstatic let featherInstallationRegistryChanged = Notification.Name("Feather.installationRegistryChanged")\n}\n\nstruct InstalledSourceAppRecord''',
        '''extension Notification.Name {\n\tstatic let featherInstallationRegistryChanged = Notification.Name("Feather.installationRegistryChanged")\n}\n\nenum InstalledPackageMetadataSource: String, Codable {\n\tcase manual\n\tcase source\n}\n\nstruct InstalledSourceAppRecord''',
        "enum de origem do pacote",
    )
    text = replace_once(
        text,
        '''\t// Optional so registries created by Feather 3.0 remain decodable.\n\tvar installedBuildVersion: String? = nil\n\tvar appName: String?''',
        '''\t// Optional so registries created by Feather 3.0 remain decodable.\n\tvar installedBuildVersion: String? = nil\n\t// Optional Beta 2 package metadata. Missing keys remain compatible with Beta 1 backups.\n\tvar installedPackageName: String? = nil\n\tvar installedPackageVersion: String? = nil\n\tvar installedPackageRevision: String? = nil\n\tvar packageMetadataSource: InstalledPackageMetadataSource? = nil\n\tvar appName: String?''',
        "campos de pacote",
    )
    text = replace_once(
        text,
        '''\tvar hasHiddenUpdates: Bool {\n\t\tupdatesDisabled == true || ignoredRemoteVersion != nil\n\t}''',
        '''\tvar installedPackageLabel: String? {\n\t\tguard\n\t\t\tlet name = installedPackageName?.trimmingCharacters(in: .whitespacesAndNewlines),\n\t\t\t!name.isEmpty,\n\t\t\tlet version = installedPackageVersion?.trimmingCharacters(in: .whitespacesAndNewlines),\n\t\t\t!version.isEmpty\n\t\telse {\n\t\t\treturn nil\n\t\t}\n\t\treturn "\\(name) \\(version)"\n\t}\n\t\n\tvar hasHiddenUpdates: Bool {\n\t\tupdatesDisabled == true || ignoredRemoteVersion != nil\n\t}''',
        "label instalado",
    )
    text = replace_once(
        text,
        '''\t\t\tsourceAppVersionDate: metadata?.sourceAppVersionDate ?? fallbackProvenance?.sourceAppVersionDate,\n\t\t\tsourceAppDownloadURL: metadata?.sourceAppDownloadURL ?? fallbackProvenance?.sourceAppDownloadURL\n\t\t)''',
        '''\t\t\tsourceAppVersionDate: metadata?.sourceAppVersionDate ?? fallbackProvenance?.sourceAppVersionDate,\n\t\t\tsourceAppDownloadURL: metadata?.sourceAppDownloadURL ?? fallbackProvenance?.sourceAppDownloadURL,\n\t\t\tderivePackageMetadata: true\n\t\t)''',
        "upsert automático",
    )
    text = replace_once(
        text,
        '''\t\t\tsourceAppVersionDate: provenance.sourceAppVersionDate,\n\t\t\tsourceAppDownloadURL: provenance.sourceAppDownloadURL\n\t\t)''',
        '''\t\t\tsourceAppVersionDate: provenance.sourceAppVersionDate,\n\t\t\tsourceAppDownloadURL: provenance.sourceAppDownloadURL,\n\t\t\tderivePackageMetadata: false\n\t\t)''',
        "upsert manual",
    )
    text = replace_once(
        text,
        '''\t@discardableResult\n\tfunc remove(recordID: String) -> Bool {''',
        '''\t@discardableResult\n\tfunc setInstalledPackage(\n\t\trecordID: String,\n\t\tname: String,\n\t\tversion: String,\n\t\trevision: String?,\n\t\tsource: InstalledPackageMetadataSource\n\t) -> Bool {\n\t\tlet normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)\n\t\tlet normalizedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)\n\t\tguard\n\t\t\t!normalizedName.isEmpty,\n\t\t\t!normalizedVersion.isEmpty,\n\t\t\tlet index = records.firstIndex(where: { $0.id == recordID })\n\t\telse {\n\t\t\treturn false\n\t\t}\n\t\tlet normalizedRevision = revision?.trimmingCharacters(in: .whitespacesAndNewlines)\n\t\trecords[index].installedPackageName = normalizedName\n\t\trecords[index].installedPackageVersion = normalizedVersion\n\t\trecords[index].installedPackageRevision = normalizedRevision?.isEmpty == false ? normalizedRevision : nil\n\t\trecords[index].packageMetadataSource = source\n\t\trecords[index].updatedAt = Date()\n\t\trecords[index].ignoredRemoteVersion = nil\n\t\t_save()\n\t\treturn true\n\t}\n\t\n\t@discardableResult\n\tfunc clearInstalledPackage(recordID: String) -> Bool {\n\t\tguard let index = records.firstIndex(where: { $0.id == recordID }) else {\n\t\t\treturn false\n\t\t}\n\t\trecords[index].installedPackageName = nil\n\t\trecords[index].installedPackageVersion = nil\n\t\trecords[index].installedPackageRevision = nil\n\t\trecords[index].packageMetadataSource = nil\n\t\trecords[index].updatedAt = Date()\n\t\trecords[index].ignoredRemoteVersion = nil\n\t\t_save()\n\t\treturn true\n\t}\n\t\n\t@discardableResult\n\tfunc remove(recordID: String) -> Bool {''',
        "métodos de pacote",
    )
    text = replace_once(
        text,
        '''\t\tsourceAppIdentifier: String,\n\t\tsourceAppVersionDate: Date?,\n\t\tsourceAppDownloadURL: URL?\n\t) -> Bool {''',
        '''\t\tsourceAppIdentifier: String,\n\t\tsourceAppVersionDate: Date?,\n\t\tsourceAppDownloadURL: URL?,\n\t\tderivePackageMetadata: Bool\n\t) -> Bool {''',
        "assinatura upsert",
    )
    text = replace_once(
        text,
        '''\t\t}\n\t\t\n\t\t_save()\n\t\treturn true\n\t}\n\t\n\tprivate func _canonicalized''',
        '''\t\t}\n\t\t\n\t\tif\n\t\t\tderivePackageMetadata,\n\t\t\tlet package = Self._packageMetadata(from: sourceAppDownloadURL),\n\t\t\tlet index = records.firstIndex(where: { $0.localBundleIdentifier == localBundleIdentifier })\n\t\t{\n\t\t\trecords[index].installedPackageName = package.name\n\t\t\trecords[index].installedPackageVersion = package.version\n\t\t\trecords[index].installedPackageRevision = package.revision\n\t\t\trecords[index].packageMetadataSource = .source\n\t\t}\n\t\t\n\t\t_save()\n\t\treturn true\n\t}\n\t\n\tprivate static func _packageMetadata(\n\t\tfrom url: URL?\n\t) -> (name: String, version: String, revision: String?)? {\n\t\tguard let url else { return nil }\n\t\tlet name = _queryValue(in: url, keys: ["tweak", "tweakName"])\n\t\tlet version = _queryValue(in: url, keys: ["tweakVersion"])\n\t\tguard let name, let version else { return nil }\n\t\tlet revision = _queryValue(\n\t\t\tin: url,\n\t\t\tkeys: ["packageRevision", "featherRevision", "pkgRevision"]\n\t\t)\n\t\treturn (name, version, revision)\n\t}\n\t\n\tprivate static func _queryValue(in url: URL, keys: [String]) -> String? {\n\t\tguard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {\n\t\t\treturn nil\n\t\t}\n\t\tfor key in keys {\n\t\t\tif let value = queryItems.first(where: {\n\t\t\t\t$0.name.compare(key, options: [.caseInsensitive]) == .orderedSame\n\t\t\t})?.value?.trimmingCharacters(in: .whitespacesAndNewlines),\n\t\t\t!value.isEmpty {\n\t\t\t\treturn value\n\t\t\t}\n\t\t}\n\t\treturn nil\n\t}\n\t\n\tprivate func _canonicalized''',
        "derivação automática",
    )
    path.write_text(text, encoding="utf-8")
    print("✅ InstallationRegistry Beta 2 aplicado.")


def patch_update_manager() -> None:
    path = ROOT / "Feather/Backend/Observable/UpdateManager.swift"
    text = path.read_text(encoding="utf-8")
    if "installedRecord: InstalledSourceAppRecord" in text:
        print("UpdateManager já contém Beta 2.")
        return

    text = replace_once(
        text,
        '''\tfunc update(for app: AppInfoPresentable) -> AppUpdate? {\n\t\tguard let candidate = _candidateUpdate(for: app) else { return nil }\n\t\t\n\t\t// Source metadata is authoritative''',
        '''\tfunc update(for app: AppInfoPresentable) -> AppUpdate? {\n\t\tguard let candidate = _candidateUpdate(for: app) else { return nil }\n\t\t\n\t\tif\n\t\t\tlet localBundleIdentifier = app.identifier,\n\t\t\tlet installedRecord = InstallationRegistry.shared.records.first(where: {\n\t\t\t\t$0.localBundleIdentifier == localBundleIdentifier\n\t\t\t})\n\t\t{\n\t\t\treturn Self._isRemoteReleaseNewer(\n\t\t\t\tremoteVersion: candidate.remoteVersion,\n\t\t\t\tremoteBuild: candidate.remoteBuildVersion,\n\t\t\t\tremoteDownloadURL: candidate.downloadURL,\n\t\t\t\tinstalledRecord: installedRecord\n\t\t\t) ? candidate : nil\n\t\t}\n\t\t\n\t\t// Source metadata is authoritative''',
        "registro local em update(for:)",
    )
    text = replace_once(
        text,
        '''\t\t\t\tguard Self._isRemoteReleaseNewer(\n\t\t\t\t\tremoteVersion: remoteVersion,\n\t\t\t\t\tremoteBuild: remoteBuild,\n\t\t\t\t\tremoteDownloadURL: downloadURL,\n\t\t\t\t\tinstalledVersion: installedApp.installedVersion,\n\t\t\t\t\tinstalledBuild: installedApp.installedBuildVersion,\n\t\t\t\t\tinstalledDownloadURL: installedApp.sourceAppDownloadURL\n\t\t\t\t) else {''',
        '''\t\t\t\tguard Self._isRemoteReleaseNewer(\n\t\t\t\t\tremoteVersion: remoteVersion,\n\t\t\t\t\tremoteBuild: remoteBuild,\n\t\t\t\t\tremoteDownloadURL: downloadURL,\n\t\t\t\t\tinstalledRecord: installedApp\n\t\t\t\t) else {''',
        "comparação do registro",
    )
    text = replace_once(
        text,
        '''\t\t\t\tlet localPackageRevision = Self._packageRevision(from: installedApp.sourceAppDownloadURL)\n\t\t\t\tlet remotePackageRevision = Self._packageRevision(from: downloadURL)\n\t\t\t\tlet localPackageLabel = Self._packageLabel(from: installedApp.sourceAppDownloadURL)\n\t\t\t\tlet remotePackageLabel = Self._packageLabel(from: downloadURL)''',
        '''\t\t\t\tlet localPackageRevision = installedApp.installedPackageRevision\n\t\t\t\t\t?? Self._packageRevision(from: installedApp.sourceAppDownloadURL)\n\t\t\t\tlet remotePackageRevision = Self._packageRevision(from: downloadURL)\n\t\t\t\tlet localPackageLabel = installedApp.installedPackageLabel\n\t\t\t\t\t?? Self._packageLabel(from: installedApp.sourceAppDownloadURL)\n\t\t\t\tlet remotePackageLabel = Self._packageLabel(from: downloadURL)''',
        "labels locais",
    )
    text = replace_once(
        text,
        '''\t\t\t\tlet packageOnlyUpdate = Self._isPackageOnlyUpdate(\n\t\t\t\t\tremoteVersion: remoteVersion,\n\t\t\t\t\tremoteBuild: remoteBuild,\n\t\t\t\t\tremoteDownloadURL: downloadURL,\n\t\t\t\t\tinstalledVersion: installedApp.installedVersion,\n\t\t\t\t\tinstalledBuild: installedApp.installedBuildVersion,\n\t\t\t\t\tinstalledDownloadURL: installedApp.sourceAppDownloadURL\n\t\t\t\t)''',
        '''\t\t\t\tlet packageOnlyUpdate = Self._isPackageOnlyUpdate(\n\t\t\t\t\tremoteVersion: remoteVersion,\n\t\t\t\t\tremoteBuild: remoteBuild,\n\t\t\t\t\tremoteDownloadURL: downloadURL,\n\t\t\t\t\tinstalledRecord: installedApp\n\t\t\t\t)''',
        "package-only do registro",
    )
    marker = '''\tprivate static func _isRemoteReleaseNewer(\n\t\tremoteVersion: String,\n\t\tremoteBuild: String?,\n\t\tremoteDownloadURL: URL? = nil,\n\t\tinstalledVersion: String,'''
    overload = '''\tprivate static func _isRemoteReleaseNewer(\n\t\tremoteVersion: String,\n\t\tremoteBuild: String?,\n\t\tremoteDownloadURL: URL?,\n\t\tinstalledRecord: InstalledSourceAppRecord\n\t) -> Bool {\n\t\tlet versionComparison = remoteVersion.compare(\n\t\t\tinstalledRecord.installedVersion,\n\t\t\toptions: [.numeric, .caseInsensitive]\n\t\t)\n\t\tif versionComparison == .orderedDescending { return true }\n\t\tif versionComparison == .orderedAscending { return false }\n\t\t\n\t\tlet normalizedRemoteBuild = _normalizedValue(remoteBuild)\n\t\tlet normalizedInstalledBuild = _normalizedValue(installedRecord.installedBuildVersion)\n\t\tif normalizedRemoteBuild != normalizedInstalledBuild {\n\t\t\tguard\n\t\t\t\tlet normalizedRemoteBuild,\n\t\t\t\tlet normalizedInstalledBuild\n\t\t\telse {\n\t\t\t\treturn false\n\t\t\t}\n\t\t\treturn normalizedRemoteBuild.compare(\n\t\t\t\tnormalizedInstalledBuild,\n\t\t\t\toptions: [.numeric, .caseInsensitive]\n\t\t\t) == .orderedDescending\n\t\t}\n\t\t\n\t\tif let installedPackageVersion = _normalizedValue(installedRecord.installedPackageVersion) {\n\t\t\tguard let remotePackageVersion = _packageVersion(from: remoteDownloadURL) else {\n\t\t\t\treturn false\n\t\t\t}\n\t\t\tif\n\t\t\t\tlet installedPackageName = _normalizedValue(installedRecord.installedPackageName),\n\t\t\t\tlet remotePackageName = _packageName(from: remoteDownloadURL),\n\t\t\t\tinstalledPackageName.compare(remotePackageName, options: [.caseInsensitive]) != .orderedSame\n\t\t\t{\n\t\t\t\treturn true\n\t\t\t}\n\t\t\tlet packageVersionComparison = remotePackageVersion.compare(\n\t\t\t\tinstalledPackageVersion,\n\t\t\t\toptions: [.numeric, .caseInsensitive]\n\t\t\t)\n\t\t\tif packageVersionComparison == .orderedDescending { return true }\n\t\t\tif packageVersionComparison == .orderedAscending { return false }\n\t\t\t\n\t\t\tguard\n\t\t\t\tlet remoteRevision = _packageRevision(from: remoteDownloadURL),\n\t\t\t\tlet installedRevision = _normalizedValue(installedRecord.installedPackageRevision)\n\t\t\telse {\n\t\t\t\t// A manually configured matching version has no trustworthy byte revision.\n\t\t\t\t// Do not turn that migration state into a false-positive update.\n\t\t\t\treturn false\n\t\t\t}\n\t\t\treturn remoteRevision.compare(installedRevision, options: [.caseInsensitive]) != .orderedSame\n\t\t}\n\t\t\n\t\treturn _isRemoteReleaseNewer(\n\t\t\tremoteVersion: remoteVersion,\n\t\t\tremoteBuild: remoteBuild,\n\t\t\tremoteDownloadURL: remoteDownloadURL,\n\t\t\tinstalledVersion: installedRecord.installedVersion,\n\t\t\tinstalledBuild: installedRecord.installedBuildVersion,\n\t\t\tinstalledDownloadURL: installedRecord.sourceAppDownloadURL\n\t\t)\n\t}\n\t\n\tprivate static func _isPackageOnlyUpdate(\n\t\tremoteVersion: String,\n\t\tremoteBuild: String?,\n\t\tremoteDownloadURL: URL?,\n\t\tinstalledRecord: InstalledSourceAppRecord\n\t) -> Bool {\n\t\tguard remoteVersion.compare(\n\t\t\tinstalledRecord.installedVersion,\n\t\t\toptions: [.numeric, .caseInsensitive]\n\t\t) == .orderedSame else {\n\t\t\treturn false\n\t\t}\n\t\tguard _normalizedValue(remoteBuild) == _normalizedValue(installedRecord.installedBuildVersion) else {\n\t\t\treturn false\n\t\t}\n\t\treturn _isRemoteReleaseNewer(\n\t\t\tremoteVersion: remoteVersion,\n\t\t\tremoteBuild: remoteBuild,\n\t\t\tremoteDownloadURL: remoteDownloadURL,\n\t\t\tinstalledRecord: installedRecord\n\t\t)\n\t}\n\t\n'''
    if text.count(marker) != 1:
        raise SystemExit("overload UpdateManager: marcador não encontrado exatamente uma vez")
    text = text.replace(marker, overload + marker, 1)

    text = replace_once(
        text,
        '''\tprivate static func _packageRevision(from url: URL?) -> String? {''',
        '''\tprivate static func _packageName(from url: URL?) -> String? {\n\t\tguard let url else { return nil }\n\t\treturn _queryValue(in: url, keys: ["tweak", "tweakName"])\n\t}\n\t\n\tprivate static func _packageVersion(from url: URL?) -> String? {\n\t\tguard let url else { return nil }\n\t\treturn _queryValue(in: url, keys: ["tweakVersion"])\n\t}\n\t\n\tprivate static func _packageRevision(from url: URL?) -> String? {''',
        "helpers package name/version",
    )
    path.write_text(text, encoding="utf-8")
    print("✅ UpdateManager Beta 2 aplicado.")


def patch_updates_view() -> None:
    path = ROOT / "Feather/Views/Updates/UpdatesView.swift"
    text = path.read_text(encoding="utf-8")
    if "Nova revisão disponível" in text and "VStack(alignment: .leading, spacing: 8)" in text:
        print("UpdatesView já contém Beta 2.")
        return

    text = replace_once(
        text,
        '''\t\t\tif let remoteLabel = update.remotePackageLabel {\n\t\t\t\treturn remoteLabel\n\t\t\t}''',
        '''\t\t\tif let remoteLabel = update.remotePackageLabel {\n\t\t\t\tif\n\t\t\t\t\tlet localRevision = update.localPackageRevision,\n\t\t\t\t\tlet remoteRevision = update.remotePackageRevision,\n\t\t\t\t\tlocalRevision.compare(remoteRevision, options: [.caseInsensitive]) != .orderedSame\n\t\t\t\t{\n\t\t\t\t\treturn "\\(remoteLabel) • Nova revisão disponível"\n\t\t\t\t}\n\t\t\t\treturn remoteLabel\n\t\t\t}''',
        "subtitle revisão",
    )

    old = '''\t\tVStack(alignment: .leading, spacing: 10) {\n\t\t\tHStack(spacing: 18) {\n\t\t\t\tUpdateAppIconView(url: update.iconURL)\n\t\t\t\t\n\t\t\t\tNBTitleWithSubtitleView(\n\t\t\t\t\ttitle: update.appName,\n\t\t\t\t\tsubtitle: _subtitle,\n\t\t\t\t\tlinelimit: 0\n\t\t\t\t)\n\t\t\t\t\n\t\t\t\tButton {\n\t\t\t\t\t_startUpdateDownload()\n\t\t\t\t} label: {\n\t\t\t\t\tGroup {\n\t\t\t\t\t\tif _isDownloading {\n\t\t\t\t\t\t\tProgressView()\n\t\t\t\t\t\t\t\t.frame(minWidth: 48)\n\t\t\t\t\t\t} else {\n\t\t\t\t\t\t\tText(.localized("Update"))\n\t\t\t\t\t\t\t\t.lineLimit(1)\n\t\t\t\t\t\t\t\t.font(.headline.bold())\n\t\t\t\t\t\t\t\t.foregroundStyle(Color.accentColor)\n\t\t\t\t\t\t\t\t.padding(.horizontal, 18)\n\t\t\t\t\t\t\t\t.padding(.vertical, 6)\n\t\t\t\t\t\t\t\t.background(Color(uiColor: .quaternarySystemFill))\n\t\t\t\t\t\t\t\t.clipShape(Capsule())\n\t\t\t\t\t\t}\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t\t.buttonStyle(.borderless)\n\t\t\t\t.disabled(_isDownloading)\n\t\t\t\t\n\t\t\t\tMenu {\n\t\t\t\t\tButton(.localized("Hide This Update"), systemImage: "eye.slash") {\n\t\t\t\t\t\tupdateManager.hideCurrentUpdate(update)\n\t\t\t\t\t}\n\t\t\t\t\t\n\t\t\t\t\tButton(.localized("Hide Updates for This App"), systemImage: "bell.slash") {\n\t\t\t\t\t\tupdateManager.hideUpdatesForApp(update)\n\t\t\t\t\t}\n\t\t\t\t} label: {\n\t\t\t\t\tImage(systemName: "ellipsis")\n\t\t\t\t\t\t.frame(width: 24, height: 32)\n\t\t\t\t}\n\t\t\t\t.buttonStyle(.borderless)\n\t\t\t}\n'''
    new = '''\t\tVStack(alignment: .leading, spacing: 10) {\n\t\t\tHStack(alignment: .top, spacing: 18) {\n\t\t\t\tUpdateAppIconView(url: update.iconURL)\n\t\t\t\t\n\t\t\t\tVStack(alignment: .leading, spacing: 8) {\n\t\t\t\t\tHStack(spacing: 8) {\n\t\t\t\t\t\tText(update.appName)\n\t\t\t\t\t\t\t.font(.headline)\n\t\t\t\t\t\t\t.lineLimit(1)\n\t\t\t\t\t\t\t.layoutPriority(1)\n\t\t\t\t\t\t\n\t\t\t\t\t\tSpacer(minLength: 8)\n\t\t\t\t\t\t\n\t\t\t\t\t\tButton {\n\t\t\t\t\t\t\t_startUpdateDownload()\n\t\t\t\t\t\t} label: {\n\t\t\t\t\t\t\tGroup {\n\t\t\t\t\t\t\t\tif _isDownloading {\n\t\t\t\t\t\t\t\t\tProgressView()\n\t\t\t\t\t\t\t\t\t\t.frame(minWidth: 48)\n\t\t\t\t\t\t\t\t} else {\n\t\t\t\t\t\t\t\t\tText(.localized("Update"))\n\t\t\t\t\t\t\t\t\t\t.lineLimit(1)\n\t\t\t\t\t\t\t\t\t\t.font(.headline.bold())\n\t\t\t\t\t\t\t\t\t\t.foregroundStyle(Color.accentColor)\n\t\t\t\t\t\t\t\t\t\t.padding(.horizontal, 18)\n\t\t\t\t\t\t\t\t\t\t.padding(.vertical, 6)\n\t\t\t\t\t\t\t\t\t\t.background(Color(uiColor: .quaternarySystemFill))\n\t\t\t\t\t\t\t\t\t\t.clipShape(Capsule())\n\t\t\t\t\t\t\t\t}\n\t\t\t\t\t\t\t}\n\t\t\t\t\t\t}\n\t\t\t\t\t\t.buttonStyle(.borderless)\n\t\t\t\t\t\t.disabled(_isDownloading)\n\t\t\t\t\t\t\n\t\t\t\t\t\tMenu {\n\t\t\t\t\t\t\tButton(.localized("Hide This Update"), systemImage: "eye.slash") {\n\t\t\t\t\t\t\t\tupdateManager.hideCurrentUpdate(update)\n\t\t\t\t\t\t\t}\n\t\t\t\t\t\t\tButton(.localized("Hide Updates for This App"), systemImage: "bell.slash") {\n\t\t\t\t\t\t\t\tupdateManager.hideUpdatesForApp(update)\n\t\t\t\t\t\t\t}\n\t\t\t\t\t\t} label: {\n\t\t\t\t\t\t\tImage(systemName: "ellipsis")\n\t\t\t\t\t\t\t\t.frame(width: 24, height: 32)\n\t\t\t\t\t\t}\n\t\t\t\t\t\t.buttonStyle(.borderless)\n\t\t\t\t\t}\n\t\t\t\t\t\n\t\t\t\t\tText(_subtitle)\n\t\t\t\t\t\t.font(.subheadline)\n\t\t\t\t\t\t.foregroundStyle(.secondary)\n\t\t\t\t\t\t.lineLimit(2)\n\t\t\t\t\t\t.fixedSize(horizontal: false, vertical: true)\n\t\t\t\t}\n\t\t\t}\n'''
    text = replace_once(text, old, new, "layout da célula")
    path.write_text(text, encoding="utf-8")
    print("✅ UpdatesView Beta 2 aplicado.")


def patch_tabbar() -> None:
    path = ROOT / "Feather/Views/TabView/Bars/TabbarView.swift"
    text = path.read_text(encoding="utf-8")
    if "_TabBarBadgePositionConfigurator" in text:
        print("TabbarView já contém Beta 2.")
        return
    text = replace_once(
        text,
        '''import SwiftUI\nimport CoreData''',
        '''import SwiftUI\nimport CoreData\nimport UIKit''',
        "UIKit Tabbar",
    )
    text = replace_once(
        text,
        '''\t\t}\n\t\t.onAppear {\n\t\t\tguard !_didResolveInitialTab else { return }''',
        '''\t\t}\n\t\t.background(_TabBarBadgePositionConfigurator().frame(width: 0, height: 0))\n\t\t.onAppear {\n\t\t\tguard !_didResolveInitialTab else { return }''',
        "configurador de badge",
    )
    text += '''\n\nprivate struct _TabBarBadgePositionConfigurator: UIViewControllerRepresentable {\n\tfunc makeUIViewController(context: Context) -> Controller {\n\t\tController()\n\t}\n\t\n\tfunc updateUIViewController(_ uiViewController: Controller, context: Context) {\n\t\tuiViewController.configureBadgePosition()\n\t}\n\t\n\tfinal class Controller: UIViewController {\n\t\toverride func viewDidAppear(_ animated: Bool) {\n\t\t\tsuper.viewDidAppear(animated)\n\t\t\tconfigureBadgePosition()\n\t\t}\n\t\t\n\t\tfunc configureBadgePosition() {\n\t\t\tDispatchQueue.main.async { [weak self] in\n\t\t\t\tguard\n\t\t\t\t\tlet root = self?.view.window?.rootViewController,\n\t\t\t\t\tlet tabBarController = Self.findTabBarController(in: root)\n\t\t\t\telse {\n\t\t\t\t\treturn\n\t\t\t\t}\n\t\t\t\tlet tabBar = tabBarController.tabBar\n\t\t\t\tlet appearance = tabBar.standardAppearance\n\t\t\t\tlet offset = UIOffset(horizontal: 5, vertical: -4)\n\t\t\t\tlet layouts = [\n\t\t\t\t\tappearance.stackedLayoutAppearance,\n\t\t\t\t\tappearance.inlineLayoutAppearance,\n\t\t\t\t\tappearance.compactInlineLayoutAppearance,\n\t\t\t\t]\n\t\t\t\tfor layout in layouts {\n\t\t\t\t\tlayout.normal.badgePositionAdjustment = offset\n\t\t\t\t\tlayout.selected.badgePositionAdjustment = offset\n\t\t\t\t\tlayout.focused.badgePositionAdjustment = offset\n\t\t\t\t\tlayout.disabled.badgePositionAdjustment = offset\n\t\t\t\t}\n\t\t\t\ttabBar.standardAppearance = appearance\n\t\t\t\ttabBar.scrollEdgeAppearance = appearance\n\t\t\t}\n\t\t}\n\t\t\n\t\tprivate static func findTabBarController(in controller: UIViewController) -> UITabBarController? {\n\t\t\tif let tabBarController = controller as? UITabBarController {\n\t\t\t\treturn tabBarController\n\t\t\t}\n\t\t\tif let presented = controller.presentedViewController,\n\t\t\t   let match = findTabBarController(in: presented) {\n\t\t\t\treturn match\n\t\t\t}\n\t\t\tfor child in controller.children {\n\t\t\t\tif let match = findTabBarController(in: child) {\n\t\t\t\t\treturn match\n\t\t\t\t}\n\t\t\t}\n\t\t\treturn nil\n\t\t}\n\t}\n}\n'''
    path.write_text(text, encoding="utf-8")
    print("✅ TabbarView Beta 2 aplicado.")


def patch_settings() -> None:
    path = ROOT / "Feather/Views/Settings/SettingsView.swift"
    text = path.read_text(encoding="utf-8")
    if "TweakCatalogView()" in text:
        print("SettingsView já contém Beta 2.")
        return
    text = replace_once(
        text,
        '''\t\t\t\t\tNavigationLink(destination: BackupView()) {\n\t\t\t\t\t\tLabel(.localized("Backup & Restore"), systemImage: "icloud")\n\t\t\t\t\t}''',
        '''\t\t\t\t\tNavigationLink(destination: TweakCatalogView()) {\n\t\t\t\t\t\tLabel("Tweaks e atualizações", systemImage: "shippingbox")\n\t\t\t\t\t}\n\t\t\t\t\tNavigationLink(destination: BackupView()) {\n\t\t\t\t\t\tLabel(.localized("Backup & Restore"), systemImage: "icloud")\n\t\t\t\t\t}''',
        "link para catálogo",
    )
    path.write_text(text, encoding="utf-8")
    print("✅ SettingsView Beta 2 aplicado.")


def patch_build_workflow() -> None:
    path = ROOT / ".github/workflows/build-beta.yml"
    text = path.read_text(encoding="utf-8")
    if "beta/3.1.0-beta2" in text and "30102" in text:
        print("build-beta.yml já contém Beta 2.")
        return
    text = text.replace("beta/3.1.0-beta1", "beta/3.1.0-beta2")
    text = text.replace("Beta 1", "Beta 2")
    text = text.replace("Beta-1", "Beta-2")
    text = text.replace("30101", "30102")
    text = text.replace(
        "# Feather 3.1 Beta 2 validated build pipeline",
        "# Feather 3.1 Beta 2 build pipeline",
    )
    required = [
        "beta/3.1.0-beta2",
        "CURRENT_PROJECT_VERSION",
        "30102",
        "Feather-3.1-Beta-2.ipa",
        "Feather-3.1-Beta-2",
    ]
    for value in required:
        if value not in text:
            raise SystemExit(f"build-beta.yml: valor esperado ausente: {value}")
    path.write_text(text, encoding="utf-8")
    print("✅ Build workflow Beta 2 aplicado.")


def main() -> None:
    patch_registry()
    patch_update_manager()
    patch_updates_view()
    patch_tabbar()
    patch_settings()
    patch_build_workflow()
    print("🔥 Feather 3.1 Beta 2 fechada para compilação.")


if __name__ == "__main__":
    main()
