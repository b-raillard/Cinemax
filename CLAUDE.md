# Cinemax - Jellyfin Client for Apple Platforms

Native Jellyfin media streaming client for iOS 18+ and tvOS 26+. Uses a "Cinema Glass" design system (dark glassmorphism, editorial layouts, no borders).

## Architecture

- **SwiftUI** multi-platform (single Xcode project, iOS + tvOS targets)
- **CinemaxKit** local Swift Package at `Packages/CinemaxKit` — shared networking, models, persistence
- **@Observable** + `@MainActor` for all state management
- **Swift 6** strict concurrency
- **JellyfinClient** wrapped with `NSLock` + `nonisolated(unsafe)` for Sendable conformance

**Dependencies**: `jellyfin-sdk-swift` v0.6.0, `Nuke`/`NukeUI` v12.9.0, `AVKit`/`AVPlayer`

**Playback reporting**: `APIClientProtocol` defines `reportPlaybackStart`, `reportPlaybackProgress`, `reportPlaybackStopped`. Both `TVPlayerHostViewController` (tvOS) and `VideoPlayerView` (iOS) call these on start, every 10 s, and on dismiss/disappear. Without these calls Jellyfin never updates `playbackPositionTicks` / `isPlayed`, so `getNextUp` and resume data stay stale.

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
- **Reusable components** in `Shared/DesignSystem/Components/`: `CinemaLazyImage`, `ProgressBarView`, `RatingBadge`, `LoadingStateView`, `ErrorStateView`, `PosterCard`, `WideCard`, `ContentRow`, `CinemaButton`
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

**DeviceProfile**: DirectPlay for mp4/m4v/mov + h264/hevc; transcode to HLS mp4 with `hevc,h264` only. **Never include `mpeg4`** in video codec lists — MPEG-4 ASP is not a valid HLS transcode target on Apple platforms and causes Jellyfin to inject `mpeg4-*` URL parameters that AVFoundation doesn't recognise. `maxBitrate`: 120 Mbps (4K) or 20 Mbps (1080p) via `@AppStorage("render4K")`.

### tvOS Player — Critical Constraints
- **MUST present via UIKit modal** (`UIViewController.present()`), NOT SwiftUI — SwiftUI presentation corrupts `TabView`/`NavigationSplitView` focus on dismiss
- **Do NOT use `AVPlayerViewController`** — shows "Unknown" for audio tracks, no public API to fix. Use `TVPlayerHostViewController` instead

### Custom tvOS Player (`TVCustomPlayerView.swift`)
All types live in `Shared/Screens/TVCustomPlayerView.swift`:

- **`TVPlayerState`** — single source of truth: `currentTime`, `duration`, `isPlaying`, `isBuffering`, `showControls`, `currentAudioIdx`, `currentSubtitleIdx`, `title`, `previousEpisode`, `nextEpisode`
- **`TVPlayerHostViewController`** — UIKit VC with `AVPlayerLayer` + `UIHostingController<TVPlayerOverlayView>`. Handles remote via `pressesBegan`: playPause → toggle; menu → show/dismiss controls; left/right → pass to super (SwiftUI `onMoveCommand` handles seeking). Accepts `episodeNavigator` for in-player episode switching via `navigateToEpisode(_:)`. Reports playback start/progress/stop to Jellyfin. **Touch-surface scrubbing**: `UIPanGestureRecognizer` with `allowedTouchTypes = [.indirect]` tracks swipe gestures on the Siri Remote touch pad; during scrub `state.currentTime` updates visually while the time observer is gated (`isScrubbing`), and a single `avPlayer.seek()` fires on gesture end.
- **`TVControlsOverlay`** — owns the single `@FocusState<FocusItem?>` (`.scrubber`, `.audio`, `.subtitle`, `.previousEpisode`, `.nextEpisode`). `onMoveCommand` for seeking lives here. Controls float on video with no background container; buttons have individual `Capsule()` glass backgrounds
- **`TVPlayerScrubber`** — display-only, no `@FocusState`. Re-renders only on progress/time changes
- **`TVAudioTrackMenu`** / **`TVSubtitleTrackMenu`** — isolated sub-views observing only their index. Same-track selection is a no-op

**HUD center area** (always visible when controls are shown):
- Large `pause.circle.fill` / `play.circle.fill` icon reflects `state.isPlaying` in real-time
- `gobackward.15` / `goforward.15` flash icons flank the play/pause icon; shown for 500 ms on each scrubber seek, cancelled and restarted on rapid consecutive seeks

