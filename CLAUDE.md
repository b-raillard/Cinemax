# Cinemax - Jellyfin Client for Apple Platforms

Native Jellyfin media streaming client for iOS 18+ and tvOS 26+. Uses a "Cinema Glass" design system (dark glassmorphism, editorial layouts, no borders).

## Architecture

- **SwiftUI** multi-platform (single Xcode project, iOS + tvOS targets)
- **CinemaxKit** local Swift Package at `Packages/CinemaxKit` — shared networking, models, persistence
- **@Observable** + `@MainActor` for all state management. **iOS `NavigationStack` caveat**: destination views pushed via `navigationDestination(item:)` render in a separate context — `@Observable` changes to environment objects won't re-render the destination unless it is a standalone `View` struct with its own `@Environment` properties. Always use a proper struct (not an extension method returning `some View`) for interactive pushed destinations.
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

- Dynamic color tokens in `CinemaGlassTheme.swift` (`CinemaColor`, `CinemaFont`, `CinemaSpacing`, `CinemaRadius`). All `CinemaColor` tokens use `Color.dynamic(light:dark:)` backed by `UIColor(dynamicProvider:)` — they resolve against the active `UITraitCollection` automatically. **Never use `Color(hex:)` for new tokens** — always use `Color.dynamic(light:dark:)` so they work in both modes.
- **Reusable components** in `Shared/DesignSystem/Components/`: `CinemaLazyImage`, `ProgressBarView`, `RatingBadge`, `LoadingStateView`, `ErrorStateView`, `PosterCard`, `WideCard`, `ContentRow`, `CinemaButton`
- **Shared toggle**: `CinemaToggleIndicator` (Capsule+Circle pill, in `SettingsScreen.swift`) — used on both iOS and tvOS for all boolean settings. Interaction is parent-driven (wrap in `Button { value.toggle() }`). Never use system `Toggle` in settings.
- **No 1px borders** — use color shifts for boundaries. Glass panels: `.glassPanel()` modifier
- **Dynamic accent**: use `themeManager.accent` / `.accentContainer` / `.accentDim` / `.onAccent` — never `CinemaColor.tertiary*`. All four sub-tokens are dual-mode via `Color.dynamic`.
- **Dark/Light mode**: `ThemeManager.darkModeEnabled` → `.preferredColorScheme()` at root (set in `AppNavigation`, nowhere else). Colors flip automatically via `UITraitCollection`. **Always route dark mode changes through `themeManager.darkModeEnabled =` setter** — direct `@AppStorage("darkMode")` writes bypass `_accentRevision` and break reactivity.
- **Hardcoded `.white` / `.black` rule**: `.white` and `.black` are only acceptable inside the video player (always dark) and on elements that sit directly on a saturated `accentContainer` background. Everywhere else use `CinemaColor.onSurface` / `CinemaColor.onSurfaceVariant`.
- **Font scaling**: `CinemaScale.factor` applies a 1.4× base multiplier on tvOS, then user `uiScale` (80–130%) on top. All `CinemaFont` and `CinemaScale.pt()` calls multiply by this. **Exception**: Play/Lecture button labels use hardcoded `28pt` on tvOS
- **Focus — tvOS**: `@FocusState` + `.focusEffectDisabled()` + `.hoverEffectDisabled()`. Indicator is a 2px accent `strokeBorder` — no scale, no white background. Cards: `CinemaTVCardButtonStyle`. Settings rows: `.tvSettingsFocusable()`. Season tabs: `SeasonTabButtonStyle`. **tvOS focus trait-collection caveat**: when a `Button` receives focus, tvOS overrides the `UITraitCollection` inside the button label, flipping all `Color.dynamic` tokens to their light-mode values. `tvSettingsFocusable` takes a `colorScheme` parameter and injects `.environment(\.colorScheme, colorScheme)` on both the content and the background shape to prevent this. Always pass `colorScheme: themeManager.darkModeEnabled ? .dark : .light` at call sites.
- **Focus — iOS**: `.cinemaFocus()` modifier (accent border + shadow)
- **Motion Effects**: `motionEffectsEnabled` environment key (from `AppNavigation` via `@AppStorage("motionEffects")`). When off, all `.animation()` calls use `nil`. Consumed by `CinemaFocusModifier`, `CinemaTVButtonStyle`, `CinemaTVCardButtonStyle`, toggle indicators. Injected on both iOS and tvOS.
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

### Native Player — Both Platforms (`NativeVideoPresenter` in `VideoPlayerView.swift`)
Both iOS and tvOS use native `AVPlayerViewController` presented via UIKit modal (`UIViewController.present()`). The shared `NativeVideoPresenter` class handles playback, track menus, episode navigation, and playback reporting on both platforms.

- **MUST present via UIKit modal**, NOT SwiftUI — SwiftUI presentation corrupts `TabView`/`NavigationSplitView` focus on dismiss
- **iOS dismiss detection**: `PlayerHostingVC` wrapper (child VC) with `viewWillDisappear(isBeingDismissed:)`
- **tvOS dismiss detection**: `TVDismissDelegate` using `AVPlayerViewControllerDelegate.playerViewControllerDidEndDismissalTransition` (tvOS-only API). Do NOT embed `AVPlayerViewController` as a child VC on tvOS — causes internal constraint conflicts and `-12881` playback errors

**Audio track menus**: injected via `transportBarCustomMenuItems` — first-class public API on tvOS, accessed via ObjC runtime KVC on iOS (marked `API_UNAVAILABLE(ios)` in Swift SDK but exists at runtime on iOS 16+). Custom audio menu shows Jellyfin track names instead of AVKit's default "Unknown" labels

