#!/usr/bin/env python3
"""FR/EN/DE parity of every .strings table, for CI (plain Python, no toolchain).

Fails when a key exists in one language only, when a `<key>.one` plural has no
base `<key>` (see the plural RULE in CLAUDE.md), or when a key's format
specifiers (%@, %d, %1$@…) differ from the French source — a French string
with one `%@` against a translation with two crashes at runtime. Every other
language is compared with French, the base language.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGS = ("fr", "en", "de")
TABLES = ("Localizable.strings", "InfoPlist.strings", "AppShortcuts.strings")
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)
SPEC = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h|z|q)?[@dDiuUxXoOfFeEgGcCsSp]")


DUPLICATES: list[str] = []


def parse(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    entries: dict[str, str] = {}
    for m in ENTRY.finditer(text):
        if m.group(1) in entries:
            DUPLICATES.append(f"{path.parent.name}/{path.name}: '{m.group(1)}' defined twice")
        entries[m.group(1)] = m.group(2)
    return entries


def specifiers(value: str) -> list[str]:
    # `%1$@` and `%@` are the same argument type: compare without positions.
    found = SPEC.findall(value.replace("%%", ""))
    return sorted(re.sub(r"^%\d+\$", "%", f) for f in found)


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
        fr = tables["fr"]
        for lang in LANGS[1:]:
            other = tables[lang]
            for key in sorted(fr.keys() - other.keys()):
                problems.append(f"{table}: '{key}' missing in {lang}")
            for key in sorted(other.keys() - fr.keys()):
                problems.append(f"{table}: '{key}' only in {lang}")
            for key in sorted(fr.keys() & other.keys()):
                if specifiers(fr[key]) != specifiers(other[key]):
                    problems.append(f"{table}: '{key}' format specifiers differ (fr {specifiers(fr[key])} / {lang} {specifiers(other[key])})")
        if table == "Localizable.strings":
            for key in sorted(k for k in fr if k.endswith(".one")):
                if key[:-4] not in fr:
                    problems.append(f"{table}: '{key}' has no base key '{key[:-4]}'")
    problems.extend(DUPLICATES)
    if problems:
        print("Localization parity FAILED:")
        for p in problems:
            print(f"  - {p}")
        return 1
    count = len(parse(ROOT / "Resources" / "fr.lproj" / "Localizable.strings"))
    DUPLICATES.clear()
    print(f"Localization parity OK ({count} keys in Localizable.strings).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
