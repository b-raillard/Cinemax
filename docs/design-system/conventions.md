# Conventions

Load-bearing rules. Each one exists because breaking it has caused a bug, an inconsistency, or a surprising regression. Read once, then enforce on every PR.

## Colour

### Never `Color(hex:)` for new tokens

All design tokens are `Color.dynamic(light:dark:)` in `CinemaGlassTheme.swift`. The `Color(hex:)` initialiser exists only as a legacy helper and cannot flip with dark/light mode. If you need a new colour: add it as a `CinemaColor` token first, or layer it as an accent variant.

### Never `CinemaColor.tertiary*`

Legacy blue-flavoured accent. Use `themeManager.accent` / `.accentContainer` / `.accentDim` / `.onAccent`. Migrate call sites you encounter.

### Route mode + accent writes through `ThemeManager`

```swift
// ✅
themeManager.darkModeEnabled = true
themeManager.accentColorKey = "purple"

// ❌ Bypasses _accentRevision — views won't re-render
@AppStorage("darkMode") var dark = true
// then writes directly to `dark`
```

`ThemeManager` bumps a private `_accentRevision` counter on write. Every accent-consuming view reads it (`_ = _accentRevision` at the top of each computed property), which is how SwiftUI knows to re-render.

### `.preferredColorScheme` goes at the root, exactly once

In `AppNavigation`. Setting it on a child view breaks `UITraitCollection` propagation, and then every `Color.dynamic` inside that subtree resolves against the wrong trait.

### Hardcoded `.white` / `.black`

