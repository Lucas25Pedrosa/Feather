#!/usr/bin/env python3
# Build-time pt-BR catalog merge.
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Feather" / "Resources" / "Localizable.xcstrings"
STRINGS = ROOT / ".github" / "localization" / "pt-BR" / "Localizable.strings"
STRINGSDICT = ROOT / ".github" / "localization" / "pt-BR" / "Localizable.stringsdict"
LOCALE = "pt-BR"

EXTRA_TRANSLATIONS = {
    "Server Password": "Senha do servidor",
    "Leave blank if the server does not have a password.": "Deixe em branco caso o servidor não tenha senha.",
    "The server password could not be stored securely on this device.": "A senha do servidor não pôde ser armazenada com segurança neste dispositivo.",
    "The server password or recovery key was not accepted by the backup service.": "A senha do servidor ou a chave de recuperação não foi aceita pelo serviço de backup.",
    # Feather 3.1 Beta 1
    "Tabs": "Abas",
    "Settings is always available. Drag tabs to change their order.": "Configurações permanece sempre disponível. Arraste as abas para alterar a ordem.",
    "Default Launch Tab": "Aba inicial padrão",
    "Launch": "Inicialização",
    "Backup Content": "Conteúdo do backup",
    "Choose Sources, Updates, or both. Sources are restored by merging and existing sources are not duplicated.": "Escolha Fontes, Atualizações ou ambos. As fontes são restauradas por mesclagem e as fontes existentes não são duplicadas.",
    "Selected data is encrypted on this iPhone before upload. The recovery key is never sent to the backup service.": "Os dados selecionados são criptografados neste iPhone antes do envio. A chave de recuperação nunca é enviada ao serviço de backup.",
    "Restore only changes the selected data. Existing source entries are kept and duplicates are skipped.": "A restauração altera apenas os dados selecionados. As fontes existentes são mantidas e duplicatas são ignoradas.",
    "Only the selected backup content will be restored.": "Somente o conteúdo de backup selecionado será restaurado.",
    "Select Sources, Updates, or both.": "Selecione Fontes, Atualizações ou ambos.",
    "Backup restored: %d update records and %d sources added.": "Backup restaurado: %d registros de atualização e %d fontes adicionadas.",
    "%d source(s) could not be checked. Existing update information was preserved.": "%d fonte(s) não pôde/puderam ser verificada(s). As informações de atualização existentes foram preservadas.",
    "Register apps that were already installed before Feather began tracking them. Their saved versions are used to detect newer versions from your sources and can be included in cloud backup.": "Cadastre apps que já estavam instalados antes de o Feather começar a acompanhá-los. As versões salvas são usadas para detectar versões mais recentes nas suas fontes e podem ser incluídas no backup em nuvem.",
}


def load_plist_as_json(path: Path) -> dict:
    data = subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(path)
    ])
    return json.loads(data)


def string_unit(value: str) -> dict:
    return {
        "stringUnit": {
            "state": "translated",
            "value": value,
        }
    }


def main() -> None:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    translations = load_plist_as_json(STRINGS)
    translations.update(EXTRA_TRANSLATIONS)
    plural_tables = load_plist_as_json(STRINGSDICT)

    if len(translations) < 300:
        raise SystemExit(f"Unexpected pt-BR translation count: {len(translations)}")

    strings = catalog.setdefault("strings", {})

    for key, value in translations.items():
        entry = strings.setdefault(key, {"extractionState": "manual"})
        entry.setdefault("localizations", {})[LOCALE] = string_unit(value)

    plural_count = 0
    for key, table in plural_tables.items():
        format_key = table.get("NSStringLocalizedFormatKey", "")
        if not (format_key.startswith("%#@") and format_key.endswith("@")):
            continue
        variable = format_key[3:-1]
        forms = table.get(variable, {})
        plural = {}
        for category in ("zero", "one", "two", "few", "many", "other"):
            value = forms.get(category)
            if isinstance(value, str):
                plural[category] = string_unit(value)
        if not plural:
            continue
        entry = strings.setdefault(key, {"extractionState": "manual"})
        entry.setdefault("localizations", {})[LOCALE] = {
            "variations": {"plural": plural}
        }
        plural_count += 1

    if plural_count < 3:
        raise SystemExit(f"Unexpected pt-BR plural count: {plural_count}")

    CATALOG.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        f"Merged {len(translations)} pt-BR strings and "
        f"{plural_count} plural entries into Localizable.xcstrings."
    )


if __name__ == "__main__":
    main()
