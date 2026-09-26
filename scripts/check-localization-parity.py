#!/usr/bin/env python3
"""FR/EN parity of every .strings table, for CI (plain Python, no toolchain).

Fails when a key exists in one language only, when a `<key>.one` plural has no
base `<key>` (see the plural RULE in CLAUDE.md), or when a key's format
specifiers (%@, %d, %1$@…) differ between the two languages — a French string
with one `%@` against an English one with two crashes at runtime.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGS = ("fr", "en")
TABLES = ("Localizable.strings", "InfoPlist.strings", "AppShortcuts.strings")
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)
SPEC = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDiuUxXoOfFeEgGcCsSp]")


def parse(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return {m.group(1): m.group(2) for m in ENTRY.finditer(text)}


def specifiers(value: str) -> list[str]:
    return sorted(SPEC.findall(value.replace("%%", "")))


def main() -> int:
    problems: list[str] = []
    for table in TABLES:
        tables = {}
        for lang in LANGS:
            path = ROOT / "Resources" / f"{lang}.lproj" / table
            if not path.exists():
                problems.append(f"{table}: missing for {lang}")
                continue
            tables[lang] = parse(path)
        if len(tables) != len(LANGS):
            continue
        fr, en = tables["fr"], tables["en"]
        for key in sorted(fr.keys() - en.keys()):
            problems.append(f"{table}: '{key}' only in fr")
        for key in sorted(en.keys() - fr.keys()):
            problems.append(f"{table}: '{key}' only in en")
        for key in sorted(fr.keys() & en.keys()):
            if specifiers(fr[key]) != specifiers(en[key]):
                problems.append(f"{table}: '{key}' format specifiers differ (fr {specifiers(fr[key])} / en {specifiers(en[key])})")
        if table == "Localizable.strings":
            for key in sorted(k for k in fr if k.endswith(".one")):
                if key[:-4] not in fr:
                    problems.append(f"{table}: '{key}' has no base key '{key[:-4]}'")
    if problems:
        print("Localization parity FAILED:")
        for p in problems:
            print(f"  - {p}")
        return 1
    count = len(parse(ROOT / "Resources" / "fr.lproj" / "Localizable.strings"))
    print(f"Localization parity OK ({count} keys in Localizable.strings).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