**Subtitle handling** (platform-split):
- **iOS**: `enableSubtitlesInManifest: true` + subtitle profiles `.hls` → Jellyfin includes WebVTT renditions in the HLS manifest. `HLSManifestLoader` (`AVAssetResourceLoaderDelegate` with `cinemax-https://` custom scheme) strips `#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS` from playlists and ASS/SSA override tags (`{\i1}`, `{\b}`, `{comments}`) from VTT segments. AVKit shows ONE unified native Subtitles menu. **iOS fallback**: `HLSManifestLoader` can also fail with `-12881` on iOS (not just tvOS) — `retryWithDirectURL` in `NativeVideoPresenter` automatically retries with the direct HLS URL (no custom scheme) when the player item fails. ASS tags won't be stripped on fallback (same as tvOS). Flag `hasRetriedDirectURL` resets on episode navigation so each episode gets its own retry
- **tvOS**: Same `enableSubtitlesInManifest: true` + `.hls` profiles. `HLSManifestLoader` does NOT work on tvOS (`AVAssetResourceLoaderDelegate` causes `-12881` with `AVPlayerViewController`), so the HLS URL is used directly. AVKit shows native Subtitles menu, but ASS tags may appear in subtitle text (known Jellyfin server-side limitation)
- **`HLSManifestLoader` key constraint**: `contentInformationRequest.contentType` must be a **UTI**, not a MIME type. Use `"public.m3u-playlist"` for M3U8, `"org.w3.webvtt"` for VTT. For segment types, skip `contentType` to let AVFoundation infer it

**Episode navigation**: `MPRemoteCommandCenter` prev/next track commands on both platforms. `EpisodeRef` + `EpisodeNavigator` + `buildEpisodeNavigation` (shared free function in `PlayLink.swift`). `PlayLink` carries `previousEpisode`, `nextEpisode`, `episodeNavigator`; passes through `VideoPlayerCoordinator` (tvOS) or `VideoPlayerView` (iOS) → `NativeVideoPresenter`

**Playback reporting**: `reportPlaybackStart`, `reportPlaybackProgress` (10 s loop), `reportPlaybackStopped` — called on start, periodically, and on dismiss/episode-nav

**Auto-play next episode**: `AVPlayerItem.didPlayToEndTime` observer → `navigateToEpisode(next)` when `autoPlayNextEpisode` setting is on

### Legacy Custom tvOS Player (`TVCustomPlayerView.swift`) — DEAD CODE
The custom player (`TVPlayerHostViewController`, `TVPlayerState`, `TVControlsOverlay`, `TVPlayerScrubber`, `TVAudioTrackMenu`, `TVSubtitleTrackMenu`) is no longer used. tvOS now uses `NativeVideoPresenter` with native `AVPlayerViewController`. The old code remains in `Shared/Screens/TVCustomPlayerView.swift` and `TVPlayerHostViewController.swift` but is unreachable — `VideoPlayerCoordinator` creates `NativeVideoPresenter` instead of `TVVideoPresenter`.

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

### `@AppStorage` keys (shared between iOS and tvOS, declared in `SettingsScreen`)
| Key | Default | Effect |
|-----|---------|--------|
| `motionEffects` | `true` | `motionEffectsEnabled` env key — disables all animations when off |
| `forceSubtitles` | `false` | Auto-selects first `.legible` track; disables `appliesMediaSelectionCriteriaAutomatically` |
| `render4K` | `true` | `maxBitrate` 120 Mbps (on) / 20 Mbps (off) |
| `autoPlayNextEpisode` | `true` | Auto-navigates to next episode via `AVPlayerItem.didPlayToEndTime` in `NativeVideoPresenter` (both platforms) |
| `uiScale` | `1.0` | Font scale 80–130%. Bumps `ThemeManager._accentRevision` to force re-render |
| `darkMode` | `true` | **Must be toggled via `themeManager.darkModeEnabled`**, not directly — direct writes don't bump `_accentRevision` |
| `accentColor` | `"blue"` | Set via `themeManager.accentColorKey` for same reason |

## MediaDetailScreen

- `MediaDetailViewModel` auto-resolves Episode/Season → parent Series (fetches by `seriesID`, loads seasons + episodes). Also calls `getNextUp()` for series to populate `nextUpEpisode`
- `nextUpEpisodes: [BaseItemDto]` — when `nextUpEpisode.seasonID ≠ selectedSeasonId` (e.g. series season boundary), the next-up's season episodes are fetched separately so `episodeNavigation(for:)` can build prev/next refs for the resume button
- Uses `resolvedType` (not initial `itemType`) for layout decisions
- tvOS: overview text uses `.focusable()` for focus-driven scrolling past non-interactive content
- **tvOS detail refresh**: `VideoPlayerCoordinator` has `lastDismissedAt: Date?`; updated via `onDismiss` callback in `NativeVideoPresenter` (triggered by `TVDismissDelegate`); `MediaDetailScreen` observes `.onChange(of: coordinator.lastDismissedAt)` to reload after the player is dismissed (iOS reloads automatically via `.task` on NavigationLink pop)

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
- **Backdrop (full-bleed ZStack)**: `CinemaLazyImage` used directly inside a `ZStack` must have `.frame(maxWidth: .infinity, maxHeight: .infinity)` — without it, the ZStack sizes from the image's natural dimensions (e.g. 1920px), pushing the title VStack off-screen. Also use `LazyVStack(alignment: .leading)` as the outer container.
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
