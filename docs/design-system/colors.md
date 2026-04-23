# Colors

All colour comes from three sources — and only three:

1. **`CinemaColor.*`** — surfaces, text, error, success. Neutral. Never imported from a hex literal inside a view.
2. **`themeManager.accent` / `.accentContainer` / `.accentDim` / `.onAccent`** — the user's chosen accent. Dynamic.
3. **`.white` / `.black`** — only inside the video player (always-dark chrome) and on saturated `accentContainer` fills.

Anything else is a bug. See [conventions.md](./conventions.md).

---

## How dark / light mode works

The app does not branch on `colorScheme` in views. Instead:

```swift
// In ThemeManager
static func dynamic(light: UInt, dark: UInt) -> Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(hexInt: light)
            : UIColor(hexInt: dark)
    })
}
```

Every `CinemaColor` and every accent slot is a `Color.dynamic(light:dark:)` backed by a `UIColor(dynamicProvider:)`. The colour *resolves* against the active `UITraitCollection` at render time, so flipping mode is a trait-change, not a view reload.

The mode itself is driven at the app root only:

```swift
// AppNavigation — the ONE place .preferredColorScheme is set
.preferredColorScheme(themeManager.colorScheme)
```

**Never set `.preferredColorScheme` anywhere else.** It breaks the trait-collection propagation.

**Always route mode changes through the manager:**

```swift
themeManager.darkModeEnabled = true   // ✅ bumps _accentRevision → views re-render
@AppStorage("darkMode") var d = true  // ❌ bypasses the revision counter
```

Same rule for `themeManager.accentColorKey`.

### tvOS focus caveat

A focused `Button` on tvOS overrides the `UITraitCollection` inside its label — every `Color.dynamic` token inside a focused button flips to its *light-mode* value, even in dark mode. The workaround lives in `tvSettingsFocusable(…, colorScheme:)`, which injects `.environment(\.colorScheme, colorScheme)` on both the label and the background shape. **Always pass `colorScheme: themeManager.darkModeEnabled ? .dark : .light`.**

---

## `CinemaColor` — neutral palette

All values `Color.dynamic(light: 0xRRGGBB, dark: 0xRRGGBB)`. Source: `Shared/DesignSystem/CinemaGlassTheme.swift`.

### Surfaces — tonal hierarchy (no borders; depth comes from these)

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `surface` | `#F7F7F8` | `#0E0E0E` | App background |
| `surfaceContainerLowest` | `#FFFFFF` | `#000000` | Rare — video player backdrop fade |
| `surfaceContainerLow` | `#F1F1F2` | `#131313` | Sections sitting on `surface` |
| `surfaceContainer` | `#EAEAEC` | `#191A1A` | Default card/panel fill |
| `surfaceContainerHigh` | `#E2E2E5` | `#1F2020` | Elevated card, icon-badge bg |
| `surfaceContainerHighest` | `#D9D9DD` | `#252626` | Top-of-stack element |
| `surfaceVariant` | `#E2E2E5` | `#252626` | Glass-panel overlay tint |
| `surfaceBright` | `#FFFFFF` | `#2C2C2C` | Highlighted surface, rare |

```text
Tonal hierarchy (dark mode):
┌──────────────────────────────────────────────┐  surface #0E0E0E  (page)
│                                              │
│  ┌────────────────────────────────────────┐  │  surfaceContainerLow #131313
│  │                                        │  │
│  │  ┌──────────────────────────────────┐  │  │  surfaceContainer #191A1A
│  │  │                                  │  │  │
│  │  │  ┌────────────────────────────┐  │  │  │  surfaceContainerHigh #1F2020
│  │  │  │  Icon · 3F3F40 bg badge    │  │  │  │  surfaceContainerHighest #252626
│  │  │  └────────────────────────────┘  │  │  │
│  │  └──────────────────────────────────┘  │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘
```

### Text — on top of surfaces

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `onSurface` | `#14161A` | `#E7E5E4` | Primary text |
| `onSurfaceVariant` | `#55585E` | `#ACABAA` | Secondary text, labels, metadata |
| `onBackground` | `#14161A` | `#E7E5E4` | Text on full-bleed surfaces |

### Primary / Secondary — neutral action greys

Used by `CinemaButton(style: .primary)` and the few places that need a high-contrast-but-colorless button.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `primary` | `#3A3B3D` | `#C6C6C7` | `CinemaGradient.primaryButton` start |
| `primaryDim` | `#4A4B4D` | `#B8B9B9` | Dimmed primary, unused at time of writing |
| `primaryContainer` | `#D0D1D4` | `#454747` | `CinemaGradient.primaryButton` end |
| `onPrimary` | `#FFFFFF` | `#3F4041` | Text on primary button |
| `secondary` | `#55585E` | `#9D9E9E` | Secondary label, rarely direct |
| `secondaryContainer` | `#C8CACE` | `#3A3C3C` | Secondary button backgrounds |

### Tertiary — **legacy, do not use for new code**

Kept only for lingering call sites that haven't been migrated to `ThemeManager`. **Always use `themeManager.accent` / `.accentContainer` / `.accentDim` / `.onAccent` instead.**

| Token | Note |
| --- | --- |
| `tertiary`, `tertiaryContainer`, `tertiaryDim`, `onTertiary` | Blue-flavoured. Migrate on sight. |

### Outline — subtle separators (avoid on new designs)

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `outline` | `#B0B1B5` | `#767575` | Ghost-button 1 pt stroke only |
| `outlineVariant` | `#CFD0D3` | `#484848` | Barely-visible separator |

Don't reach for these to build hierarchy. Use tonal surface shifts.

