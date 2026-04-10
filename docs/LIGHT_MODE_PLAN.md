# Light Mode Implementation Plan

Goal: implement a working light theme for Cinemax. The toggle (`themeManager.darkModeEnabled`) and Settings UI already exist; today flipping it only switches `.preferredColorScheme()` but every color in the app is hardcoded dark. The job is to make `CinemaColor` (and a small set of stragglers) resolve dynamically against the current `ColorScheme` so the entire UI flips with one switch.

---

## 1. Current state

- `Shared/DesignSystem/CinemaGlassTheme.swift` — `enum CinemaColor` exposes ~20 static `let` colors with hardcoded dark hex values.
- `Shared/DesignSystem/ThemeManager.swift` — already has `darkModeEnabled` (`@AppStorage("darkMode")`, default `true`) and `colorScheme: ColorScheme?` returning `.dark` / `.light`.
- `Shared/Navigation/AppNavigation.swift:90` — applies `.preferredColorScheme(themeManager.colorScheme)` at the root. Good.
- `iOS/CinemaxApp.swift:8` and `tvOS/CinemaxTVApp.swift:8` — hardcode `.preferredColorScheme(.dark)` on `AppNavigation`. **This overrides the ThemeManager** and must be removed.
- `Shared/Screens/SettingsScreen+iOS.swift:478` and `SettingsScreen.swift:64` — toggle is already wired through `themeManager.darkModeEnabled`. Nothing to add on the Settings side.
- Accent colors (`themeManager.accent` / `accentContainer` / `accentDim` / `onAccent`) are currently identical in dark/light. Per the brief, the user wants them to look correct in both modes — see §4.

### Tokens currently in use across the codebase

```
CinemaColor.surface
CinemaColor.surfaceContainerLowest
CinemaColor.surfaceContainerLow
CinemaColor.surfaceContainerHigh
CinemaColor.surfaceContainerHighest
CinemaColor.surfaceVariant
CinemaColor.surfaceTint
CinemaColor.onSurface
CinemaColor.onSurfaceVariant
CinemaColor.primary
CinemaColor.primaryContainer
CinemaColor.onPrimary
CinemaColor.outline
CinemaColor.outlineVariant
CinemaColor.error
CinemaColor.errorContainer
CinemaColor.success
CinemaColor.tertiary  ← legacy, still referenced in a few places, must also flip
```

(`surfaceContainer` and `surfaceBright` are declared but unused — leave them in but give them light variants too for completeness.)

### Other absolute color references that will leak in light mode

These are NOT covered by `CinemaColor` and need targeted fixes — see §3.4:

- `Shared/Screens/MovieLibraryScreen.swift:582` — `Color.white.opacity(0.25)`
- `Shared/Screens/MediaDetailScreen.swift:374` — `ProgressBarView(... trackColor: Color.white.opacity(0.25))`
- `Shared/Screens/SettingsScreen+iOS.swift:83, 102, 122` — `Color.white.opacity(...)`
- `Shared/Screens/SettingsScreen+tvOS.swift:110, 130, 136` — `Color.white.opacity(...)`
- `Shared/Screens/VideoPlayerView.swift:49` — `Color.black.ignoresSafeArea()` → **leave as-is**, video player must always be black regardless of theme.
- `Shared/Screens/TVControlsOverlay.swift` — `.black` shadows / fg colors → **leave as-is**, overlays are always on top of video.

---

## 2. Strategy (read this before coding)

**Use UIKit's dynamic color provider, not a SwiftUI computed property over `ThemeManager`.**

Why:
- `CinemaColor.surface` is referenced ~250+ times across the codebase. Converting every site to a computed accessor like `theme.surface` would touch every screen and many components.
- `UIColor(dynamicProvider:)` (and `NSColor(name:dynamicProvider:)` on macOS) automatically resolves against the `userInterfaceStyle` trait of the view it's drawn into. Since `AppNavigation` already calls `.preferredColorScheme(themeManager.colorScheme)` at the root, the trait propagates to every UIHostingController and the colors flip for free with no call-site changes.
- This is the same mechanism Apple uses for `UIColor.systemBackground` etc.

So: **`CinemaColor` stays an enum with the same property names**, but each `static let` becomes `static let` of a dynamic `Color` built from `UIColor(dynamicProvider:)`. Zero call-site changes for the surface/text/outline tokens.

Light/dark switch is then a single `.preferredColorScheme()` flip — already wired.

---

## 3. Implementation steps

