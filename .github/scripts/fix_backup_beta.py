from pathlib import Path

path = Path("Feather/Backend/Backup/BackupManager.swift")
text = path.read_text(encoding="utf-8")
old = (
    "\t\tvar components = URLComponents(url: url, resolvingAgainstBaseURL: false)\n"
    "\t\tcomponents?.scheme = components?.scheme?.lowercased()\n"
    "\t\tcomponents?.host = components?.host?.lowercased()\n"
    "\t\tcomponents?.fragment = nil\n"
)
new = (
    "\t\tvar components = URLComponents(url: url, resolvingAgainstBaseURL: false)\n"
    "\t\tlet normalizedScheme = components?.scheme?.lowercased()\n"
    "\t\tlet normalizedHost = components?.host?.lowercased()\n"
    "\t\tcomponents?.scheme = normalizedScheme\n"
    "\t\tcomponents?.host = normalizedHost\n"
    "\t\tcomponents?.fragment = nil\n"
)

if old in text:
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("BackupManager.swift corrigido.")
elif new in text:
    print("BackupManager.swift já estava corrigido.")
else:
    raise SystemExit("ERRO: bloco esperado do BackupManager não foi encontrado.")
