# Spacing & Layout

Spacing, corner radii, and adaptive grid metrics. Source: `Shared/DesignSystem/CinemaGlassTheme.swift` and `Shared/DesignSystem/AdaptiveLayout.swift`.

---

## Spacing scale

Non-linear 4-pt-ish scale — tuned by eye rather than mathematically. Use these tokens exclusively; literal `.padding(14)` is a bug waiting to drift.

| Token | Value | Typical use |
| --- | --- | --- |
| `CinemaSpacing.spacing1` | 4 | Icon / text gap, hair-line separators |
| `CinemaSpacing.spacing2` | 11 | Tight row, inline padding (~0.7 rem) |
| `CinemaSpacing.spacing3` | 16 | Default internal padding, card gap |
| `CinemaSpacing.spacing4` | 22 | Section spacing, button padding (~1.4 rem) |
| `CinemaSpacing.spacing5` | 28 | Group break |
| `CinemaSpacing.spacing6` | 32 | Large section break (~2 rem) |
| `CinemaSpacing.spacing8` | 44 | Hero/landing vertical rhythm |
| `CinemaSpacing.spacing10` | 56 | Very large, rare |
| `CinemaSpacing.spacing20` | 112 | Page horizontal margins (mainly tvOS, ~7 rem) |

```text
0    4    11    16    22    28    32    44    56              112
│    │    │     │     │     │     │     │     │                │
spc1 spc2 spc3  spc4  spc5  spc6  spc8  spc10 spc20
```

### Rules of thumb

- **Default card gap**: `spacing3` (16). Don't nest `spacing2` inside a `spacing3` container — it reads muddy.
- **Button vertical padding**: iOS `spacing2` (11), tvOS `spacing4` (22). Already baked into `CinemaButton`.
- **Screen horizontal padding**: driven by `AdaptiveLayout.horizontalPadding(for:)` (see below) on iOS. tvOS uses `spacing20` on landing-type screens and smaller on grids.
- **Between major sections in a scroll view**: `spacing6` (32) top-to-bottom.

---

## Corner radii

```swift
enum CinemaRadius {
    static let small: CGFloat = 4
    static let medium: CGFloat = 8
    static let large: CGFloat = 16
    static let extraLarge: CGFloat = 24
    static let full: CGFloat = 9999
}
```

| Token | Use |
| --- | --- |
| `small` (4) | Quality badges, rating pills, tight inline tags |
| `medium` (8) | Rare — icon badges in settings rows (used with fill) |
| `large` (16) | Default card radius. Buttons, `PosterCard`, `WideCard`, text fields, focus ring |
| `extraLarge` (24) | Glass panels, sheet content containers (`.glassPanel()` default) |
| `full` (9999) | Capsule — chips, progress bars, toggle indicator pills, decade/genre filter chips |

Pick the radius that matches the container's visual weight, not its height. A small pill chip is `.full`, not `.medium` — rounding should land on "obvious capsule" vs "rounded rectangle with clearly visible corners" vs "almost square".

---

## Motion timing

```swift
enum CinemaMotion {
    static let standard: Double = 0.3
}
```

This is deliberately minimal — most animation durations are contextual and live where they're used (focus transitions, toast spring, toggle 0.15 s, rainbow tick 33 ms). See [motion.md](./motion.md).

---

## Adaptive layout (iOS)

iPad gets larger cards, denser grids, and roomier padding via `AdaptiveLayout`. iPhone and iPad are distinguished by `horizontalSizeClass` (`.compact` vs `.regular`); tvOS doesn't consult this helper.

```swift
@Environment(\.horizontalSizeClass) private var hsc
let form = AdaptiveLayout.form(horizontalSizeClass: hsc)   // .compact or .regular
```

### Card widths (horizontal scroll rows)

| Card | `.compact` (iPhone) | `.regular` (iPad) |
| --- | --- | --- |
| `posterCardWidth` (2:3 poster) | 140 | 180 |
| `wideCardWidth` (16:9) | 280 | 380 |

### Grid columns

Grids use **fixed count on iPhone** so card sizing stays stable across the narrow width range, and **adaptive minimum on iPad** so landscape / split-view / Stage Manager pack more automatically.

| Grid | iPhone | iPad |
| --- | --- | --- |
| `posterGridColumns` (library, search) | 3 flexible columns, 16 gap | `GridItem(.adaptive(minimum: 160), spacing: 16)` |
| `browseGenreColumns` (wider rectangles) | 2 flexible, `spacing3` gap | `.adaptive(minimum: 220)`, `spacing3` gap |
| `userGridColumns` (user-switch sheet) | 3 flexible, `spacing3` gap | `.adaptive(minimum: 150)`, `spacing3` gap |

### Padding & reading width

| Metric | iPhone | iPad |
| --- | --- | --- |
| `horizontalPadding` | `spacing3` (16) | `spacing6` (32) |
| `readingMaxWidth` | `nil` (fill) | 900 |

Cap prose (detail overview, licence page, long body text) at `readingMaxWidth` on iPad so reading lines stay ≤ ~70 characters. Centered in parent.

### Hero heights

| Hero | iPhone | iPad |
| --- | --- | --- |
| `heroHeight` (Home) | 360 | 500 |
| `detailBackdropHeight` (MediaDetail) | 310 | 460 |

---

## tvOS layout

tvOS does not use `AdaptiveLayout`. Defaults to apply at call sites:

- **Page outer horizontal padding**: `spacing20` (112) for settings landing / splash layouts; `spacing10` (56) or `spacing6` (32) for content-heavy screens (library grids, home).
- **Content rows horizontal padding**: `spacing10` (56) — matches the visual inset you see on Netflix/Apple TV+.
- **Scroll clip**: `.scrollClipDisabled()` on horizontal rows so focus-scale (1.05×) doesn't clip at row edges.
- **Row card widths**: `PosterCard` ends up ~320 pt wide on tvOS after layout, set by grid spacing rather than a hard token. Don't hardcode — let `LazyHStack` sizing decide.

---

## Frame / sizing conventions

### Image containers

From CLAUDE.md, formalised here:

```swift
// ✅ Correct
Color.clear
    .aspectRatio(2/3, contentMode: .fit)
    .frame(maxWidth: .infinity)
    .overlay { CinemaLazyImage(url: url, fallbackIcon: "film") }
    .clipped()
    .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
```

The `Color.clear` shell is load-bearing — `CinemaLazyImage` alone sizes to the image's natural dimensions, which is usually much larger than the card slot.

### Full-bleed backdrops inside `ZStack`

```swift
ZStack {
    CinemaLazyImage(url: backdropURL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // ← required
    LazyVStack(alignment: .leading) {
        Text(title).font(CinemaFont.display(.large))
        // ...
    }
}
```

Without both `.frame` fills, the ZStack will take the image's 1920 × 1080 natural size and push the title VStack off-screen. The outer container should be `LazyVStack(alignment: .leading)` — not `VStack` — to keep anchoring stable.

### Alphabetical-jump-bar friendly titles (library)

When a library is sorted alphabetically, `AlphabeticalJumpBar` attaches to the right edge and jumps via `scrollTo(firstItemID(for:))`. Don't wrap poster titles in anything that changes the item's ID scheme — the bar looks up items by the same `.id()` used in the `ForEach`.