### 3.1 — Add a dynamic color helper

In `CinemaGlassTheme.swift`, add this above `enum CinemaColor`:

```swift
import SwiftUI
import UIKit  // (already implicit on iOS/tvOS via SwiftUI)

extension Color {
    /// Resolves to `dark` when the trait collection is dark, otherwise `light`.
    /// Drives Cinemax's dual-mode color tokens. The current scheme is set at
    /// the root via `.preferredColorScheme(themeManager.colorScheme)` in
    /// AppNavigation, so this propagates app-wide automatically.
    static func dynamic(light: UInt, dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            switch traits.userInterfaceStyle {
            case .light: return UIColor(hexInt: light)
            default:     return UIColor(hexInt: dark)
            }
        })
    }
}

private extension UIColor {
    convenience init(hexInt: UInt, alpha: CGFloat = 1.0) {
        self.init(
            red:   CGFloat((hexInt >> 16) & 0xFF) / 255.0,
            green: CGFloat((hexInt >>  8) & 0xFF) / 255.0,
            blue:  CGFloat( hexInt        & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}
```

Notes:
- Both iOS and tvOS support `UIColor { traits in ... }` (iOS 13+, tvOS 13+). No `#if os` needed.
- The existing `Color(hex:)` initializer in the same file stays untouched — it's still used by `ThemeManager` for accent palette swatches.

### 3.2 — Replace `CinemaColor` static lets with dynamic versions

Rewrite the body of `enum CinemaColor` so each token is `Color.dynamic(light: 0xXXXXXX, dark: 0xYYYYYY)`. Keep the property names exactly as they are. Use the palette in §4.

```swift
enum CinemaColor {
    // Surface hierarchy
    static let surface                  = Color.dynamic(light: 0xF7F7F8, dark: 0x0E0E0E)
    static let surfaceContainerLowest   = Color.dynamic(light: 0xFFFFFF, dark: 0x000000)
    static let surfaceContainerLow      = Color.dynamic(light: 0xF1F1F2, dark: 0x131313)
    static let surfaceContainer         = Color.dynamic(light: 0xEAEAEC, dark: 0x191A1A)
    static let surfaceContainerHigh     = Color.dynamic(light: 0xE2E2E5, dark: 0x1F2020)
    static let surfaceContainerHighest  = Color.dynamic(light: 0xD9D9DD, dark: 0x252626)
    static let surfaceVariant           = Color.dynamic(light: 0xE2E2E5, dark: 0x252626)
    static let surfaceBright            = Color.dynamic(light: 0xFFFFFF, dark: 0x2C2C2C)

    // Text
    static let onSurface         = Color.dynamic(light: 0x14161A, dark: 0xE7E5E4)
    static let onSurfaceVariant  = Color.dynamic(light: 0x55585E, dark: 0xACABAA)
    static let onBackground      = Color.dynamic(light: 0x14161A, dark: 0xE7E5E4)

    // Primary (used for muted button gradients & on-primary text)
    static let primary           = Color.dynamic(light: 0x3A3B3D, dark: 0xC6C6C7)
    static let primaryDim        = Color.dynamic(light: 0x4A4B4D, dark: 0xB8B9B9)
    static let primaryContainer  = Color.dynamic(light: 0xD0D1D4, dark: 0x454747)
    static let onPrimary         = Color.dynamic(light: 0xFFFFFF, dark: 0x3F4041)

    // Secondary
    static let secondary          = Color.dynamic(light: 0x55585E, dark: 0x9D9E9E)
    static let secondaryContainer = Color.dynamic(light: 0xC8CACE, dark: 0x3A3C3C)

    // Tertiary (legacy accent — kept for the few lingering call sites)
    static let tertiary          = Color.dynamic(light: 0x0060D6, dark: 0x679CFF)
    static let tertiaryContainer = Color.dynamic(light: 0x007AFF, dark: 0x007AFF)
    static let tertiaryDim       = Color.dynamic(light: 0x0050B8, dark: 0x0070EB)
    static let onTertiary        = Color.dynamic(light: 0xFFFFFF, dark: 0x001F4A)

    // Outline
    static let outline        = Color.dynamic(light: 0xB0B1B5, dark: 0x767575)
    static let outlineVariant = Color.dynamic(light: 0xCFD0D3, dark: 0x484848)

    // Error
    static let error            = Color.dynamic(light: 0xC0392B, dark: 0xEE7D77)
    static let errorContainer   = Color.dynamic(light: 0xFADBD8, dark: 0x7F2927)
    static let onErrorContainer = Color.dynamic(light: 0x7B1A12, dark: 0xFF9993)

    // Success
    static let success = Color.dynamic(light: 0x1F9D45, dark: 0x34C759)

    // Surface tint
    static let surfaceTint = Color.dynamic(light: 0x3A3B3D, dark: 0xC6C6C7)
}
```

