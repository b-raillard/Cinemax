# Cinemax - Jellyfin Client for Apple Platforms

Native Jellyfin media streaming client for iOS 18+ and tvOS 26+. Uses a "Cinema Glass" design system (dark glassmorphism, editorial layouts, no borders).

## Architecture

- **SwiftUI** multi-platform (single Xcode project, iOS + tvOS targets)
- **CinemaxKit** local Swift Package at `Packages/CinemaxKit` — shared networking, models, persistence
- **@Observable** + `@MainActor` for all state management. **iOS `NavigationStack` caveat**: destination views pushed via `navigationDestination(item:)` render in a separate context — `@Observable` changes to environment objects won't re-render the destination unless it is a standalone `View` struct with its own `@Environment` properties. Always use a proper struct (not an extension method returning `some View`) for interactive pushed destinations.
- **Swift 6** strict concurrency
- **JellyfinClient** wrapped with `NSLock` + `nonisolated(unsafe)` for Sendable conformance

### Modern API requirements (iOS 18 / tvOS 26)

The project's deployment targets are iOS 18 and tvOS 26. Avoid pre-iOS-15 APIs that the compiler has now deprecated.

- **`UIButton`**: never use `UIButton(type:)` + `setTitle` / `setTitleColor` / `titleLabel?.font` / `backgroundColor` / `contentEdgeInsets`. Build buttons with `UIButton.Configuration`:
  ```swift
  var config = UIButton.Configuration.plain()
  var attrTitle = AttributedString("Hello")
  attrTitle.font = .systemFont(ofSize: 17, weight: .semibold)
  attrTitle.foregroundColor = UIColor.white
  config.attributedTitle = attrTitle
  config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
  config.background.backgroundColor = .systemBlue
  config.background.cornerRadius = 12
  // Frosted background is supported via `config.background.customView = UIVisualEffectView(...)`
  let button = UIButton(configuration: config, primaryAction: UIAction { _ in ... })
  ```
- **Free SwiftUI helpers**: free functions returning `some View` that touch SwiftUI types (`PrimitiveButtonStyle.plain`, `Font`, etc.) must be `@MainActor`. Under Swift 6 strict concurrency, those types are main-actor-isolated and the compiler raises "Main actor-isolated static property X can not be referenced from a nonisolated context" otherwise. The shared `iOSToggleRow` / `iOSSettingsRow` helpers in `SettingsRowHelpers.swift` follow this pattern.
- **iPad multitasking**: `UIRequiresFullScreen: true` is set in `project.yml` for the iOS target. Cinemax is a video player — split view would interrupt playback and break hero/backdrop layouts, and the flag also satisfies Xcode's "all interface orientations must be supported unless the app requires full screen" warning. Don't change this without a strong reason; if the app ever needs split view, the iPhone orientation list must be expanded to include `UIInterfaceOrientationPortraitUpsideDown` (currently omitted on iPhone).

**Dependencies**: `jellyfin-sdk-swift` v0.6.0, `Nuke`/`NukeUI` v12.9.0, `AVKit`/`AVPlayer`

**Playback reporting**: `APIClientProtocol` defines `reportPlaybackStart`, `reportPlaybackProgress`, `reportPlaybackStopped`. `NativeVideoPresenter` (both platforms) calls these on start, every 10 s, and on dismiss/disappear. Without these calls Jellyfin never updates `playbackPositionTicks` / `isPlayed`, so `getNextUp` and resume data stay stale.

## Project Structure

