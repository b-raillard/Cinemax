# Platforms

iOS (iPhone), iPadOS, and tvOS share tokens and components. Divergence is at the layout + input-model level — never at the style-token level.

---

## At a glance

|  | iPhone | iPad | tvOS |
| --- | --- | --- | --- |
| Shell | `TabView` (bottom bar) | `NavigationSplitView` (sidebar) | `TabView` (top bar) |
| Input | Touch | Touch + pointer (hover) | Siri Remote (focus engine) |
| Focus indicator | system defaults | `.hoverEffect(.lift)` | 2 pt accent stroke + scale 1.05 + shadow |
| Toggle affordance | `CinemaToggleIndicator` in `Button` | same as iPhone | same, but via `tvSettingsFocusable(colorScheme:)` |
| Video player dismissal | `PlayerHostingVC.viewWillDisappear(isBeingDismissed:)` | same as iPhone | `TVDismissDelegate` (no child VC embedding) |
| Alert style | SwiftUI `.alert` OK; `UIAlertController` inside playback | same | Always `UIAlertController` |
| Base font multiplier | 1.0 | 1.0 | 1.4 |
| UI scale range | 0.8 – 1.3 (user) | 0.8 – 1.3 (user) | 0.8 – 1.3 (user, compounds with 1.4) |
| Dynamic Type | Yes (`.xSmall … .accessibility2`) | Yes | No |
| Settings top-level | bottom tab | split sidebar item | top tab |
| Modal sheets | `.sheet(item:)` | `.sheet(item:)` (adapts to form) | `.sheet(item:)` + focus discipline |
| Alphabetical jump bar | Yes | Yes | No |
| Hover effects | No | Yes | No (focus instead) |

---

## iOS (iPhone)

### Layout form

`AdaptiveLayout.form(horizontalSizeClass: .compact)`:
- `posterCardWidth` 140, `wideCardWidth` 280
- Grids: 3 flexible columns, 16 gap (poster); 2 flexible columns, `spacing3` gap (browse genre)
- `horizontalPadding` `spacing3` (16)
- `readingMaxWidth` none (fill)
- `heroHeight` 360, `detailBackdropHeight` 310

### Navigation

- Root `TabView` in `MainTabView` — bottom bar.
- Detail screens pushed via `NavigationStack` + `navigationDestination(item:)`.
- **Caveat**: destinations that need to observe an `@Observable` environment object must be standalone `View` structs with their own `@Environment` properties. Extension methods returning `some View` render in a separate context and won't re-render from observable changes.

### Playback

- Native `AVPlayerViewController` presented as a UIKit modal.
- Picture-in-Picture enabled (`allowsPictureInPicturePlayback = true`, `canStartPictureInPictureAutomaticallyFromInline = true`).
- External playback / AirPlay enabled (`usesExternalPlaybackWhileExternalScreenIsActive = true`).
- Subtitles stripped via `HLSManifestLoader` (custom scheme `cinemax-https://`) — ASS/SSA tags cleaned so AVKit shows one unified native Subtitles menu.
- Voice search briefly flips audio category to `.record`; do not start voice search during active playback.

### Input

- Touch only on iPhone.
- `AlphabeticalJumpBar` appears on the right edge of library screens when sort is A→Z name and `items.count > 20`.

---

## iPadOS

Same codebase as iPhone, but distinguished by size class + iPad-specific affordances.

### Layout form

`AdaptiveLayout.form(horizontalSizeClass: .regular)`:
- `posterCardWidth` 180, `wideCardWidth` 380
- Grids: `.adaptive(minimum: 160)` (poster) — column count scales with container width including sidebar, split view, Stage Manager
- `horizontalPadding` `spacing6` (32)
- `readingMaxWidth` 900 — prose capped at this, centered
- `heroHeight` 500, `detailBackdropHeight` 460

### Navigation

- `NavigationSplitView` — sidebar on one side, detail on the other.
- Same `navigationDestination(item:)` push semantics as iPhone.

### Multitasking & orientation

- `UIRequiresFullScreen` was removed with the iOS 26 bump. iPad split view / Stage Manager is allowed at runtime.
- **Hero/backdrop layouts and playback-through-resize have not been hardened for resized iPad windows**. Expect visual glitches on non-full-window iPad until that work ships.
- iPhone and iPad orientation lists both include `UIInterfaceOrientationPortraitUpsideDown` to silence the "all orientations must be supported" warning introduced alongside the Full-Screen deprecation.

### Input

- Touch + pointer. `.hoverEffect(.lift)` on focusable cards (from `.cinemaFocus()` when motion is enabled) gives a gentle scale/shadow when the pointer is over them.
- When motion is disabled, the fallback is `.hoverEffect(.highlight)` (dim only).