### 3.3 — Remove the hardcoded `.preferredColorScheme(.dark)` overrides

These currently force the entire app to dark, defeating `themeManager.colorScheme`:

- `iOS/CinemaxApp.swift:8` — delete the `.preferredColorScheme(.dark)` modifier on `AppNavigation()`.
- `tvOS/CinemaxTVApp.swift:8` — same.

Result:
```swift
// iOS/CinemaxApp.swift
WindowGroup {
    AppNavigation()
}
```

Do **not** add a replacement here — `AppNavigation` already applies `.preferredColorScheme(themeManager.colorScheme)` itself.

### 3.4 — Fix the absolute `Color.white` / opacity leaks

These bypass the token system. Replace each with a dynamic equivalent. The pattern: anywhere `Color.white.opacity(x)` was used to mean "dim foreground accent on a dark surface", switch to a token that flips correctly.

| File | Line | Current | Replace with |
|---|---|---|---|
| `Shared/Screens/MovieLibraryScreen.swift` | 582 | `Color.white.opacity(0.25)` | `CinemaColor.onSurface.opacity(0.25)` |
| `Shared/Screens/MediaDetailScreen.swift` | 374 | `trackColor: Color.white.opacity(0.25)` | `trackColor: CinemaColor.onSurface.opacity(0.25)` |
| `Shared/Screens/SettingsScreen+iOS.swift` | 83 | `isFirst ? Color.white.opacity(0.2) : CinemaColor.surfaceContainerHighest` | `isFirst ? themeManager.accent.opacity(0.18) : CinemaColor.surfaceContainerHighest` |
| `Shared/Screens/SettingsScreen+iOS.swift` | 102 | `isFirst ? Color.white.opacity(0.8) : ...` | `isFirst ? CinemaColor.onSurface.opacity(0.85) : CinemaColor.onSurfaceVariant.opacity(0.6)` |
| `Shared/Screens/SettingsScreen+iOS.swift` | 122 | `Color.white.opacity(isFirst ? 0.1 : 0.05)` | `CinemaColor.onSurface.opacity(isFirst ? 0.12 : 0.06)` |
| `Shared/Screens/SettingsScreen+tvOS.swift` | 110 | `isFocused ? Color.white.opacity(0.2) : CinemaColor.surfaceContainerHighest` | `isFocused ? themeManager.accent.opacity(0.18) : CinemaColor.surfaceContainerHighest` |
| `Shared/Screens/SettingsScreen+tvOS.swift` | 130, 136 | `Color.white.opacity(0.7)` | `CinemaColor.onSurface.opacity(0.7)` |

**Do NOT touch**:
- `Shared/Screens/VideoPlayerView.swift:49` — the player background must remain `Color.black`.
- `Shared/Screens/TVControlsOverlay.swift` — all `.black` shadows / `.white` foregrounds. The tvOS player overlay sits on top of video and must stay light-on-dark in both themes.
- `Shared/Screens/TVCustomPlayerView.swift` and any other player overlay code — same rule.

### 3.5 — Glass material in light mode

`Shared/DesignSystem/GlassModifiers.swift` uses `.ultraThinMaterial` overlaid with `CinemaColor.surfaceVariant.opacity(0.6)`. `.ultraThinMaterial` is itself trait-aware (it lightens in light mode), and `surfaceVariant` is now dynamic, so this **should just work**. Verify visually after the migration; if the panel is too washed out in light mode, lower the overlay opacity to `0.4` for light specifically. Prefer to leave it alone unless it actually looks wrong.

### 3.6 — Accent palette tweaks for light mode

`themeManager.accent` / `accentContainer` / `accentDim` / `onAccent` currently return single colors regardless of scheme. The blue/purple/etc. variants are tuned for dark backgrounds — on white they're too bright and `onAccent` (very dark) becomes invisible against white surfaces.

Convert each accent computed property in `Shared/DesignSystem/ThemeManager.swift` to use `Color.dynamic(light:dark:)` with the palette in §4. **Do NOT** change the `accentColorKey` switch structure — just swap each `Color(hex: 0x...)` for `Color.dynamic(light: 0x..., dark: 0x...)`.