```
Shared/
  DesignSystem/     CinemaGlassTheme, ThemeManager, GlassModifiers, FocusScaleModifier, LocalizationManager, TVButtonStyles
    Components/     CinemaLazyImage, ProgressBarView, RatingBadge, LoadingStateView, ErrorStateView, PosterCard, WideCard, ContentRow, CinemaButton, FlowLayout
  Navigation/       AppNavigation (auth routing), MainTabView (tab bar/sidebar)
  Screens/          HomeScreen, LoginScreen, ServerSetupScreen, SearchScreen, MediaDetailScreen,
                    MovieLibraryScreen, LibrarySortFilterSheet, TVSeriesScreen, MediaQualityBadges,
                    VideoPlayerView, NativeVideoPresenter, HLSManifestLoader, PlayLink, TrackPickerSheet,
                    SettingsScreen (+iOS, +tvOS platform variants), SettingsRowHelpers
  ViewModels/       HomeViewModel, LoginViewModel, SearchViewModel, ServerSetupViewModel,
                    MediaDetailViewModel, MediaLibraryViewModel, VideoPlayerCoordinator
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
- `isFiltered` is true when genre chips are selected OR `showUnwatchedOnly == true` OR `selectedDecades` non-empty
- **Browse vs filtered**: show browse view (genre rows) whenever `isFiltered == false`, regardless of sort. Genre chip / unwatched toggle / decade chip switches to the flat filtered grid
- **Title count**: uses `isFiltered` (not `isNonDefault`) — sort-only changes don't affect total count. Shows `filteredTotalCount` when filtered, `totalCount` otherwise
- Sort change triggers `reloadGenreItems` (genre rows respect current sort); filter change triggers `applyFilter` (flat paginated list)
- `loadInitial` guarded by `hasLoaded` — prevents re-randomization on tab switch. `reload(using:)` bypasses the guard and re-runs the full load. Triggered by pull-to-refresh on iOS and by `.cinemaxShouldRefreshCatalogue` notification from Settings → Server → Refresh Catalogue on both platforms

**Filters**:
- Unwatched: iOS sort sheet `unwatchedSection` + tvOS inline Watch Status chip → `LibrarySortFilterState.showUnwatchedOnly` → `filters: [.isUnplayed]` on `getItems`
- Decade: `LibrarySortFilterState.selectedDecades: Set<Int>` (stored as the starting year, e.g. `1980`). `expandedYears` explodes the set into every concrete year and passes to `getItems(years:)`. UI: chips for 1950s–2020s in both iOS sort sheet and tvOS inline bar

**Refresh**: `.refreshable { reload() }` on iOS. On both platforms, observes `.cinemaxShouldRefreshCatalogue` (posted by Settings → Server → Refresh Catalogue, which also calls `apiClient.clearCache()`). No in-page refresh button — the global Settings action is the single source of truth.

**tvOS filter bar**: inline (not modal) — sort pills (horizontal scroll) + watch-status chip + decade chips + genre chips (`FlowLayout`, multi-line) + Reset button only. `TVFilterChipButtonStyle` for chip focus.

**iOS alphabetical jump bar**: `AlphabeticalJumpBar` (Contacts-style capsule, ultraThinMaterial background, right edge of filtered view). Tap or drag to scroll the grid. Uses `ScrollViewReader` + `proxy.scrollTo(firstItemID(for: letter))` and `UISelectionFeedbackGenerator` for per-letter haptics. Only rendered when `sortBy == .sortName && sortAscending && items.count > 20` — other sorts aren't alphabetically meaningful.

## Video Playback

### Playback Flow
1. `getItem()` — fetch full metadata
2. Resolve non-playable items: Series → `getNextUp()` or first episode; Season → first episode (**Series/Season have no media sources — must resolve to Episode first**)
3. POST PlaybackInfo with `DeviceProfile` (`isAutoOpenLiveStream=true`, `mediaSourceID`, `userID`)
4. Build stream URL: use `transcodingURL` if present (HLS), otherwise direct stream `/Videos/{id}/stream?static=true&...`
5. Fallback: direct stream without PlaybackInfo session

**DeviceProfile**: DirectPlay for mp4/m4v/mov + h264/hevc; transcode to HLS mp4 with `hevc,h264` only. **Never include `mpeg4`** in video codec lists — MPEG-4 ASP is not a valid HLS transcode target on Apple platforms and causes Jellyfin to inject `mpeg4-*` URL parameters that AVFoundation doesn't recognise. `maxBitrate`: 120 Mbps (4K) or 20 Mbps (1080p) via `@AppStorage("render4K")`.

### Native Player — Both Platforms (`NativeVideoPresenter.swift`)
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

**Playback reporting**: `reportPlaybackStart`, `reportPlaybackProgress`, `reportPlaybackStopped` — called on start, periodically (via shared 1 s time observer, reports every ~10 s), and on dismiss/episode-nav

**Auto-play next episode**: `AVPlayerItem.didPlayToEndTime` observer → `navigateToEpisode(next)` when `autoPlayNextEpisode` setting is on

**Skip Intro / Credits**: Requires the **Intro Skipper** plugin (or similar) on the Jellyfin server. On playback start (and episode navigation), `NativeVideoPresenter` fetches media segments via `getMediaSegments(itemId:includeSegmentTypes: [.intro, .outro])`. A single `addPeriodicTimeObserver` (1 s interval) handles both segment detection and progress reporting. Visibility is **pure time-based**: `checkSegments` shows/hides based on whether `currentTime ∈ [segment.start, segment.end)`. Re-entry works naturally — rewinding back into a segment re-shows the button. Click action seeks to `segment.end`; no manual hide call, the next observer tick detects we're outside the segment and clears the button. Localization keys: `player.skipIntro`, `player.skipCredits`.

Rendering is platform-split:
- **iOS**: a floating `UIButton` (with `UIBlurEffect` background, bottom-right corner of the player) added directly to `AVPlayerViewController.view`. Direct touch.
- **tvOS**: native `AVPlayerViewController.contextualActions = [UIAction(…)]`. This is the only mechanism that produces a focusable action button coexisting with `AVPlayerViewController`'s transport-bar focus context. **Custom subviews / overlay modals / subclass `preferredFocusEnvironments` overrides cannot be focused on tvOS while AVPlayerViewController is on screen** — the player owns and locks its focus environment. Do not attempt to reintroduce a floating pill on tvOS; it will appear but be unreachable by the Siri Remote. Same rule applies to any future "in-player" affordance (next-episode card, chapter menu, etc.) — use `contextualActions` or other native player APIs rather than arbitrary subviews.

**Chapters** (tvOS only): built from `BaseItemDto.chapters` and applied via `AVPlayerItem.navigationMarkerGroups = [AVNavigationMarkersGroup(title:timedNavigationMarkers:)]`. Each marker carries `commonIdentifierTitle` + optional `commonIdentifierArtwork` (JPEG thumbnail fetched from `ImageURLBuilder.chapterImageURL(itemId:imageIndex:)` with the Jellyfin auth token). `AVNavigationMarkersGroup` lives in AVKit on tvOS only; iOS `AVPlayerViewController` has no native chapter scrubber so the iOS path is a scoped `#if os(tvOS)` no-op.

