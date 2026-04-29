---
name: design-system-review
description: Audit changed Swift files against Cinemax design-system rules from docs/design-system/conventions.md. Run before committing UI changes.
---

# design-system-review

The authoritative PR rejection checklist lives at `docs/design-system/conventions.md`. This skill runs that checklist as a grep sweep on either staged files or the whole `Shared/` tree.

## Read first

Before flagging anything, skim:
- `docs/design-system/conventions.md` — rejection rules
- `docs/design-system/colors.md` — accent / dynamic-color tokens
- `docs/design-system/components.md` — `CinemaToggleIndicator`, `CinemaButton`, etc.
- `CLAUDE.md` Design System section — summary

## Scope

Default scope: files changed vs `git diff --name-only HEAD` filtered to `*.swift` under `Shared/`. If the user passes a path, audit only that.

```bash
cd "$CLAUDE_PROJECT_DIR"
TARGETS=$(git diff --name-only HEAD -- 'Shared/**/*.swift' 2>/dev/null)
[ -z "$TARGETS" ] && TARGETS=$(git diff --name-only --cached -- 'Shared/**/*.swift')
[ -z "$TARGETS" ] && TARGETS=$(find Shared -name '*.swift')
```

## Rules to enforce

For each rule, run the grep, report `file:line — rule violated — suggested fix`.

### Color tokens

- **No `Color(hex:` in new code** — use `CinemaColor.*` or `Color.dynamic(light:dark:)`. Pre-existing tokens inside `CinemaGlassTheme.swift` are exempt.
  ```bash
  grep -nE 'Color\(hex:' $TARGETS | grep -v 'CinemaGlassTheme.swift'
  ```
- **No raw `.white` / `.black`** outside the video player and elements on saturated `accentContainer`. Else use `CinemaColor.onSurface` / `.onSurfaceVariant`.
  ```bash
  grep -nE '\.foregroundStyle\(\.white\)|\.foregroundStyle\(\.black\)|\.foregroundColor\(\.white\)|\.foregroundColor\(\.black\)' $TARGETS \
    | grep -vE 'VideoPlayer|NativeVideoPresenter|onAccent|accentContainer'
  ```
- **No `CinemaColor.tertiary*`** — use `themeManager.accent` / `.accentContainer` / `.accentDim` / `.onAccent`.
  ```bash
  grep -nE 'CinemaColor\.tertiary' $TARGETS
  ```

### Toggles

- **Never use system `Toggle` in settings or UI** — use `CinemaToggleIndicator`.
  ```bash
  grep -nE '^\s*Toggle\s*\(' $TARGETS | grep -v 'CinemaToggleIndicator'
  ```

### Borders

- **No 1px borders** — use color shifts or `.glassPanel()`.
  ```bash
  grep -nE '\.(border|strokeBorder|stroke)\([^)]*lineWidth:\s*1[^0-9]' $TARGETS \
    | grep -vE 'cinemaFocus|tvSettingsFocusable|TVFilterChipButtonStyle'
  ```

### Toolbar + Liquid Glass

- **Never `.buttonStyle(.glass)` / `.glassProminent` on `ToolbarItem`** — iOS 26 already wraps toolbar items in Liquid Glass; nesting double-capsules.
  ```bash
  awk '/ToolbarItem/{tb=1} tb && /buttonStyle\(\.(glass|glassProminent)/{print FILENAME ":" NR ": toolbar Liquid Glass nested"} /^}/{tb=0}' $TARGETS
  ```

### Direct AppStorage writes for theme

- **Never write `@AppStorage("darkMode")` / `@AppStorage("accentColor")` directly** — route through `themeManager.darkModeEnabled =` / `themeManager.accentColorKey =` (otherwise `_accentRevision` doesn't bump and reactivity breaks).
  ```bash
  grep -nE '@AppStorage\("(darkMode|accentColor)"\)' $TARGETS \
    | grep -v 'ThemeManager.swift'
  ```

### LazyImage usage

- **Never raw `LazyImage(...)`** — always `CinemaLazyImage`.
  ```bash
  grep -nE '\bLazyImage\(' $TARGETS | grep -v 'CinemaLazyImage'
  ```

### tvOS focus

- On tvOS code, `Button` inside settings rows should be wrapped with `.tvSettingsFocusable(...)` — flag bare `.focusable()` on settings rows.
- Hard-coded `1920` for backdrop sizing — use `ImageURLBuilder.screenPixelWidth`.
  ```bash
  grep -nE 'maxWidth:\s*1920|width:\s*1920' $TARGETS \
    | grep -vE 'ImageURLBuilder\.swift|//.*backdrop'
  ```

### Hardcoded text style

- New text in screens should use `CinemaFont.*` — flag raw `.font(.system(...))` outside `Shared/DesignSystem/`.
  ```bash
  grep -nE '\.font\(\.system\(' $TARGETS | grep -v 'Shared/DesignSystem/'
  ```

## Output format

```
## Design system review — N findings

### Color tokens
- Shared/.../X.swift:42 — raw .white outside player. Replace with CinemaColor.onSurface.

### Toggles
(no issues)

### ...
```

End with a one-line summary and a reminder: rules live in `docs/design-system/conventions.md` — when in doubt, read that file.

Do not modify files. Surface, don't fix.
