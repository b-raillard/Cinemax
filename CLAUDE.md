# Cinemax - Jellyfin Client for Apple Platforms

Native Jellyfin media streaming client for iOS 18+ and tvOS 26+. Uses a "Cinema Glass" design system (dark glassmorphism, editorial layouts, no borders).

## Architecture

- **SwiftUI** multi-platform (single Xcode project, iOS + tvOS targets)
- **CinemaxKit** local Swift Package at `Packages/CinemaxKit` — shared networking, models, persistence
- **@Observable** + `@MainActor` for all state management
- **Swift 6** strict concurrency
- **JellyfinClient** wrapped with `NSLock` + `nonisolated(unsafe)` for Sendable conformance

**Dependencies**: `jellyfin-sdk-swift` v0.6.0, `Nuke`/`NukeUI` v12.9.0, `AVKit`/`AVPlayer`

## Project Structure

```
Shared/
  DesignSystem/     CinemaGlassTheme, ThemeManager, GlassModifiers, FocusScaleModifier, LocalizationManager, Components/
  Navigation/       AppNavigation (auth routing), MainTabView (tab bar/sidebar)
  Screens/          HomeScreen, MediaDetailScreen, VideoPlayerView, SearchScreen, MovieLibraryScreen, SettingsScreen
iOS/                app entry point
tvOS/               app entry point
Resources/
  fr.lproj/         French localization (default)
  en.lproj/         English localization
Packages/CinemaxKit/  Models, Networking (JellyfinAPIClient, ImageURLBuilder), Persistence (KeychainService)
```

## Design System

- Static color tokens in `CinemaGlassTheme.swift` (`CinemaColor`, `CinemaFont`, `CinemaSpacing`, `CinemaRadius`)
- **No 1px borders** — use color shifts for boundaries. Glass panels: `.glassPanel()` modifier
- **Dynamic accent**: use `themeManager.accent` / `.accentContainer` / `.accentDim` / `.onAccent` — never `CinemaColor.tertiary*`
- **Dark/Light mode**: `ThemeManager.darkModeEnabled` → `.preferredColorScheme()` at root. Colors are dark-first
- **Font scaling**: `CinemaScale.factor` applies a 1.4× base multiplier on tvOS, then user `uiScale` (80–130%) on top. All `CinemaFont` and `CinemaScale.pt()` calls multiply by this. **Exception**: Play/Lecture button labels use hardcoded `28pt` on tvOS
- **Focus — tvOS**: `@FocusState` + `.focusEffectDisabled()` + `.hoverEffectDisabled()`. Indicator is a 2px accent `strokeBorder` — no scale, no white background. Cards: `CinemaTVCardButtonStyle`. Settings rows: `.tvSettingsFocusable()`. Season tabs: `SeasonTabButtonStyle`
- **Focus — iOS**: `.cinemaFocus()` modifier (accent border + shadow)
- **Motion Effects**: `motionEffectsEnabled` environment key (from `AppNavigation` via `@AppStorage("motionEffects")`). When off, all `.animation()` calls use `nil`. Consumed by `CinemaFocusModifier`, `CinemaTVButtonStyle`, `CinemaTVCardButtonStyle`, toggle indicators
- Platform-adaptive layouts: `#if os(tvOS)` or `horizontalSizeClass`

## Navigation

- `AppNavigation` → Keychain session check → `apiClient.reconnect()` + `fetchServerInfo()`
- `AppNavigation` injects `ThemeManager` and `LocalizationManager`, applies `.preferredColorScheme()` at root
- No server → `ServerSetupScreen` → `LoginScreen` → `MainTabView`
- `MainTabView`: top tab bar on tvOS, sidebar on iPad, bottom tab bar on iPhone
- All play buttons use `PlayLink<Label>` (Button+coordinator on tvOS, NavigationLink on iOS) — never direct `NavigationLink` to `VideoPlayerView`

## Media Library (`MediaLibraryScreen`)

Unified screen parameterized by `BaseItemKind` (movies or series).

**Sort & Filter state** (`LibrarySortFilterState`):
- Default: `dateCreated` descending. `isNonDefault` is true when sort or filter differs from default
- `isFiltered` is true only when genre chips are selected
- **Browse vs filtered**: show browse view (genre rows) whenever `isFiltered == false`, regardless of sort. Only a genre chip selection switches to the flat filtered grid
- **Title count**: uses `isFiltered` (not `isNonDefault`) — sort-only changes don't affect total count, only genre filtering does. Shows `filteredTotalCount` when filtered, `totalCount` otherwise
- Sort change triggers `reloadGenreItems` (genre rows respect current sort); genre selection triggers `applyFilter` (flat paginated list)
- `loadInitial` guarded by `hasLoaded` — prevents re-randomization on tab switch

**tvOS filter bar**: inline (not modal) — sort pills (horizontal scroll) + genre chips (`FlowLayout`, multi-line) + reset button. `TVFilterChipButtonStyle` for chip focus.

## Video Playback