Allowed only:
- Inside the video player (chrome is always dark).
- On elements sitting directly on a saturated `accentContainer` fill (e.g. the `.accent` style's label, `RatingBadge` text).

Everywhere else: `CinemaColor.onSurface` / `.onSurfaceVariant`.

## Typography

### No literal `.font(.system(size:))` calls in views

Always `CinemaFont.*`. The one documented exception is `CinemaButton.fontSize` (hardcoded tvOS 28 / iOS 18 for play button presence — see [typography.md](./typography.md#cinemabutton-hardcoded-exceptions)).

### Dynamic Type only on reading surfaces

- Hero / display / headline → fixed variants.
- Body / detail / settings rows / list cells → `dynamicBody` / `dynamicBodyLarge` / `dynamicLabel(_:)`.

### `.minimumScaleFactor` is a safety net, not a solution

`CinemaButton` uses `.minimumScaleFactor(0.7)` for French strings. That's fine. If you find yourself applying it to a display/headline title, the layout is wrong — widen the container.

## Borders & surfaces

### No 1 px borders — use tonal shifts

Hierarchy comes from `surface` → `surfaceContainer` → `surfaceContainerHigh`, not strokes. The exceptions (all explicit and small):

- Ghost `CinemaButton` — 1 pt `outline.opacity(0.2)` stroke.
- tvOS focus ring — 2 pt accent stroke (inside `.cinemaFocus()` and button styles).
- tvOS settings-row focus — 1.5 pt accent stroke (`tvSettingsFocusable`).
- `GlassTextField` focus — accent stroke on the focused state.

That's the full list. Reject code review of anything that adds a new border.

## Toggles

### Never system `Toggle` in settings

Use `CinemaToggleIndicator` wrapped in a `Button`. See [components.md § CinemaToggleIndicator](./components.md#cinematoggleindicator). Same pill on both platforms, correct accent colour, compatible with the "one focusable unit per row" tvOS rule.

## Toolbar buttons (iOS 26)

In iOS 26, navigation-bar `ToolbarItem` buttons are automatically rendered with Liquid Glass by the system. **Do not add `.buttonStyle(.glass)` / `.glassProminent` on toolbar items** — it nests a second glass capsule inside the toolbar's own container (visible doubled-up glass rim, see `MovieLibraryScreen.filterButton` for the reference pattern).

Signal active state with:

```swift
.tint(themeManager.accent)         // colour
Image(systemName: "line.3.horizontal.decrease.circle.fill")  // .fill variant when active
```

## UIButton (UIKit)

Never use `UIButton(type:)` + `setTitle` / `setTitleColor` / `titleLabel?.font` / `backgroundColor` / `contentEdgeInsets` — those APIs are deprecated on iOS 26 and produce runtime warnings. Build with `UIButton.Configuration`.

For a frosted background:

```swift
var config = UIButton.Configuration.plain()
config.title = title
config.baseForegroundColor = .white
// ...
config.background.customView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))

let button = UIButton(configuration: config)
```

Reference patterns: the Skip Intro button and the debug "End" pill in `NativeVideoPresenter.swift`.

## Free SwiftUI helpers

Under Swift 6 strict concurrency, free functions returning `some View` that reference `PrimitiveButtonStyle.plain`, `Font`, or other main-actor-isolated SwiftUI types **must be marked `@MainActor`**. The `iOSToggleRow` / `iOSToggleRowsJoined` / `iOSSettingsRow` helpers in `SettingsRowHelpers.swift` follow this. Any new view helper you add will probably need the same annotation.

## Image loading

### Always `CinemaLazyImage`, never `LazyImage`

`CinemaLazyImage` enforces the fallback conventions (`fallbackIcon`, `fallbackBackground`, suppressed spinners in dense grids).

### Card containers need a `Color.clear` shell

```swift
Color.clear
    .aspectRatio(2/3, contentMode: .fit)
    .frame(maxWidth: .infinity)
    .overlay { CinemaLazyImage(url: url, fallbackIcon: "film") }
    .clipped()
    .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
```

Without the shell, `CinemaLazyImage` sizes to the image's natural dimensions.

### Full-bleed ZStack backdrops need `.frame(maxWidth: .infinity, maxHeight: .infinity)`

Otherwise the `ZStack` sizes from the image's intrinsic (e.g. 1920 pt) dimensions and pushes other ZStack content off-screen. Outer container should be `LazyVStack(alignment: .leading)`, not `VStack`.

### Use `ImageURLBuilder.screenPixelWidth`, not 1920

The helper adapts to the device. Hardcoded widths waste bandwidth on iPhone and look blurry on tvOS 4K.

## Refresh

Settings → Server → Refresh Catalogue is the **single trigger** for cache invalidation:

```swift
apiClient.clearCache()
NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
```

Observers: `HomeScreen`, `MediaLibraryScreen`. iOS also gets `.refreshable { reload() }`.

**Don't add per-page refresh buttons** — that was deliberately consolidated to avoid inconsistent cache behaviour. Pull-to-refresh is fine because it invokes the same reload path.

## Playback

### Always present via UIKit modal, never SwiftUI

SwiftUI `.fullScreenCover` / `.sheet` presentation of the video player corrupts `TabView` / `NavigationSplitView` focus on dismiss. Use `UIViewController.present(_:animated:)` from a `UIHostingController`'s parent chain. See `NativeVideoPresenter.swift`.

### Always `PlayLink`, never `NavigationLink` to `VideoPlayerView`

`PlayLink` picks the right path per platform. A raw `NavigationLink` to `VideoPlayerView` works on iOS but crashes the tvOS focus model.

### `DeviceProfile` must not include `mpeg4`

Not a valid HLS transcode target on Apple platforms — causes Jellyfin to inject `mpeg4-*` URL parameters AVFoundation doesn't recognise. Transcode target is `hevc,h264` only.

### One periodic time observer

`NativeVideoPresenter` owns a single `addPeriodicTimeObserver` (1 s interval) and fans ticks to `SkipSegmentController.onTick` + `PlaybackReporter.onTick`. Sub-controllers must never add their own observers — preserves the single-observer invariant.

## Localization

- Never hardcode user-facing strings. Always `loc.localized("key")` or `loc.localized("key", args...)`.
- French is default (`fr.lproj`), English is the alternative (`en.lproj`).
- For plural-aware strings use the helper on `LocalizationManager` (e.g. `loc.remainingTime(minutes:)`), not inline `if minutes >= 60`.

## Settings keys

Every `@AppStorage` key name and default lives in `SettingsKey` / `SettingsKey.Default`. **Don't write literal string keys at call sites** — it's how typos become silent bugs (write to `"autoPlay"` reads stale data from `"autoPlayNextEpisode"`).

```swift
// ✅
@AppStorage(SettingsKey.autoPlayNextEpisode) var autoPlay: Bool = SettingsKey.Default.autoPlayNextEpisode

// ❌
@AppStorage("autoPlay") var autoPlay = true
```

## Swift 6 escape hatches

Two patterns that are safe but need explicit annotations:

1. **`View, Equatable` sub-type inside a `@MainActor` screen needs `nonisolated static func ==`.** `Equatable` is not main-actor-isolated. Example: `PlayActionButtonsSection` in `MediaDetailScreen.swift`.
2. **A `@MainActor` class's `static func` returning non-Sendable types into a `TaskGroup.addTask @Sendable` closure needs `nonisolated private static func`.** Example: `HomeViewModel.fetchGenreItems`.

Both are safe when the body only reads its parameters. Use them — don't work around by making things `Sendable` they shouldn't be.

---

## A rejection checklist for PRs

When reviewing a PR that touches UI, block on any of these:

- [ ] Uses a hex literal via `Color(hex:)` inside a view
- [ ] Uses `CinemaColor.tertiary*`
- [ ] Sets `.preferredColorScheme` outside `AppNavigation`
- [ ] Adds a 1 px `.stroke` / `.border` that isn't one of the three allowed exceptions
- [ ] Uses a literal `.font(.system(size:))` or `Font.body` / `.title` in a view
- [ ] Uses system `Toggle` in a settings surface
- [ ] Adds `.buttonStyle(.glass)` / `.glassProminent` on a toolbar item
- [ ] Uses `UIButton(type:)` + setter-style UIKit chrome
- [ ] Presents the video player via SwiftUI modal
- [ ] Uses `NavigationLink` to `VideoPlayerView`
- [ ] Adds a per-page catalogue-refresh button
- [ ] Loads an image via raw `LazyImage`
- [ ] Writes to a literal `@AppStorage("...")` key string
- [ ] tvOS: focuses individual sub-items of a settings row
- [ ] tvOS: omits `colorScheme:` from `tvSettingsFocusable(…)`
- [ ] Hardcodes user-facing strings instead of `loc.localized(...)`
