from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding="utf-8")


# Beta 6 is only a horizontal calibration of the iOS 27 Liquid Glass badge.
# Beta 5 reached the correct active tab bar and the vertical position is good,
# so keep all vertical geometry unchanged and move only the rendered badge
# farther toward the icon's upper-right corner.
path = "Feather/Views/TabView/Bars/TabbarView.swift"
text = read(path)
old = "badgeView.transform = CGAffineTransform(translationX: 5, y: -4)"
new = "badgeView.transform = CGAffineTransform(translationX: 12, y: -4)"

if new in text:
    print("Feather 3.1 Beta 6: horizontal badge calibration already applied.")
elif old in text:
    text = text.replace(old, new, 1)
    write(path, text)
    print("Feather 3.1 Beta 6: badge moved right; vertical position preserved.")
else:
    raise SystemExit("ERRO: ponto de calibração do badge da Beta 5 não encontrado.")
