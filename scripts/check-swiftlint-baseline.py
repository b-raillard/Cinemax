#!/usr/bin/env python3
"""Fails when `.swiftlint-baseline.json` holds an entry nothing matches any more.

SwiftLint matches a baseline entry on file + rule + line text (many with an
empty text), so a stale entry can silently absorb an identical NEW violation.
Usage: check-swiftlint-baseline.py <committed baseline> <fresh baseline>, the
fresh one written by `swiftlint lint --write-baseline` with the pinned version.
Fix: regenerate the committed baseline (see the SwiftLint RULE in CLAUDE.md).
"""
import json
import sys
from collections import Counter


def keys(path: str) -> Counter:
    with open(path, encoding="utf-8") as f:
        entries = json.load(f)
    return Counter(
        (e["violation"]["location"]["file"], e["violation"]["ruleIdentifier"], e["text"])
        for e in entries
    )


def main() -> int:
    committed, fresh = keys(sys.argv[1]), keys(sys.argv[2])
    stale = committed - fresh
    for (file, rule, text), count in sorted(stale.items()):
        print(f"stale baseline entry ×{count}: {file} [{rule}] {text.strip()!r}")
    if stale:
        print(f"{sum(stale.values())} stale entries — regenerate .swiftlint-baseline.json")
        return 1
    print(f"SwiftLint baseline OK ({sum(committed.values())} entries, none stale).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
