from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding="utf-8")


# Beta 5 fixes the badge in the tab bar that is actually used on iOS 18+
# (including iOS 27). Previous Beta 3/4 geometry fixes lived only inside
# TabbarView, while VariedTabbarView routes modern iOS versions through
# ExtendedTabbarView.

tabbar_path = "Feather/Views/TabView/Bars/TabbarView.swift"
tabbar = read(tabbar_path)

old_decl = "private struct _TabBarBadgePositionConfigurator: UIViewControllerRepresentable {"
new_decl = "struct _TabBarBadgePositionConfigurator: UIViewControllerRepresentable {"
if old_decl in tabbar:
    tabbar = tabbar.replace(old_decl, new_decl, 1)
elif new_decl not in tabbar:
    raise SystemExit("ERRO: configurador compartilhado do badge não encontrado em TabbarView.swift")
write(tabbar_path, tabbar)


extended_path = "Feather/Views/TabView/Bars/ExtendedTabbarView.swift"
extended = read(extended_path)

anchor = "\t\t.tabViewStyle(.sidebarAdaptable)\n"
insertion = (
    "\t\t.tabViewStyle(.sidebarAdaptable)\n"
    "\t\t// iOS 18+ (incluindo iOS 27) usa este ExtendedTabbarView.\n"
    "\t\t// Monte o configurador aqui para ajustar o badge da barra realmente ativa.\n"
    "\t\t.background(_TabBarBadgePositionConfigurator().frame(width: 0, height: 0))\n"
)

if "_TabBarBadgePositionConfigurator().frame(width: 0, height: 0)" not in extended:
    if anchor not in extended:
        raise SystemExit("ERRO: ponto de inserção do badge não encontrado em ExtendedTabbarView.swift")
    extended = extended.replace(anchor, insertion, 1)

write(extended_path, extended)
print("Feather 3.1 Beta 5: configurador do badge aplicado ao ExtendedTabbarView do iOS 18+.")