---

## tvOS

### Layout

- Top tabs in `TabView`.
- Horizontal scroll rows must use `.scrollClipDisabled()` so the 1.05× focus scale isn't clipped at row edges.
- Page outer padding on landing-type screens: `spacing20` (112). Content-heavy screens (library, home) use `spacing10` (56) or `spacing6` (32).

### Focus model

- `@FocusState` + `.focusEffectDisabled()` + `.hoverEffectDisabled()` — Cinemax draws its own focus indicator, suppressing the system's halo.
- Indicator is a 2 pt accent `strokeBorder` with radius `.large`, plus a `surfaceTint`-coloured shadow. No scale (scale is from button style), no white background.
- Settings-row focus: `tvSettingsFocusable(isFocused:, accent:, colorScheme:)` — **always** pass `colorScheme: themeManager.darkModeEnabled ? .dark : .light` (see [colors.md § tvOS focus caveat](./colors.md#tvos-focus-caveat)).

### Button styles

- Cards: `CinemaTVCardButtonStyle` — 0.97 press scale, 0.05 brightness lift on focus.
- Buttons: `CinemaTVButtonStyle(cinemaStyle:)` — 1.05 focus scale, 0.95 press scale, style-specific shadow. Wrapped by `CinemaButton`.
- Chips: `TVFilterChipButtonStyle(accent:)` — stroke border on focus, no scale.

### Rules (non-negotiable)

1. **One focusable unit per row** — never individually focusable sub-items.
2. **Accent picker / language row** use `onMoveCommand` (left/right cycles values, select cycles) rather than nested focusable items.
3. **`AVPlayerViewController`'s focus environment is locked during playback.** Custom overlay views cannot become focusable. Use `contextualActions = [UIAction(…)]` for in-player buttons. This is the only mechanism — do not try to embed the player as a child VC (causes `-12881`) or override `preferredFocusEnvironments`.
4. **Menu button on detail settings pages**: `.onExitCommand { selectedCategory = nil }`.
5. **Scroll-to-top on reappearance**: wrap landing-screen content in `ScrollViewReader` with a `.id("screen.top")` sentinel; `proxy.scrollTo("screen.top", anchor: .top)` in `.onAppear` so the top tab bar resurfaces after deep nav pop or tab switch.

### Playback

- Native `AVPlayerViewController` presented via UIKit modal.
- Audio-track menus are first-class via `transportBarCustomMenuItems`.
- Subtitles: `HLSManifestLoader` does **not** work on tvOS — causes `-12881` with `AVPlayerViewController`. The direct HLS URL is used; ASS/SSA tags may appear in subtitle text.
- Chapters: set `AVPlayerItem.navigationMarkerGroups = [AVNavigationMarkersGroup(...)]`. Each marker carries `commonIdentifierTitle` + optional `commonIdentifierArtwork` from `ImageURLBuilder.chapterImageURL(…)`. iOS has no native chapter scrubber so the path is `#if os(tvOS)` no-op.
- Skip Intro / Credits: via `AVPlayerViewController.contextualActions`. **The only mechanism that produces a focusable action button while AVPlayerViewController is on screen.**

### Typography

- Base font multiplier 1.4 on top of the user's UI scale (see [typography.md](./typography.md#the-scale-system)).
- Dynamic Type is not applied on tvOS.
- No `UIFontMetrics` in the tvOS render path.

### Assets

- App icon: `Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets/` — 3-layer parallax imagestack + Top Shelf (1920 × 720) + Top Shelf Wide (2320 × 720).
- In-app logo: `AppLogo.imageset` uses `app_logo_tv.png` on tvOS — the front parallax layer only, transparent background. Don't apply `.clipShape` to the tvOS logo.

---

## Cross-platform conventions

### Presenting modals over the player

Do not present a SwiftUI sheet on top of the video player. The underlying `AVPlayerViewController` is a UIKit view; stacking SwiftUI modal presentation on top produces focus + dismissal bugs on both platforms.

Instead:
- **tvOS**: `UIAlertController` presented from the player VC.
- **iOS**: `UIAlertController` or custom UIKit view added to `playerVC.view`.

### Audio sessions

`NativeVideoPresenter.activatePlaybackAudioSession()` sets `.playback + .moviePlayback` before handing an item to the player, and `.notifyOthersOnDeactivation` in `cleanup()`. Required on iOS for AirPlay + lock-screen continuation (`UIBackgroundModes = [audio, airplay]` in `project.yml`).

### Image URLs

Use `ImageURLBuilder.screenPixelWidth` for backdrops — not a literal `1920`. The value adapts per device (Retina scale, iPad vs iPhone, tvOS 4K).