**Episode navigation** (`EpisodeRef` + `EpisodeNavigator` + `buildEpisodeNavigation` in `PlayLink.swift`):
- `EpisodeRef: Sendable { id, title }` — lightweight episode pointer
- `EpisodeNavigator = @Sendable (String) async -> (PlaybackInfo, EpisodeRef?, EpisodeRef?)?` — fetches new PlaybackInfo and returns updated prev/next refs
- `buildEpisodeNavigation(for:in:apiClient:userId:)` — free function that builds `(previous, next, navigator)` from a flat `[BaseItemDto]` list; used by both `MediaDetailScreen` and `HomeViewModel` to avoid duplication
- `TVControlsOverlay` shows `backward.end.fill` / `forward.end.fill` capsule buttons when `state.previousEpisode` / `state.nextEpisode` are non-nil; update live after navigation
- `navigateToEpisode()` reports playback stop for the old item, then start for the new one; resets `state.currentTime/duration`, swaps `AVPlayer` item, updates `state.title` + episode refs
- `PlayLink` carries `previousEpisode`, `nextEpisode`, `episodeNavigator`; passes them through `VideoPlayerCoordinator` → `TVVideoPresenter` → `TVPlayerHostViewController`

**Key invariants**:
- Never re-render Menus on time ticks — isolate to sub-views
- Always set `state.currentTime = savedSeconds` before `state.isBuffering = true` in track-switch paths
- `@FocusState` must live in `TVControlsOverlay` (parent), not sub-views, for focus restoration after Menu back
- `state.title` / `state.previousEpisode` / `state.nextEpisode` are updated by `navigateToEpisode()` so the overlay reflects the current episode without re-mounting
- `isScrubbing = true` blocks the periodic time observer from overriding the scrubber position during touch-pad swipes

### iOS Player (`VideoPlayerView`)
`AVPlayerItem(url:)`, KVO on `playerItem.status`, cleanup on disappear (pause + nil + invalidate). Uses `@State`-based mutable episode context (`currentItemId`, `currentTitle`, `currentStartTime`, `currentPrevEpisode`, `currentNextEpisode`) so episode navigation hot-swaps the player in place. Prev/next `backward.end.fill` / `forward.end.fill` icon buttons appear in the top-trailing overlay alongside the track picker. Reports playback start/progress (10 s loop) /stop to Jellyfin; `progressReportTask` is cancelled in `cleanup()`.

## Settings Screen

### Layout — two-level navigation

**Landing page** (both platforms):
- **tvOS**: Split layout — left panel (brand: `AppLogo` image + title + version), right panel (4 nav category buttons). Centered accent bloom in `.background {}` persists across all settings pages. No intermediate panel backgrounds — dark base + bloom + content only.
- **iOS**: Vertical scroll — logo header, 4 nav buttons (first is accent-highlighted), device info footer. Uses `NavigationStack` + `navigationDestination(item:)`.

**Detail pages** (per category: Appearance, Account, Server, Interface):
- tvOS: `ScrollView` with back button at top. Menu (remote) button triggers `.onExitCommand { selectedCategory = nil }`.
- iOS: Pushed via `NavigationStack`, standard back button.

### tvOS focus rules for Settings
- Each settings row is a **single focusable unit** — never individual sub-items within a row.
- Accent color row: left/right arrows cycle colors; select cycles to next. Uses `onMoveCommand`.
- Language row: left/right or select toggles fr↔en. Uses `onMoveCommand`.
- Category buttons on landing: pill shape, focused state = `accentContainer` fill + scale 1.05 + glow shadow.
- Back button focus: `.focused($focusedItem, equals: .back)`, highlighted with accent color.

### Assets
- `AppLogo.imageset`: iOS uses `app_logo.png` (full icon with background); tvOS uses `app_logo_tv.png` (front parallax layer — transparent background, jellyfish only). No `clipShape` on tvOS logo — organic shape renders freely.

### `@AppStorage` keys (all in `SettingsScreen`)
| Key | Default | Effect |
|-----|---------|--------|
| `motionEffects` | `true` | `motionEffectsEnabled` env key — disables all animations when off |
| `forceSubtitles` | `false` | Auto-selects first `.legible` track; disables `appliesMediaSelectionCriteriaAutomatically` |
| `render4K` | `true` | `maxBitrate` 120 Mbps (on) / 20 Mbps (off) |
| `uiScale` | `1.0` | Font scale 80–130%. Bumps `ThemeManager._accentRevision` to force re-render |

## MediaDetailScreen