Example for `accent`:
```swift
var accent: Color {
    _ = _accentRevision
    return switch accentColorKey {
    case "purple": Color.dynamic(light: 0x7A2BD0, dark: 0xBF7FFF)
    case "pink":   Color.dynamic(light: 0xC2185B, dark: 0xFF6BB5)
    case "orange": Color.dynamic(light: 0xCC5A0A, dark: 0xFF8C42)
    case "green":  Color.dynamic(light: 0x1F7A50, dark: 0x4CAF82)
    case "cyan":   Color.dynamic(light: 0x0E8F84, dark: 0x2DD4BF)
    default:       Color.dynamic(light: 0x0060D6, dark: 0x679CFF) // blue
    }
}
```

Apply the same pattern to `accentContainer`, `accentDim`, `onAccent` using §4.

Important: after switching to `Color.dynamic`, the `_ = _accentRevision` read at the top of each computed property still must stay — it's what re-renders observers when the user picks a different accent color from the same palette.

### 3.7 — Verify launch screen / focus rings

- `Shared/Navigation/AppNavigation.swift:99` — `CinemaColor.surface.ignoresSafeArea()` in `launchScreen`. Already a token, will flip for free.
- `Shared/DesignSystem/FocusScaleModifier.swift:33` — uses `.shadow(...)`. If the shadow is hardcoded `.black`, change to `.black.opacity(0.4)` (already invisible in light mode) or leave alone — verify visually.
- `Shared/DesignSystem/Components/CinemaButton.swift:111` — same check.

---

## 4. Color palette (light vs dark)

Design intent: light mode is **soft cool grey, not pure white**. Pure white is fatiguing for a media app and clashes with cinema-focused content. Background `#F7F7F8` (Apple `systemGroupedBackground`-like). Surface containers step **darker** as the hierarchy goes up (opposite of dark mode). Text is near-black `#14161A`, not pure black, to keep contrast comfortable.

### Surface ramp

| Token | Light | Dark |
|---|---|---|
| `surface` | `#F7F7F8` | `#0E0E0E` |
| `surfaceContainerLowest` | `#FFFFFF` | `#000000` |
| `surfaceContainerLow` | `#F1F1F2` | `#131313` |
| `surfaceContainer` | `#EAEAEC` | `#191A1A` |
| `surfaceContainerHigh` | `#E2E2E5` | `#1F2020` |
| `surfaceContainerHighest` | `#D9D9DD` | `#252626` |
| `surfaceVariant` | `#E2E2E5` | `#252626` |
| `surfaceBright` | `#FFFFFF` | `#2C2C2C` |

### Text / on-surface

| Token | Light | Dark |
|---|---|---|
| `onSurface` | `#14161A` | `#E7E5E4` |
| `onSurfaceVariant` | `#55585E` | `#ACABAA` |
| `onBackground` | `#14161A` | `#E7E5E4` |

### Primary / secondary

| Token | Light | Dark |
|---|---|---|
| `primary` | `#3A3B3D` | `#C6C6C7` |
| `primaryDim` | `#4A4B4D` | `#B8B9B9` |
| `primaryContainer` | `#D0D1D4` | `#454747` |
| `onPrimary` | `#FFFFFF` | `#3F4041` |
| `secondary` | `#55585E` | `#9D9E9E` |
| `secondaryContainer` | `#C8CACE` | `#3A3C3C` |

### Outline / status

| Token | Light | Dark |
|---|---|---|
| `outline` | `#B0B1B5` | `#767575` |
| `outlineVariant` | `#CFD0D3` | `#484848` |
| `error` | `#C0392B` | `#EE7D77` |
| `errorContainer` | `#FADBD8` | `#7F2927` |
| `onErrorContainer` | `#7B1A12` | `#FF9993` |
| `success` | `#1F9D45` | `#34C759` |
| `surfaceTint` | `#3A3B3D` | `#C6C6C7` |

### Accents (per `accentColorKey`, all four sub-tokens)

