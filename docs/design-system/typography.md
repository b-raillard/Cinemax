# Typography

Every font in the app flows through `CinemaFont`. Direct `.system(size:)` calls in views are a bug — they bypass the scale system and look wrong on tvOS.

Source: `Shared/DesignSystem/CinemaGlassTheme.swift` (§ `// MARK: - Typography`).

---

## The scale system

All sizes pass through `CinemaScale.pt(_:)` which applies two multipliers:

```swift
static var factor: CGFloat {
    let stored = UserDefaults.standard.object(forKey: "uiScale") as? Double ?? 1.0
    #if os(tvOS)
    return CGFloat(stored) * 1.4    // tvOS base multiplier — 10 m viewing distance
    #else
    return CGFloat(stored)           // iOS base = 1.0
    #endif
}
```

- **App UI scale**: user-controlled, 0.8 – 1.3 (`SettingsKey.uiScale`, default 1.0). Settings → Appearance → UI Scale. Persisted and bumps `ThemeManager._accentRevision` on write so views re-render.
- **tvOS base 1.4×**: baked into `CinemaScale.factor`. Rationale: base sizes are tuned for iPhone (~30 cm viewing distance); tvOS is ~3 m.

So a "body" font declared as `17 pt` renders as:

| Platform | User scale | Final size |
| --- | --- | --- |
| iPhone | 100 % | 17 pt |
| iPhone | 130 % | 22 pt |
| iPad (same) | 100 % | 17 pt |
| tvOS | 100 % | 24 pt (17 × 1.4) |
| tvOS | 130 % | 31 pt (17 × 1.4 × 1.3) |

---

## Fixed-size tokens

These return fixed `.system(size:)` fonts — scaled by app UI scale + tvOS multiplier, but **not** by the OS-level Dynamic Type preference. Use them when precise layout control matters (hero titles, display type, tightly-packed UI).

```swift
CinemaFont.display(.large)   // 56 pt heavy
CinemaFont.display(.medium)  // 45 pt heavy   ← default
CinemaFont.display(.small)   // 36 pt bold

CinemaFont.headline(.large)  // 32 pt bold
CinemaFont.headline(.medium) // 28 pt bold    ← default
CinemaFont.headline(.small)  // 24 pt semibold

CinemaFont.body              // 17 pt regular
CinemaFont.bodyLarge         // 19 pt regular

CinemaFont.label(.large)     // 19 pt medium
CinemaFont.label(.medium)    // 16 pt medium  ← default
CinemaFont.label(.small)     // 14 pt medium
```

---

## Dynamic-Type-aware tokens

These layer `UIFontMetrics` on top, so the final size is `baseSize × appScale × OS_DynamicType`. Use for **reading-heavy** surfaces where the user's OS accessibility preference should apply (settings rows, detail overviews, episode titles, list cells).

```swift
CinemaFont.dynamicBody           // 17 pt + UIFontMetrics(.body)
CinemaFont.dynamicBodyLarge      // 19 pt + UIFontMetrics(.body)

CinemaFont.dynamicLabel(.large)  // 19 pt + UIFontMetrics(.callout)
CinemaFont.dynamicLabel(.medium) // 16 pt + UIFontMetrics(.subheadline)
CinemaFont.dynamicLabel(.small)  // 14 pt + UIFontMetrics(.footnote)
```

**Don't use dynamic variants for hero/display/headline titles** — they can overflow into backdrops and break grid alignment. The hard cap is enforced at the app root:

```swift
// AppNavigation
.dynamicTypeSize(.xSmall ... .accessibility2)
```

---

## Picking a font

```text
Is this a one-word display heading on a hero / landing? ───────────→ display(.medium or .large)

Is this a screen / section title? ─────────────────────────────────→ headline(.medium)

Is this reading-heavy body text (detail overview, license page,
 settings descriptions, episode synopsis)? ────────────────────────→ dynamicBody or dynamicBodyLarge

Is this a one-line fixed piece of body copy (metadata, inline
 status, single-line card title)? ─────────────────────────────────→ body or bodyLarge

Is this a control label, row title, button text, tag? ─────────────→ label(.medium)  (or dynamic variant if reading-heavy)

Is this a small uppercase section header / tracking label? ────────→ label(.small) with .tracking(1.2)
```

---

## Editorial details

### Tracking

Headlines and display titles are heavy + tracked tight:

```swift
Text(title)
    .font(CinemaFont.display(.large))
    .tracking(-0.3)           // slightly condensed
```

Uppercase section labels go the other way:

```swift
Text("STUDIO")
    .font(CinemaFont.label(.small))
    .tracking(1.2)
```

### Weights

We deliberately under-use `semibold` and over-use `heavy` / `bold` / `medium`:

- `heavy` — display type only
- `bold` — headlines, buttons, emphasis
- `medium` — labels, metadata, buttons on iOS
- `regular` — body

Avoid `.light`/`.thin`/`.ultraLight`. They do not read on dark backdrops and look weak on tvOS.

### `CinemaButton` hardcoded exceptions

The Play / Lecture primary button text size is hardcoded (not `CinemaFont`-routed):

- tvOS: `28 pt` bold — explicitly sized to match the transport bar presence of AVPlayerViewController
- iOS: `18 pt` bold

Both wrap through `CinemaScale.factor` indirectly — they live in `CinemaButton.fontSize`. Don't generalise this back into `CinemaFont.body` without understanding the tvOS focus target.

---

## What to avoid

- `Font.system(size: 14)` — literal size. Use `label(.small)` or `dynamicLabel(.small)`.
- `.font(.body)` / `.font(.title)` — SwiftUI system fonts. They don't flow through our scale.
- `UIFont.systemFont(ofSize: …)` — UIKit literals. Same reason.
- `.minimumScaleFactor(0.5)` anywhere a display/headline font is used — it hides the UI-scale regression rather than fixing the layout.

---

## Localization effect on typography

French is the default locale (`fr.lproj`). French strings are on average ~25 % longer than English equivalents. Screen layouts must accommodate this — don't `.lineLimit(1)` button titles unless you know the French string fits at 130 % UI scale. `CinemaButton` uses `.minimumScaleFactor(0.7)` as a safety net.
