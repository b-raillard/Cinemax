# Component Catalogue

Every reusable component, its signature, and when to reach for it. Organised by category.

| Category | Components |
| --- | --- |
| [Actions](#actions) | `CinemaButton`, `PlayLink` |
| [Cards & cells](#cards--cells) | `PosterCard`, `WideCard`, `CastCircle`, `ContentRow` |
| [Inputs](#inputs) | `GlassTextField`, `CinemaToggleIndicator` |
| [Status & states](#status--states) | `LoadingStateView`, `EmptyStateView`, `ErrorStateView`, `ToastOverlay` |
| [Media & imagery](#media--imagery) | `CinemaLazyImage`, `ProgressBarView`, `RatingBadge`, `MediaQualityBadges` |
| [Layout](#layout) | `FlowLayout`, `AlphabeticalJumpBar` |
| [Settings row kit](#settings-row-kit) | `SettingsToggleRow`, `iOSToggleRow`, `iOSToggleRowsJoined`, `iOSSettingsRow`, `iOSRowIcon`, `iOSSettingsDivider`, `iOSSettingsSectionHeader`, `tvGlassToggle`, `tvToggleList`, `tvActionRow`, `tvSettingsFocusable` |

For each component below: file, signature, purpose, platform, dependencies, anatomy, and non-obvious notes.

---

## Actions

### `CinemaButton`

- **File**: `Shared/DesignSystem/Components/CinemaButton.swift`
- **Signature**:
  ```swift
  CinemaButton(
      title: String,
      style: CinemaButtonStyle = .primary,  // .primary | .ghost | .accent
      icon: String? = nil,                  // SF Symbol name, trails the title
      isLoading: Bool = false,
      action: @escaping () -> Void
  )
  ```
- **Purpose**: The app's only button. Three styles cover 95 % of needs.
- **Platform**: both. iOS uses a plain SwiftUI button with `RoundedRectangle` background. tvOS uses `CinemaTVButtonStyle` with focus scale/shadow.
- **Dependencies**: `ThemeManager` (accent), `CinemaGradient` (primary style), `CinemaColor.outline` (ghost border).
- **Anatomy**: `HStack` of `ProgressView` (when loading) or `Text + optional Image`. Full-width, `spacing4` horizontal padding. Vertical padding iOS 11 / tvOS 22. Corner radius `.large` (16).
- **Styles**:
  - `.primary` — `primaryButton` gradient, `onPrimary` text. Default.
  - `.ghost` — `.ultraThinMaterial` + `outline.opacity(0.2)` stroke, `onSurface` text.
  - `.accent` — `accentContainer` fill, `.white` text (intentional — `.white` on saturated containers is fine, see [conventions.md § Hardcoded colours](./conventions.md#hardcoded-whiteblack)).
- **Notes**:
  - `isLoading` replaces the label with a `ProgressView` tinted to match `textColor`.
  - Title uses `.tracking(-0.3)`, `.lineLimit(1)`, `.minimumScaleFactor(0.7)` — the last is your safety net for long French strings.
  - Font size is hardcoded `tvOS 28 / iOS 18` — see [typography.md](./typography.md#cinemabutton-hardcoded-exceptions).

### `PlayLink<Label: View>`

- **File**: `Shared/Screens/PlayLink.swift` (deliberately in `Screens/`, not `DesignSystem/Components/` — it depends on `VideoPlayerView` / `VideoPlayerCoordinator`, so moving it would invert the dependency direction)
- **Signature**:
  ```swift
  PlayLink(
      itemId: String,
      title: String,
      startTime: Double? = nil,                    // seconds; nil = from start
      previousEpisode: EpisodeRef? = nil,
      nextEpisode: EpisodeRef? = nil,
      episodeNavigator: EpisodeNavigator? = nil,
      @ViewBuilder label: @escaping () -> Label
  )
  ```
- **Purpose**: The **only** approved way to open the video player. Wraps a custom label.
- **Platform**: both. iOS renders a `NavigationLink` to `VideoPlayerView`; tvOS renders a `Button` that triggers `VideoPlayerCoordinator.play(…)` (UIKit modal).
- **Dependencies**: tvOS — `VideoPlayerCoordinator`, `AppState`. iOS — `VideoPlayerView`.
- **Notes**:
  - `itemId` and `startTime` are `var` on the navigator state so the same controller can rebind to the next episode (auto-play next). See CLAUDE.md § Video Playback.
  - Never use a raw `NavigationLink` to `VideoPlayerView`. The SwiftUI modal path corrupts tab-bar focus on dismiss.
  - For resume from offset: pass `startTime: Double(ticks) / 10_000_000`.
  - For episode navigation: precompute with `precomputeEpisodeRefs(_:)` once per season, reuse for all episodes in that season.

---

## Cards & cells

### `PosterCard`

- **File**: `Shared/DesignSystem/Components/PosterCard.swift`
- **Signature**:
  ```swift
  PosterCard(title: String, imageURL: URL?, subtitle: String? = nil)
  ```
- **Purpose**: 2:3 poster card for movies, series, episodes-as-thumbnails in a grid.
- **Platform**: both.
- **Dependencies**: `CinemaLazyImage` (fallback `"film"`), `.cinemaFocus()`.
- **Anatomy**:
  ```text
  ┌────────────┐
  │            │
  │   2:3      │  RoundedRectangle(radius: .large)
  │   image    │  clipped + clipShape
  │            │
  └────────────┘
   Title text   ← label(.large), onSurfaceVariant, lineLimit(2)
   Subtitle     ← label(.medium), outline, lineLimit(1), optional
  ```
- **Notes**:
  - A hidden `Text("M\nM")` placeholder fixes the title-area height so adjacent cards in a row align even when titles wrap to 1 vs 2 lines.
  - **No** `ProgressView` during image load — rendering 6+ spinners in a dense grid is visual noise. The fallback background covers the load window.

### `WideCard`

- **File**: `Shared/DesignSystem/Components/WideCard.swift`
- **Signature**:
  ```swift
  WideCard(title: String, imageURL: URL?, progress: Double? = nil, subtitle: String? = nil)
  ```
- **Purpose**: 16:9 card for Continue Watching, Watching Now, and other episode-oriented rows.
- **Platform**: both.
- **Dependencies**: `CinemaLazyImage` (fallback `"play.rectangle"`), `ProgressBarView`, `.cinemaFocus()`.
- **Anatomy**: 16:9 image with optional progress bar pinned at the bottom; title + optional subtitle below.
- **Notes**: Progress bar only shown if `progress != nil && progress! > 0`.

### `CastCircle`

- **File**: `Shared/DesignSystem/Components/CastCircle.swift`
- **Signature**:
  ```swift
  CastCircle(name: String, role: String? = nil, imageURL: URL? = nil)
  ```
- **Purpose**: Cast / crew thumbnail on media-detail screens.
- **Platform**: both.
- **Anatomy**: 80 pt circular image (fallback `person.fill`), name below, optional role line.
- **Notes**: Fixed size. Frame width is `80 + 20 = 100`.

### `ContentRow<Data, ItemID, ItemView>`

- **File**: `Shared/DesignSystem/Components/ContentRow.swift`
- **Signature**:
  ```swift
  ContentRow(
      title: String,
      showViewAll: Bool = false,
      onViewAll: (() -> Void)? = nil,
      data: Data,
      id: KeyPath<Data.Element, ItemID>,
      @ViewBuilder itemView: @escaping (Data.Element) -> ItemView
  )
  ```
- **Purpose**: Horizontally-scrollable titled row. Used across Home, MediaDetail, Search.
- **Platform**: both. tvOS adds `.scrollClipDisabled()` so focus scale isn't clipped at row edges.
- **Anatomy**: section header (title + optional "View all") + `ScrollView(.horizontal) { LazyHStack { ForEach } }`.
- **Notes**:
  - The `ForEach` via `id:` is load-bearing — using a `@ViewBuilder` children closure defeats SwiftUI's lazy dequeuing and builds all children eagerly.
  - Feed it 10–30 items. For "everything in this library" use a grid screen instead.

---

## Inputs

### `GlassTextField`

- **File**: `Shared/DesignSystem/Components/GlassTextField.swift`
- **Signature (iOS)**:
  ```swift
  GlassTextField(
      label: String,
      text: Binding<String>,
      placeholder: String = "",
      icon: String? = nil,
      isSecure: Bool = false,
      keyboardType: UIKeyboardType = .default
  )
  ```
  tvOS variant is identical minus `keyboardType`.
- **Purpose**: Single-line glass input for server URL, username, password, search sheets.
- **Platform**: both, with platform-specific layouts (tvOS has larger padding and font).
- **Dependencies**: `ThemeManager` (focus accent stroke), `@FocusState`.
- **Anatomy**: `VStack` of optional uppercase tracked label → rounded-rect panel containing optional SF Symbol icon + `TextField` (or `SecureField` when `isSecure`).
- **Notes**:
  - Focus animates the icon colour on iOS. tvOS does not — focus is already indicated by the system focus effect on the containing button/form.
  - Don't substitute system `TextField` with `.textFieldStyle(.roundedBorder)` — it doesn't match the glass language.

### `CinemaToggleIndicator`

- **File**: `Shared/DesignSystem/Components/CinemaToggleIndicator.swift`
- **Signature**:
  ```swift
  CinemaToggleIndicator(isOn: Bool, accent: Color, animated: Bool = true)
  ```
- **Purpose**: Shared toggle pill (Capsule + sliding Circle). The app never uses the system `Toggle`.
- **Platform**: both.
- **Anatomy**: 52 × 32 capsule filled with `accent` when on, a 26 × 26 white circle inside; 0.15 s easeInOut slide.
- **Pattern**: parent owns the state, wraps in a `Button`:
  ```swift
  Button { value.toggle() } label: {
      CinemaToggleIndicator(isOn: value, accent: themeManager.accent)
  }
  .buttonStyle(.plain)
  ```
- **Why not system `Toggle`**: the iOS tint overrides in system Toggle don't respect our dynamic accent reliably, and tvOS needs the whole row to be one focusable unit — wrapping a system Toggle is awkward. This pill is the same shape on both platforms, which reinforces the "same language on every device" identity.

---

## Status & states

These four cover every "not the happy path" surface. Use them — don't build ad-hoc variants.

### `LoadingStateView`

- **File**: `Shared/DesignSystem/Components/LoadingStateView.swift`
- **Signature**:
  ```swift
  LoadingStateView(tint: Color = CinemaColor.onSurfaceVariant)
  ```
- **Purpose**: Full-area spinner. Use while a screen is fetching its first payload.
- **Anatomy**: centered `ProgressView` scaled `1.5×`.
- **Notes**: pass `.white` (or `.onAccent`) when placed on a saturated / dark overlay.

### `EmptyStateView`

- **File**: `Shared/DesignSystem/Components/EmptyStateView.swift`
- **Signature**:
  ```swift
  EmptyStateView(
      systemImage: String,
      title: String,
      subtitle: String? = nil,
      actionTitle: String? = nil,
      onAction: (() -> Void)? = nil
  )
  ```
- **Purpose**: Legitimate empty collection (zero items, no search matches, filters match nothing).
- **Anatomy**: 56 pt semi-transparent icon → headline title → optional body subtitle → optional 200 pt-wide ghost `CinemaButton`.
- **Notes**: For request failures use `ErrorStateView` instead. For "no results after filter", pass a Clear Filters action.

### `ErrorStateView`

- **File**: `Shared/DesignSystem/Components/ErrorStateView.swift`
- **Signature**:
  ```swift
  ErrorStateView(message: String, retryTitle: String, onRetry: @escaping () -> Void)
  ```
- **Purpose**: A request failed and the user should retry.
- **Anatomy**: 48 pt `exclamationmark.triangle.fill` in `CinemaColor.error` → message text → 160 pt ghost retry button.
- **Notes**: For per-row inline errors (e.g. one failed genre row on Home), render an inline retry capsule — not this full-area view.

### `ToastOverlay`

- **File**: `Shared/DesignSystem/Components/ToastOverlay.swift`
- **Signature**: no parameters — reads `ToastCenter` from environment.
- **Purpose**: Renders the current toast (one at a time) from `ToastCenter.current`. Mount once at the root.
- **Anatomy**: top-anchored glass pill: level-tinted SF Symbol + title + optional message + close button. Spring enter/exit.
- **Usage**:
  ```swift
  // AppNavigation (root)
  .overlay(alignment: .top) { ToastOverlay() }
  ```
- **Emitting toasts**:
  ```swift
  @Environment(ToastCenter.self) private var toasts

  toasts.success("Saved")
  toasts.error("Sign-in failed", message: "Check your password")
  toasts.info("Refreshed")
  ```
- **Durations** (from `ToastCenter`): success 2.5 s, info 2.5 s, error 4.0 s. Pass `duration:` to override.
- **Notes**: toasts do not queue — a new toast replaces the current one.

---

## Media & imagery

### `CinemaLazyImage`

- **File**: `Shared/DesignSystem/Components/CinemaLazyImage.swift`
- **Signature**:
  ```swift
  CinemaLazyImage(
      url: URL?,
      fallbackIcon: String? = "photo",
      fallbackBackground: Color = CinemaColor.surfaceContainerHigh,
      showLoadingIndicator: Bool = false
  )
  ```
- **Purpose**: **The only way to load an image.** Wraps NukeUI's `LazyImage` with Cinemax fallback conventions.
- **Platform**: both.
- **Anatomy**: `LazyImage` → on success `scaledToFill`; loading/absent → `fallbackBackground` + optional icon/spinner.
- **Notes**:
  - Pass `fallbackIcon: nil` to hide the icon entirely.
  - Pass `showLoadingIndicator: true` only on small single-image surfaces where a spinner is noticeable and helpful. Dense grids must leave it false.
  - Disk cache is configured at `AppNavigation.init()` — 500 MB under `com.cinemax.images`.
  - Never use `LazyImage` directly.

### `ProgressBarView`

- **File**: `Shared/DesignSystem/Components/ProgressBarView.swift`
- **Signature**:
  ```swift
  ProgressBarView(
      progress: Double,
      height: CGFloat = 4,
      trackColor: Color = CinemaColor.surfaceContainerHighest
  )
  ```
- **Purpose**: Flat capsule progress bar used in `WideCard`, media detail resume row, episode thumbnails.
- **Anatomy**: `GeometryReader` → track capsule + filled accent capsule (width = `geo.width × clamp(progress, 0, 1)`).
- **Notes**: Accent colour comes from `ThemeManager.accent`. Fixed 4 pt height by default — overrides are rare.

### `RatingBadge`

- **File**: `Shared/DesignSystem/Components/RatingBadge.swift`
- **Signature**:
  ```swift
  RatingBadge(rating: String)
  ```
- **Purpose**: Content rating pill (e.g. `"PG-13"`, `"TV-MA"`, `"Tous publics"`).
- **Anatomy**: uppercase, bold, letter-spaced text inside a semi-transparent white pill. Font size tvOS 12 / iOS 10. Padding `h: 8, v: 4`.

### `MediaQualityBadges`

- **File**: `Shared/DesignSystem/Components/MediaQualityBadges.swift`
- **Signature**:
  ```swift
  MediaQualityBadges(item: BaseItemDto)
  ```
- **Purpose**: Horizontal capsule badge row showing resolution / HDR / video codec / audio format / channels, derived from the item's first media source.
- **Platform**: both. Rendered only when `@AppStorage("detail.showQualityBadges") == true`.
- **Anatomy**: `ScrollView(.horizontal) { HStack { … capsules … } }`. Returns `EmptyView()` when no stream data produces badges.
- **Notes**: detection logic lives in a static `badgeLabels(for:)` helper; see CLAUDE.md § Media Detail Screen / Quality Badges for the exact mapping rules.

---

## Layout

### `FlowLayout`

- **File**: `Shared/DesignSystem/Components/FlowLayout.swift`
- **Signature**:
  ```swift
  FlowLayout(spacing: CGFloat = 8) { /* children */ }
  ```
- **Purpose**: Custom `Layout` that wraps children left-to-right, breaking to a new row when the next child would exceed the container width.
- **Platform**: both.
- **Usage**: genre chip rows, decade chip rows, tag pills — any multi-line capsule cluster.
- **Notes**: Pure `Layout` conformance — no cache, trivial memory footprint. Default `spacing: 8` is tighter than `CinemaSpacing.spacing3`; pass `spacing: CinemaSpacing.spacing3` for "roomy" variants.

### `AlphabeticalJumpBar`

- **File**: `Shared/DesignSystem/Components/AlphabeticalJumpBar.swift`
- **Signature**:
  ```swift
  AlphabeticalJumpBar(accent: Color, onSelect: @escaping (String) -> Void)
  ```
- **Purpose**: iOS Contacts-style right-edge A–Z index strip. Tap or drag to jump the scroll to matching items.
- **Platform**: iOS only (wrapped in `#if os(iOS)`).
- **Anatomy**: vertical capsule with ultraThinMaterial background; rows are single-letter `Text` (11 pt, 18 × 14). A `DragGesture` maps vertical position to a letter; taps and drags both fire `onSelect`.
- **Notes**:
  - Renders `#` (digits/symbols) + `A`–`Z`.
  - Haptic on each letter change (`UISelectionFeedbackGenerator`).
  - Call site: `MediaLibraryScreen` — only shown when `sortBy == .sortName && sortAscending && items.count > 20`.
  - `onSelect(letter)` callers typically `scrollTo(firstItemID(for: letter))` on a `ScrollViewReader`.

---

## Settings row kit

A small language of row primitives that renders the same semantic row on both iOS and tvOS. The data model is platform-agnostic; the platform extensions (`SettingsRowHelpers.swift` for iOS, `SettingsScreen+tvOS.swift` for tvOS) render it.

### `SettingsToggleRow` — the data type

```swift
struct SettingsToggleRow: Identifiable {
    let id: String                   // stable key; tvOS uses it for SettingsFocus.toggle(id)
    let icon: String                 // SF Symbol
    let label: String
    let value: Binding<Bool>
    let tint: Color?                 // iOS-only accent override (currently only used for debug-orange)
}
```

Author toggles once as `[SettingsToggleRow]`, render with the platform renderer.

### iOS renderers

All `@MainActor @ViewBuilder` free functions in `SettingsRowHelpers.swift`.

| API | Purpose |
| --- | --- |
| `iOSToggleRowsJoined(_ rows: [SettingsToggleRow], accent: Color, animated: Bool)` | Renders the array with dividers between; most toggle groups use this. |
| `iOSToggleRow(icon:label:value:accent:animated:)` | One toggle. Internally calls `iOSSettingsRow` + `iOSRowIcon` + `CinemaToggleIndicator`. |
| `iOSSettingsRow { content }` | Padded row container. `h: spacing4, v: spacing3`. |
| `iOSRowIcon(systemName:color:)` | 32 × 32 rounded-rect icon badge. |
| `iOSSettingsDivider` | Thin divider inset past the icon. |
| `iOSSettingsSectionHeader(_ title: String)` | Uppercase tracked section label. `label(.small)`, `onSurfaceVariant`, 1.2 pt tracking. |
| `navigationRow(icon:label:action:)` | Tappable row with chevron — used for "open detail page" navigation. |

### tvOS renderers

All in `SettingsScreen+tvOS.swift`.

| API | Purpose |
| --- | --- |
| `tvToggleList(_ rows: [SettingsToggleRow])` | Renders the array as focused rows. Ignores `row.tint` (tvOS uses `themeManager.accent` uniformly). |
| `tvGlassToggle(icon:label:key:value:)` | One toggle. Button → icon + label + `Spacer` + `CinemaToggleIndicator`; focus key `.toggle(key)`; wrapped in `tvSettingsFocusable`. |
| `tvActionRow(id:icon:label:subtitle:showsChevron:tint:action:)` | Tappable row with icon + title + optional subtitle + optional chevron. Two overloads — generic `.toggle(id)` focus or an explicit `SettingsFocus` case. |
| `tvSettingsFocusable(isFocused:accent:animated:colorScheme:)` | View extension that applies the tvOS settings-row focus treatment. **Always pass `colorScheme: themeManager.darkModeEnabled ? .dark : .light`** — see [colors.md § tvOS focus caveat](./colors.md#tvos-focus-caveat). |

### Example — adding a toggle

```swift
// 1. Declare in the catalogue
var interfaceToggleRows: [SettingsToggleRow] {
    [
        .init(id: "motionEffects",    icon: "sparkles",     label: loc.localized("settings.motion"),      value: $motionEffects),
        .init(id: "forceSubtitles",   icon: "captions.bubble", label: loc.localized("settings.subtitles"), value: $forceSubtitles),
        .init(id: "render4K",         icon: "4k.tv",        label: loc.localized("settings.render4K"),   value: $render4K),
    ]
}

// 2. Render per platform
#if os(iOS)
iOSToggleRowsJoined(interfaceToggleRows, accent: themeManager.accent, animated: motionEnabled)
#else
tvToggleList(interfaceToggleRows)
#endif
```

Adding a new toggle is a one-line addition to the catalogue array — no new row markup.