- `MediaDetailViewModel` auto-resolves Episode/Season → parent Series (fetches by `seriesID`, loads seasons + episodes). Also calls `getNextUp()` for series to populate `nextUpEpisode`
- `nextUpEpisodes: [BaseItemDto]` — when `nextUpEpisode.seasonID ≠ selectedSeasonId` (e.g. series season boundary), the next-up's season episodes are fetched separately so `episodeNavigation(for:)` can build prev/next refs for the resume button
- Uses `resolvedType` (not initial `itemType`) for layout decisions
- tvOS: overview text uses `.focusable()` for focus-driven scrolling past non-interactive content
- **tvOS detail refresh**: `VideoPlayerCoordinator` has `lastDismissedAt: Date?`; updated via `onDismiss` callback in `TVPlayerHostViewController.viewWillDisappear`; `MediaDetailScreen` observes `.onChange(of: coordinator.lastDismissedAt)` to reload after the player is dismissed (iOS reloads automatically via `.task` on NavigationLink pop)

**Resume / next-up logic in `actionButtons`**:
- Movie with `playbackPositionTicks > 0` and not `isPlayed`: shows progress bar (accent fill, `playButtonWidth` wide) + remaining time text (`home.remainingTime.*` keys) + "Lecture" button that resumes at saved position via `PlayLink(startTime:)`
- Series: uses `viewModel.nextUpEpisode` (from `getNextUp`). In-progress episode → progress bar + remaining time + resume button. Finished/next episode → episode label + regular play button. Falls back to series-level play if no next-up
- `userData.playbackPositionTicks` and `runTimeTicks` are both `Int?` (not `Int64`); `isPlayed` is `userData.isPlayed: Bool?`
- Episode rows show a thin accent progress bar overlay at the bottom of the thumbnail for partially-watched episodes

**Episode navigation wiring**:
- `episodeNavigation(for:)` — delegates to the shared `buildEpisodeNavigation(for:in:apiClient:userId:)` using `viewModel.episodes` (current season) or `viewModel.nextUpEpisodes` (fallback for cross-season next-up)
- Both `actionButtons` (next-up episode) and each `episodeRow` pass `previousEpisode`, `nextEpisode`, `episodeNavigator` to `PlayLink`

## HomeScreen

- `HomeViewModel` loads `resumeItems` (in-progress items) and `latestItems` in parallel via `TaskGroup`
- `heroItem = resumeItems.first ?? latestItems.first`
- **Resume navigation**: after the initial load, for each episode in `resumeItems`, the season's episode list is fetched (grouped by `seasonID` to avoid duplicate requests). Results are stored in `resumeNavigation: [String: (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)]` via `buildEpisodeNavigation`
- Both the hero `PlayLink` and each "Reprendre" card `PlayLink` pass:
  - `startTime` — from `playbackPositionTicks / 10_000_000` (nil for items with no progress)
  - `previousEpisode`, `nextEpisode`, `episodeNavigator` — looked up from `resumeNavigation[id]` (nil for movies)

## Localization

- `LocalizationManager` (`@Observable`, injected from `AppNavigation`). Default: French (`fr`), also English (`en`)
- All strings via `loc.localized("key")` or `loc.localized("key", args...)` — never hardcoded
- Strings at `Resources/{lang}.lproj/Localizable.strings`
- Reactivity: `@ObservationIgnored` + `@AppStorage` + `_revision` counter pattern (same as `ThemeManager`)

## Image Patterns

- `ImageURLBuilder` → `/Items/{id}/Images/{type}` URLs
- **Backdrop fallback**: `item.parentBackdropItemID ?? item.seriesID ?? item.id`
- **All image loading via `CinemaLazyImage`** — never use `LazyImage` directly. Params: `url`, `fallbackIcon: String?` (nil = no icon), `fallbackBackground: Color`, `showLoadingIndicator: Bool`
- **Card containers**: `Color.clear` + `.aspectRatio()` + `.frame(maxWidth: .infinity)` + `.overlay { CinemaLazyImage }` + `.clipped()`
- **PosterCard title alignment**: hidden `Text("M\nM").hidden()` placeholder + actual title overlaid top-aligned → uniform row height regardless of title length

## App Icons

- **iOS**: `Resources/Assets.xcassets/AppIcon.appiconset/` — 1024×1024 in three variants (light, dark, tinted)
- **tvOS**: `Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets/` — 3-layer parallax imagestack + Top Shelf (1920×720) + Top Shelf Wide (2320×720)
- **In-app logo**: `Resources/Assets.xcassets/AppLogo.imageset/` — iOS: full icon; tvOS: front parallax layer only (transparent bg)
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
