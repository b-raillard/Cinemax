# Cinemax Design System — "Cinema Glass"

Canonical reference for the visual language of Cinemax. This document is the single source of truth for colors, typography, spacing, components, and platform conventions. If the code disagrees with this doc, one of them is wrong — fix the delta, don't silently diverge.

> **Audience**: future Claude sessions and engineers adding or refactoring UI. Designers may also read the foundations (colors, typography, spacing).

## Identity

**Cinema Glass** is a dark-first, editorially-styled, glassmorphic design language for a premium Jellyfin client on Apple platforms. Four non-negotiable principles:

1. **No borders.** Surface hierarchy comes from tonal contrast (`surface` → `surfaceContainer` → `surfaceContainerHigh`), never from 1 px strokes. The only accepted strokes are (a) 2 pt accent focus rings on tvOS, (b) 1 pt outlines on ghost buttons, (c) 1.5 pt tvOS settings-row focus borders.
2. **Full-bleed imagery, editorial typography.** Backdrops run edge-to-edge; titles are heavy, tracked, and layered on gradient scrims. Layouts favour hero + rows over evenly-spaced grids.
3. **Dynamic accent, neutral surfaces.** Everything is a grey; only the user's chosen accent adds colour. Accent re-skins the entire app instantly via `ThemeManager`.
4. **Same language on every device.** iOS (iPhone + iPad) and tvOS share the same tokens, components, and patterns. Platform differences are layout-level, not style-level.

## Platforms

| Platform | Minimum | Navigation shell | Input |
| --- | --- | --- | --- |
| iOS (iPhone) | iOS 26 | Bottom `TabView` | Touch |
| iOS (iPad) | iOS 26 | `NavigationSplitView` sidebar | Touch + pointer (hover) |
| tvOS | tvOS 26 | Top tab bar in `TabView` | Siri Remote (focus engine) |

Shared code is the default; platform branches only where behaviour genuinely differs (focus effects, modal presentation, font sizing). See [platforms.md](./platforms.md).

## How the doc is organised

Foundations → components → patterns → platforms → conventions. Read in order for a full walkthrough, or jump to a topic.

- [colors.md](./colors.md) — every token, the accent system, dark/light mode mechanics
- [typography.md](./typography.md) — `CinemaFont`, scaling, Dynamic Type
- [spacing-layout.md](./spacing-layout.md) — spacing, radii, adaptive grids
- [motion.md](./motion.md) — animations, focus, the motion-effects flag
- [components.md](./components.md) — full component catalogue with signatures
- [patterns.md](./patterns.md) — glass panels, settings rows, navigation, toasts, empty states
- [platforms.md](./platforms.md) — iOS / iPad / tvOS differences
- [conventions.md](./conventions.md) — do's, don'ts, and load-bearing rules you must not break

## Quick lookup

| I need to… | Go to |
| --- | --- |
| …find the hex for our accent red | [colors.md § Accent palettes](./colors.md#accent-palettes) |
| …pick a font for a new screen | [typography.md § When to use which](./typography.md#picking-a-font) |
| …size an image card | [spacing-layout.md § Adaptive layout](./spacing-layout.md#adaptive-layout-ios) |
| …build a list with a toggle | [patterns.md § Settings rows](./patterns.md#settings-rows) |
| …show feedback after an action | [patterns.md § Toasts vs alerts](./patterns.md#toasts-vs-alerts) |
| …make a button focusable on tvOS | [motion.md § Focus](./motion.md#focus) |
| …understand why `.tint(themeManager.accent)` instead of `.glassProminent` | [conventions.md § Toolbar buttons](./conventions.md#toolbar-buttons-ios-26) |

## One-paragraph tour for a new contributor

Every colour is a `CinemaColor` token or `themeManager.accent` — never a hex literal. Every font size passes through `CinemaFont` so the user's 80–130 % UI scale and the tvOS 1.4× base multiplier apply automatically. Every spacing/radius value is a `CinemaSpacing` / `CinemaRadius` token. Interactive surfaces use `.cinemaFocus()` on iOS and `CinemaTVCardButtonStyle` / `CinemaTVButtonStyle` on tvOS — the focus indicator is an accent stroke, never a scale bump alone and never a white background. Dark / light mode flips via `UITraitCollection` (driven by `themeManager.darkModeEnabled` at the app root) — no per-view `colorScheme` logic. Toggles are `CinemaToggleIndicator` wrapped in a `Button`, never system `Toggle`. When you reach for a border, reach for a tonal shift instead.