### Semantic — status

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `error` | `#C0392B` | `#EE7D77` | Error text, destructive icon |
| `errorContainer` | `#FADBD8` | `#7F2927` | Error toast / badge background |
| `onErrorContainer` | `#7B1A12` | `#FF9993` | Text on `errorContainer` |
| `success` | `#1F9D45` | `#34C759` | Success icon, connected-status dot |

### Other

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `surfaceTint` | `#3A3B3D` | `#C6C6C7` | Shadow colour for elevated surfaces |

---

## Accent system

The accent is the only piece of chromatic colour in the app. The user picks one of ten options (nine visible + rainbow easter egg) in Settings → Appearance. The choice re-skins every accent-using view instantly via `ThemeManager._accentRevision`.

### API

Always read through `ThemeManager`, never from `AccentOption` directly in a view:

```swift
@Environment(ThemeManager.self) private var themeManager

// In body:
.foregroundStyle(themeManager.accent)              // text, icons, active indicators
.background(themeManager.accentContainer)          // filled buttons, selection fills
Color(themeManager.accentDim)                      // hover/pressed states
.foregroundStyle(themeManager.onAccent)            // text on accentContainer
```

Four slots per accent:

| Slot | Role |
| --- | --- |
| `accent` | Text, icons, active nav indicator, focus stroke, progress bar fill |
| `accentContainer` | Filled primary action button backgrounds (e.g. `CinemaButton(style: .accent)`), selected-chip fill, rating pill fill |
| `accentDim` | Hover / pressed states of accent-coloured UI |
| `onAccent` | Text / icon placed directly on an `accentContainer` fill. White in light mode (containers are saturated), near-black in dark mode |

### Accent palettes

All ten live in `AccentOption.palette` (`Shared/DesignSystem/AccentOption.swift`). Default is **green** (`SettingsKey.Default.accentColor = "green"`).

```text
┌─────────┬───────────┬───────────┬──────────────┬──────────────┬───────────┬───────────┬────────────┬────────────┐
│ Accent  │ accentLT  │ accentDK  │ containerLT  │ containerDK  │ dimLT     │ dimDK     │ onAccentLT │ onAccentDK │
├─────────┼───────────┼───────────┼──────────────┼──────────────┼───────────┼───────────┼────────────┼────────────┤
│ red     │ #C1272D   │ #FF6B6B   │ #E53935      │ #E53935      │ #8C1C20   │ #CC2C30   │ #FFFFFF    │ #3D0000    │
│ orange  │ #CC5A0A   │ #FF8C42   │ #E06A1A      │ #E06A1A      │ #A84508   │ #CC5500   │ #FFFFFF    │ #3D1500    │
│ yellow  │ #8A5A00   │ #FFC940   │ #D19500      │ #D19500      │ #6B4500   │ #B37B00   │ #FFFFFF    │ #2B1F00    │
│ green ★ │ #1F7A50   │ #4CAF82   │ #2E8A5E      │ #2E8A5E      │ #155F3E   │ #1F7A50   │ #FFFFFF    │ #001A0D    │
│ cyan    │ #0E8F84   │ #2DD4BF   │ #0BAEA0      │ #0BAEA0      │ #08756B   │ #009A8C   │ #FFFFFF    │ #001A18    │
│ blue    │ #0060D6   │ #679CFF   │ #007AFF      │ #007AFF      │ #0050B8   │ #0070EB   │ #FFFFFF    │ #001F4A    │
│ indigo  │ #3730A3   │ #818CF8   │ #4F46E5      │ #4F46E5      │ #262183   │ #3B3FB5   │ #FFFFFF    │ #0A0A2B    │
│ purple  │ #7A2BD0   │ #BF7FFF   │ #8E3CE0      │ #9B57E0      │ #651FB0   │ #8B44CF   │ #FFFFFF    │ #1A0040    │
│ pink    │ #C2185B   │ #FF6BB5   │ #D63384      │ #E0458F      │ #A0144A   │ #CC3578   │ #FFFFFF    │ #3D001A    │
│ rainbow │ (animated HSB, see below)                                                                              │
└─────────┴───────────┴───────────┴──────────────┴──────────────┴───────────┴───────────┴────────────┴────────────┘
★ default
```

Light-mode `accent` values are deeper/more saturated than dark-mode values to maintain ≥4.5:1 contrast on the soft-grey `surface` background.

### Rainbow easter egg

Locked by default (`SettingsKey.Default.rainbowUnlocked = false`). Unlocked by tapping the Server-setup or Login logo block through a full cycle of the nine base accents (see `AccentEasterEgg.tap(…)` in `SettingsScreen.swift`).

When active:

- `ThemeManager.isRainbow == true`
- `accent` / `accentContainer` / `accentDim` return `Color(hue: _rainbowHue, saturation: _, brightness: _)` — HSB, not palette
- A `Task { @MainActor }` advances `_rainbowHue` by 0.006 every ~33 ms and bumps `_accentRevision`, so every view observing `ThemeManager` re-evaluates its accent reads against the new hue
- The task self-cancels the moment the user picks any static accent — zero cost outside easter-egg state
- `RainbowAccentSwatch` (conic gradient) is the preview dot in the picker

### Adding a new accent

1. Add a case to `AccentOption` with its `Palette`.
2. Decide whether it should appear in `cyclingCases` (and thus be reachable by the easter egg). Adding it there extends the unlock sequence by one tap.
3. No view code changes needed — `ThemeManager` picks it up.

---

## Gradients

Two defined in `CinemaGradient`:

- `primaryButton` — `[primary, primaryContainer]` topLeading → bottomTrailing. Used by `CinemaButton(style: .primary)`.
- `heroOverlay` — `[surface.opacity(0.4), surface]` top → bottom. Scrim that sits over backdrops so hero text stays legible.

Define new gradients here, never inline in views.
