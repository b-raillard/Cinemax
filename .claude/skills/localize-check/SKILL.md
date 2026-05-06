---
name: localize-check
description: Verify FR/EN Localizable.strings parity and flag hardcoded user-facing strings in Shared/Screens. Run before commits or App Store submission.
---

# localize-check

Cinemax ships in French (default) and English. Every user-facing string must go through `loc.localized("key")`; both `.lproj` files must hold the same set of keys.

## What it does

1. Diff keys in `Resources/fr.lproj/Localizable.strings` vs `Resources/en.lproj/Localizable.strings` — report missing keys on either side.
2. Grep `Shared/` for likely hardcoded strings — `Text("…")`, `.navigationTitle("…")`, `Label("…", …)`, `Button("…")`, etc. — and flag any whose argument is a string literal rather than `loc.localized(...)`.
3. Surface the offending file:line so the author can either localize or justify (e.g. accent names, debug-only strings).

## How to run it

Execute these checks via Bash. The skill is read-only — output a list of findings, do not auto-fix.

### 1. Key-parity diff

```bash
cd "$CLAUDE_PROJECT_DIR"

extract_keys() {
  grep -oE '^"[^"]+"' "$1" | sort -u
}

diff <(extract_keys Resources/fr.lproj/Localizable.strings) \
     <(extract_keys Resources/en.lproj/Localizable.strings) \
  | awk '/^</ {print "Only in FR: " $2} /^>/ {print "Only in EN: " $2}'
```

### 2. Hardcoded-string sweep

Skim `Shared/` (skip `Shared/DesignSystem/Components/` test fixtures, accent names, debug-only labels) for SwiftUI APIs that take user-facing text:

```bash
grep -rEn --include='*.swift' \
  '\b(Text|Label|Button|navigationTitle|navigationBarTitle|alert|confirmationDialog|toolbarTitle)\(\s*"[^"%@\\][^"]+"' \
  Shared/ \
  | grep -v 'localized' \
  | grep -vE '#if DEBUG|//\s*MARK|loc\.localized'
```

False positives to ignore: SF Symbol names (in `Image(systemName:)` — not matched above), one-letter strings, format placeholders, and the rainbow easter-egg accent strings inside `AccentEasterEgg` / `RainbowAccentSwatch`.

### 3. Plural / arg-form sanity

If a key takes arguments (e.g. `loc.remainingTime(minutes:)`), verify it has a helper in `LocalizationManager` and that both FR and EN translations contain matching `%d` / `%@` placeholders.

## Output format

Print three sections — `## Key parity`, `## Hardcoded strings`, `## Argument mismatches` — each with file:line lines. End with a one-line summary: total findings.

Do not modify files. Author decides whether to fix each finding.