| Key | Sub-token | Light | Dark |
|---|---|---|---|
| **blue** (default) | `accent` | `#0060D6` | `#679CFF` |
|  | `accentContainer` | `#007AFF` | `#007AFF` |
|  | `accentDim` | `#0050B8` | `#0070EB` |
|  | `onAccent` | `#FFFFFF` | `#001F4A` |
| **purple** | `accent` | `#7A2BD0` | `#BF7FFF` |
|  | `accentContainer` | `#8E3CE0` | `#9B57E0` |
|  | `accentDim` | `#651FB0` | `#8B44CF` |
|  | `onAccent` | `#FFFFFF` | `#1A0040` |
| **pink** | `accent` | `#C2185B` | `#FF6BB5` |
|  | `accentContainer` | `#D63384` | `#E0458F` |
|  | `accentDim` | `#A0144A` | `#CC3578` |
|  | `onAccent` | `#FFFFFF` | `#3D001A` |
| **orange** | `accent` | `#CC5A0A` | `#FF8C42` |
|  | `accentContainer` | `#E06A1A` | `#E06A1A` |
|  | `accentDim` | `#A84508` | `#CC5500` |
|  | `onAccent` | `#FFFFFF` | `#3D1500` |
| **green** | `accent` | `#1F7A50` | `#4CAF82` |
|  | `accentContainer` | `#2E8A5E` | `#2E8A5E` |
|  | `accentDim` | `#155F3E` | `#1F7A50` |
|  | `onAccent` | `#FFFFFF` | `#001A0D` |
| **cyan** | `accent` | `#0E8F84` | `#2DD4BF` |
|  | `accentContainer` | `#0BAEA0` | `#0BAEA0` |
|  | `accentDim` | `#08756B` | `#009A8C` |
|  | `onAccent` | `#FFFFFF` | `#001A18` |

Rationale:
- Light-mode `accent` is the deepest readable form so it can serve as button text / icon on a white surface (≥4.5:1 contrast against `#F7F7F8`).
- Light-mode `onAccent` is always pure white because every light `accentContainer` is dark/saturated enough to host white text. Dark-mode `onAccent` keeps the original near-black so light text/icons aren't needed inside the bright dark-mode containers.
- `accentContainer` is intentionally similar in both modes for some keys — these are saturated mid-tones that work on either background, which keeps "filled accent button" recognizable when toggling themes.

---

## 5. Things to double-check after the swap

1. **Build both targets**:
   ```bash
   xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
   xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
   ```
2. **Toggle the switch live** in Settings → Appearance and confirm:
   - Home screen hero, rows, tabs flip without restart.
   - MediaDetail (movie + series), MovieLibrary (browse + filtered grid), Search, Settings (both landing and detail pages) all flip.
   - Accent color picker swatches still look right; selecting a different accent in light mode should still re-render.
   - Login + Server setup screens.
3. **Player stays dark** in both modes — `VideoPlayerView` (iOS) and `TVPlayerHostViewController` overlay (tvOS) must remain black-background / white text. This is intentional and matches every other media app.
4. **Glass panels** (`.glassPanel()`) — verify the `surfaceVariant` overlay isn't too opaque in light mode. If it is, drop the overlay opacity. Don't restructure the modifier.
5. **Focus rings on tvOS** — the 2px accent `strokeBorder` indicator should still be readable in light mode; the new lighter accents are tuned for this.
6. **Status bar / nav bar** on iOS — `.preferredColorScheme()` at the root automatically updates the status bar style. No `UIStatusBarStyle` overrides exist in the project.

---

## 6. Out of scope (do NOT do these)

- Do not introduce a `Theme` struct, environment key, or computed `theme.surface` accessor. The `CinemaColor` enum stays an enum.
- Do not migrate call sites from `CinemaColor.X` to `themeManager.X`. The whole point of the dynamic-provider strategy is zero call-site churn.
- Do not add a `system` (auto / matches OS) option. The toggle is binary today and should stay binary — adding a third state means changing `_darkModeEnabled: Bool` and the Settings UI, which is not part of this task.
- Do not touch the video player overlays or `Color.black` background — they are intentional.
- Do not add per-screen `if themeManager.darkModeEnabled` branches. If a color needs to differ, it should differ inside `CinemaColor` via `Color.dynamic`, not at the call site.

---

## 7. Suggested commit slicing

1. `feat(theme): add Color.dynamic helper and convert CinemaColor tokens to dual-mode` (steps 3.1 + 3.2)
2. `fix(theme): drop hardcoded .preferredColorScheme(.dark) at app root` (3.3)
3. `fix(theme): replace Color.white leaks with onSurface tokens` (3.4)
4. `feat(theme): dual-mode accent palette in ThemeManager` (3.6)
5. (only if needed after visual QA) `tweak(theme): glass panel overlay opacity in light mode` (3.5)

Each commit compiles and runs on its own; commits 1+3 alone should already produce a usable light mode.