**Sleep timer**: `SleepTimerOption` enum (`Off` / 15 / 30 / 45 / 60 / 90 minutes) backed by `@AppStorage("sleepTimerDefaultMinutes")`. `SleepTimerOption.currentDefaultSeconds` returns 15 s when `debug.fastSleepTimer` is on (Settings → Interface → Debug), otherwise the stored option in seconds. `NativeVideoPresenter.startSleepTimerIfNeeded` runs on playback start and episode navigation — displays a moon-icon blur pill countdown indicator (`mm:ss`) bottom-left of the player, pauses + shows a "Still watching?" prompt when the timer fires. The prompt uses `UIAlertController` on tvOS (focus-friendly) and a custom blur card on iOS; "Keep watching" restarts the timer, "Stop playback" dismisses the player.

**End-of-series completion**: When `AVPlayerItemDidPlayToEndTime` fires with autoplay on, no next episode, and `episodeNavigator != nil`, shows a centered "You finished {Series Name}" overlay. `currentSeriesName` is captured opportunistically from the same `getItem` call that fetches chapters. tvOS uses `UIAlertController`, iOS uses a custom blur card — same focus-context reason as the sleep prompt.

**Playback error recovery**: `showPlaybackErrorAlert(error:)` presents a native `UIAlertController` with error-code-specific messages. `-12881 / -12886 / -16170` → transcode guidance, `-12938 / -1001 / -1004 / -1005 / -1009` → network guidance, fallback → generic. On iOS the alert only fires after the `retryWithDirectURL` fallback itself fails (so we don't interrupt the silent first-try recovery). `isShowingErrorAlert` flag prevents stacking.

**Debug tooling** (Settings → Interface → Debug, always visible not gated by `#if DEBUG`):
- `debug.fastSleepTimer` — overrides sleep duration to 15 s
- `debug.showSkipToEnd` — on iOS paints a purple "End" pill top-right of the player that seeks to `(duration − 15 s)`; on tvOS injects the action into `transportBarCustomMenuItems`. Useful for previewing the end-of-series overlay without sitting through an episode.

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

### iOS Settings Row Helpers (`SettingsRowHelpers.swift`)
- `iOSSettingsRow` — padded row container
- `iOSRowIcon` — colored icon badge (leading element)
- `iOSSettingsDivider` — inset divider aligned past icon
- `iOSSettingsSectionHeader` — uppercase section label
- `iOSToggleRow` — complete toggle row (icon + label + `CinemaToggleIndicator`), equivalent to tvOS's `tvGlassToggle`

### Assets
- `AppLogo.imageset`: iOS uses `app_logo.png` (full icon with background); tvOS uses `app_logo_tv.png` (front parallax layer — transparent background, jellyfish only). No `clipShape` on tvOS logo — organic shape renders freely.

### `@AppStorage` keys (shared between iOS and tvOS, declared in `SettingsScreen`)
| Key | Default | Effect |
|-----|---------|--------|
| `motionEffects` | `true` | `motionEffectsEnabled` env key — disables all animations when off |
| `forceSubtitles` | `false` | Auto-selects first `.legible` track; disables `appliesMediaSelectionCriteriaAutomatically` |
| `render4K` | `true` | `maxBitrate` 120 Mbps (on) / 20 Mbps (off) |
| `autoPlayNextEpisode` | `true` | Auto-navigates to next episode via `AVPlayerItem.didPlayToEndTime` in `NativeVideoPresenter` (both platforms) |
| `sleepTimerDefaultMinutes` | `0` (Off) | Duration for the sleep timer that starts on playback. Options: 0 / 15 / 30 / 45 / 60 / 90 min via `SleepTimerOption` |
| `uiScale` | `1.0` | Font scale 80–130%. Bumps `ThemeManager._accentRevision` to force re-render |
| `darkMode` | `true` | **Must be toggled via `themeManager.darkModeEnabled`**, not directly — direct writes don't bump `_accentRevision` |
| `accentColor` | `"blue"` | Set via `themeManager.accentColorKey` for same reason |
| `home.showContinueWatching` | `true` | Toggles the Continue Watching row on Home |
| `home.showRecentlyAdded` | `true` | Toggles the Recently Added row on Home |
| `home.showGenreRows` | `true` | Toggles the 4 dynamic genre rows on Home |
| `home.showWatchingNow` | `true` | Toggles the Watching Now row on Home |
| `detail.showQualityBadges` | `true` | Toggles the resolution/HDR/codec/audio pill row on `MediaDetailScreen` |
| `debug.fastSleepTimer` | `false` | Overrides sleep duration to 15 s — for testing the "Still watching?" prompt |
| `debug.showSkipToEnd` | `false` | Shows an "End" button in the player that seeks to `(duration − 15 s)` — for testing end-of-series overlay |

### Quick user switch
`UserSwitchSheet` (launched from Settings → Account) — two-step flow: grid of server users with their primary images → password prompt → re-auth. Updates `AppState.accessToken` / `currentUserId` and calls `apiClient.reconnect(url:accessToken:)` without clearing the server URL, then emits a success toast and dismisses. Errors stay inline so the user can retry.

### Refresh Catalogue
Settings → Server has a "Refresh Catalogue" row that calls `apiClient.clearCache()` and posts `.cinemaxShouldRefreshCatalogue`. `HomeScreen` and `MediaLibraryScreen` observe this notification and reload. Fires a success toast. Single source of truth for forcing a re-fetch — no per-page refresh buttons.

### Debug section
Settings → Interface → Debug holds testing toggles. Always visible (not gated by `#if DEBUG`) so QA / power users don't need a custom build. Icons are orange to signal developer territory.

## MediaDetailScreen

- `MediaDetailViewModel` auto-resolves Episode/Season → parent Series (fetches by `seriesID`, loads seasons + episodes). Also calls `getNextUp()` for series to populate `nextUpEpisode`. `selectSeason()` uses a generation counter to discard stale results on rapid selection
- `nextUpEpisodes: [BaseItemDto]` — when `nextUpEpisode.seasonID ≠ selectedSeasonId` (e.g. series season boundary), the next-up's season episodes are fetched separately so `episodeNavigation(for:)` can build prev/next refs for the resume button
- Uses `resolvedType` (not initial `itemType`) for layout decisions
- tvOS: overview text uses `.focusable()` for focus-driven scrolling past non-interactive content
- **tvOS detail refresh**: `VideoPlayerCoordinator` has `lastDismissedAt: Date?`; updated via `onDismiss` callback in `NativeVideoPresenter` (triggered by `TVDismissDelegate`); `MediaDetailScreen` observes `.onChange(of: coordinator.lastDismissedAt)` to reload after the player is dismissed (iOS reloads automatically via `.task` on NavigationLink pop)

**Resume / next-up logic in `actionButtons`**:
- Movie with `playbackPositionTicks > 0` and not `isPlayed`: shows progress bar (accent fill, `playButtonWidth` wide) + remaining time text (`home.remainingTime.*` keys) + "Lecture" button that resumes at saved position via `PlayLink(startTime:)`
- Series: uses `viewModel.nextUpEpisode` (from `getNextUp`). In-progress episode → progress bar + remaining time + resume button. Finished/next episode → episode label + regular play button. Falls back to series-level play if no next-up
- **Play from beginning**: when `showResume` is true, a secondary ghost-styled `PlayLink` button (`detail.playFromBeginning`, SF Symbol `backward.end.fill`) is rendered under the resume button with `startTime: nil`. Only shown when a resume position exists — otherwise the single primary button already starts from 0
- `userData.playbackPositionTicks` and `runTimeTicks` are both `Int?` (not `Int64`); `isPlayed` is `userData.isPlayed: Bool?`
- Episode rows show a thin accent progress bar overlay at the bottom of the thumbnail for partially-watched episodes

**Quality badges** (`MediaQualityBadges.swift`):
- Horizontal pill row between `actionButtons` and overview text. Gated on `@AppStorage("detail.showQualityBadges")` (default `true`, toggleable in Settings > Interface > Detail Page)
- Derived from `item.mediaSources?.first` — first `.video` stream for resolution/HDR/video codec, default audio stream (`defaultAudioStreamIndex`) for audio format/channels
- Resolution: height thresholds → "4K" / "1080p" / "720p" / "SD"
- HDR: `VideoRangeType` maps to "Dolby Vision" (any `dovi*` case), "HDR10+", "HDR10", "HDR" (for `hlg`); `VideoRange.hdr` as fallback. No badge for SDR
- Video codec: "HEVC" (hevc/h265), "H.264", "AV1", "VP9", else uppercased raw codec
- Audio format: first-hit priority — Atmos (from `profile`/`displayTitle`), TrueHD, "Dolby Digital+" (EAC3), "Dolby Digital" (AC3), DTS, AAC, FLAC, Opus, MP3, else uppercased raw codec
- Channels: `channelLayout` uppercased (Stereo/Mono title-cased); fallback from `channels` count (8→"7.1", 6→"5.1", 2→"Stereo", 1→"Mono")
- View returns `EmptyView()` when no streams produce any badges

**Episode navigation wiring**:
- `episodeNavigation(for:)` — O(1) lookup from precomputed `viewModel.episodeNavigationMap` (current season) or `viewModel.nextUpNavigationMap` (cross-season next-up). Maps are rebuilt in `MediaDetailViewModel` whenever episodes change
- Both `actionButtons` (next-up episode) and each `episodeRow` pass `previousEpisode`, `nextEpisode`, `episodeNavigator` to `PlayLink`

**Ratings row** (`ratingsRow`): backdrop-adjacent. Shows `communityRating` (yellow star + `%.1f`) and `criticRating` (Rotten-Tomatoes-style icon — green if ≥ 60, red otherwise — + `%d%%`). Either or both may be absent.

**Studio / Network label** (`studioLine`): below the overview. Up to 2 names from `item.studios`. Label reads "STUDIO" for movies, "NETWORK" for series. Returns `EmptyView` when the array is empty.

**Episode metadata line** (`episodeMetadataLine`): shared helper used by both the tvOS `episodeRow` and iOS `iOSEpisodeCard`. Combines with ` • ` separator:
- If in-progress (not `isPlayed`, `playbackPositionTicks > 0`, remaining > 0): "Xm remaining" via `home.remainingTime.*` keys
- Else if `runTimeTicks > 0`: total runtime via `detail.runtime.min`
- Plus `premiereDate` formatted as `.dateTime.month(.abbreviated).day().year()` when present

## HomeScreen

- `HomeViewModel` loads `resumeItems` (in-progress items) and `latestItems` in parallel via `TaskGroup`
- `heroItem = resumeItems.first ?? latestItems.first`
- **Resume navigation**: after the initial load, for each episode in `resumeItems`, the season's episode list is fetched (grouped by `seasonID` to avoid duplicate requests). Results are stored in `resumeNavigation: [String: (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)]` via `buildEpisodeNavigation`
- Both the hero `PlayLink` and each "Reprendre" card `PlayLink` pass:
  - `startTime` — from `playbackPositionTicks / 10_000_000` (nil for items with no progress)
  - `previousEpisode`, `nextEpisode`, `episodeNavigator` — looked up from `resumeNavigation[id]` (nil for movies)

**Genre rows**: `HomeViewModel.genreRows: [(genre, items)]` — after loading resume/latest, fetches all genres via `getGenres(userId:includeItemTypes: [.movie, .series])`, shuffles and picks 4. Each genre's items are fetched in parallel via `TaskGroup` using `getItems(sortBy: [.random], genres: [genre], limit: 10, includeItemTypes: [.movie, .series])`. Empty genres are skipped; the 4 picks' order is preserved. Rendered as `ContentRow`s using `PosterCard` inside `NavigationLink` to `MediaDetailScreen`.

**Watching Now row**: `HomeViewModel.activeSessions` — fetched via `getActiveSessions(activeWithinSeconds: 60)`, filtered to drop the current user and sessions with no `nowPlayingItem`. Rendered with `WideCard` + a red "LIVE" pill overlay, navigates to the item's `MediaDetailScreen` on tap.

**Configurable layout** (`@AppStorage`, declared in `SettingsScreen.swift`, UI in Settings > Interface > Home Page):
| Key | Default | Row |
|-----|---------|-----|
| `home.showContinueWatching` | `true` | Continue Watching |
| `home.showRecentlyAdded` | `true` | Recently Added |
| `home.showGenreRows` | `true` | All 4 genre rows (block-level toggle) |
| `home.showWatchingNow` | `true` | Watching Now (other users) |

Hero is never gated — always renders when `heroItem` is non-nil.

**Refresh**: `.refreshable { await viewModel.reload(using: appState) }` on iOS. Both platforms observe `.cinemaxShouldRefreshCatalogue` (posted by Settings → Server → Refresh Catalogue) and call `viewModel.reload`. No in-page refresh pill — Settings is the single trigger. `HomeViewModel.reload(using:)` repopulates everything including genre rows, active sessions, and `resumeNavigation` (cleared before rebuild to avoid stale prev/next refs).

**Empty state**: when `heroItem`, `resumeItems`, `latestItems` and `genreRows` are all empty, renders `EmptyStateView` with a "Your library is empty" message and a Refresh action wrapped in a `ScrollView` so pull-to-refresh still works.

**Scroll-to-top on reappearance (tvOS)**: content is wrapped in `ScrollViewReader` with a zero-height `.id("home.top")` sentinel at the top. `.onAppear` fires `proxy.scrollTo("home.top", anchor: .top)` whenever the screen re-appears (after a deep nav pop or tab switch). This surfaces the system top tab bar which can otherwise stay hidden behind scrolled content. Same pattern applies in `MovieLibraryScreen`, `SearchScreen`, and Settings tvOS landing.

## SearchScreen

- `SearchViewModel.search(using:)` debounces by 400 ms then calls `searchItems(userId:searchTerm:limit:30)`
- iOS: microphone button launches `SpeechRecognitionHelper` (SFSpeechRecognizer + AVAudioEngine wrapper) for voice search
- **Surprise Me**: two pills ("Surprise movie" / "Surprise series") in the search empty state. Backed by `fetchRandomMovie(using:)` / `fetchRandomSeries(using:)` which call `getItems(includeItemTypes: [.movie or .series], sortBy: [.random], limit: 1)`. Two separate methods (not one parameterized) because Swift 6 strict concurrency flags a `[BaseItemKind]` array built from a function parameter as non-Sendable when crossing to the API actor — literal `[.movie]` / `[.series]` arrays work fine. On success pushes `MediaDetailScreen` via `navigationDestination(item:)`; on empty library emits an error toast
- **tvOS scroll-to-top**: wrapped in `ScrollViewReader` with a sentinel, `.onAppear` scrolls to top so the system tab bar resurfaces after a deep-nav pop

## Localization

- `LocalizationManager` (`@Observable`, injected from `AppNavigation`). Default: French (`fr`), also English (`en`)
- All strings via `loc.localized("key")` or `loc.localized("key", args...)` — never hardcoded
- Strings at `Resources/{lang}.lproj/Localizable.strings`
- Reactivity: `@ObservationIgnored` + `@AppStorage` + `_revision` counter pattern (same as `ThemeManager`)

## Toasts

- `ToastCenter` (`@Observable`, injected at `AppNavigation` root) — single-toast queue with auto-dismiss
- `ToastOverlay` renders a top-anchored glass pill (level-tinted SF Symbol + title + optional message) that slides in from the top safe area
- API: `.success(_:)`, `.error(_:)`, `.info(_:)`, all with optional `message:` and `duration:` parameters
- Use for: action feedback (Refresh Catalogue, user switch success), recoverable error surfaces. Do NOT use for critical errors that need user decision — use `UIAlertController` instead

## Empty states

- `EmptyStateView` (icon + title + optional subtitle + optional action button)
- Used by:
  - Home when `heroItem` / resume / latest / genre rows are all empty
  - Filtered library grid when sort + filter yields no results (offers "Clear filters" action that resets `LibrarySortFilterState()`)
  - `UserSwitchSheet` when user list is empty

## Dynamic Type (iOS)

- `.dynamicTypeSize(.xSmall ... .accessibility2)` applied at `AppNavigation` root — honors the user's OS-level text-size preference while capping below accessibility sizes that would break hero/tab-bar layouts
- `CinemaFont.dynamicBody / dynamicBodyLarge / dynamicLabel(_:)` variants use `UIFontMetrics(forTextStyle:).scaledValue(for:)` so the final size is `baseSize × CinemaScale.factor (app uiScale) × dynamicTypeMultiplier (OS)`
- Apply dynamic variants only to reading-heavy surfaces (overviews, settings rows, list cells). Hero / display / headline titles keep the fixed `CinemaFont.body` / `.headline()` variants to protect layout

## Image Patterns

- `ImageURLBuilder` → `/Items/{id}/Images/{type}` URLs
- **Backdrop sizing**: Use `ImageURLBuilder.screenPixelWidth` (device pixel width) for backdrops — never hardcode `1920`. Matches actual display density on all devices
- **Image cache**: `AppNavigation.init()` configures `ImagePipeline.shared` with a 500 MB disk cache (`com.cinemax.images`)
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