### Playback Flow
1. `getItem()` — fetch full metadata
2. Resolve non-playable items: Series → `getNextUp()` or first episode; Season → first episode (**Series/Season have no media sources — must resolve to Episode first**)
3. POST PlaybackInfo with `DeviceProfile` (`isAutoOpenLiveStream=true`, `mediaSourceID`, `userID`)
4. Build stream URL: use `transcodingURL` if present (HLS), otherwise direct stream `/Videos/{id}/stream?static=true&...`
5. Fallback: direct stream without PlaybackInfo session

**DeviceProfile**: DirectPlay for mp4/m4v/mov + h264/hevc; transcode to HLS mp4. `maxBitrate`: 120 Mbps (4K) or 20 Mbps (1080p) via `@AppStorage("render4K")`.

### tvOS Player — Critical Constraints
- **MUST present via UIKit modal** (`UIViewController.present()`), NOT SwiftUI — SwiftUI presentation corrupts `TabView`/`NavigationSplitView` focus on dismiss
- **Do NOT use `AVPlayerViewController`** — shows "Unknown" for audio tracks, no public API to fix. Use `TVPlayerHostViewController` instead

### Custom tvOS Player (`TVCustomPlayerView.swift`)
All types live in `Shared/Screens/TVCustomPlayerView.swift`:

- **`TVPlayerState`** — single source of truth: `currentTime`, `duration`, `isPlaying`, `isBuffering`, `showControls`, `currentAudioIdx`, `currentSubtitleIdx`
- **`TVPlayerHostViewController`** — UIKit VC with `AVPlayerLayer` + `UIHostingController<TVPlayerOverlayView>`. Handles remote via `pressesBegan`: playPause → toggle; menu → show/dismiss controls; left/right → pass to super (SwiftUI `onMoveCommand` handles seeking)
- **`TVControlsOverlay`** — owns the single `@FocusState<FocusItem?>` (`.scrubber`, `.audio`, `.subtitle`). `onMoveCommand` for seeking lives here. Controls float on video with no background container; buttons have individual `Circle()` glass backgrounds
- **`TVPlayerScrubber`** — display-only, no `@FocusState`. Re-renders only on progress/time changes
- **`TVAudioTrackMenu`** / **`TVSubtitleTrackMenu`** — isolated sub-views observing only their index. Same-track selection is a no-op

**Key invariants**:
- Never re-render Menus on time ticks — isolate to sub-views
- Always set `state.currentTime = savedSeconds` before `state.isBuffering = true` in track-switch paths
- `@FocusState` must live in `TVControlsOverlay` (parent), not sub-views, for focus restoration after Menu back

### iOS Player (`VideoPlayerView`)
`AVPlayerItem(url:)`, KVO on `playerItem.status`, cleanup on disappear (pause + nil + invalidate).

## tvOS Settings

`@AppStorage` keys, all in `SettingsScreen`:
| Key | Default | Effect |
|-----|---------|--------|
| `motionEffects` | `true` | `motionEffectsEnabled` env key — disables all animations when off |
| `forceSubtitles` | `false` | Auto-selects first `.legible` track; disables `appliesMediaSelectionCriteriaAutomatically` |
| `render4K` | `true` | `maxBitrate` 120 Mbps (on) / 20 Mbps (off) |
| `uiScale` | `1.0` | Font scale 80–130%. Bumps `ThemeManager._accentRevision` to force re-render |

## MediaDetailScreen

- `MediaDetailViewModel` auto-resolves Episode/Season → parent Series (fetches by `seriesID`, loads seasons + episodes)
- Uses `resolvedType` (not initial `itemType`) for layout decisions
- tvOS: overview text uses `.focusable()` for focus-driven scrolling past non-interactive content

## Localization

- `LocalizationManager` (`@Observable`, injected from `AppNavigation`). Default: French (`fr`), also English (`en`)
- All strings via `loc.localized("key")` or `loc.localized("key", args...)` — never hardcoded
- Strings at `Resources/{lang}.lproj/Localizable.strings`
- Reactivity: `@ObservationIgnored` + `@AppStorage` + `_revision` counter pattern (same as `ThemeManager`)

## Image Patterns

- `ImageURLBuilder` → `/Items/{id}/Images/{type}` URLs
- **Backdrop fallback**: `item.parentBackdropItemID ?? item.seriesID ?? item.id`
- **Card containers**: `Color.clear` + `.aspectRatio()` + `.frame(maxWidth: .infinity)` + `.overlay { LazyImage }` + `.clipped()`
- **PosterCard title alignment**: hidden `Text("M\nM").hidden()` placeholder + actual title overlaid top-aligned → uniform row height regardless of title length

## App Icons

- **iOS**: `Resources/Assets.xcassets/AppIcon.appiconset/` — 1024×1024 in three variants (light, dark, tinted)
- **tvOS**: `Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets/` — 3-layer parallax imagestack + Top Shelf (1920×720) + Top Shelf Wide (2320×720)
- **Standalone source**: `appIcon.png` at project root

## Build

```bash
# iOS
xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# tvOS
xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'

# Regenerate Xcode project
cd Cinemax && xcodegen generate
```
