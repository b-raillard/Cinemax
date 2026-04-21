# Cinemax - Jellyfin Client for Apple Platforms

Native Jellyfin media streaming client for iOS 18+ and tvOS 26+. "Cinema Glass" design system (dark glassmorphism, editorial layouts, no borders).

## Architecture

- **SwiftUI** multi-platform (single Xcode project, iOS + tvOS targets)
- **CinemaxKit** local Swift Package at `Packages/CinemaxKit` — shared networking, models, persistence
- **Swift 6** strict concurrency; **@Observable** + `@MainActor` for all state
- **JellyfinClient** wrapped with `NSLock` + `nonisolated(unsafe)` for Sendable conformance
- **iOS `NavigationStack` caveat**: destinations pushed via `navigationDestination(item:)` render in a separate context — `@Observable` changes to environment objects won't re-render the destination unless it is a standalone `View` struct with its own `@Environment` properties. Use a proper struct, not an extension method returning `some View`.

### Modern API requirements (iOS 18 / tvOS 26)

- **`UIButton`**: never use `UIButton(type:)` + `setTitle/setTitleColor/titleLabel?.font/backgroundColor/contentEdgeInsets`. Build with `UIButton.Configuration` (see the skip-intro button and debug "End" pill in `NativeVideoPresenter` for the pattern). Frosted background via `config.background.customView = UIVisualEffectView(...)`.
- **Free SwiftUI helpers**: free functions returning `some View` that touch SwiftUI types (`PrimitiveButtonStyle.plain`, `Font`, etc.) must be `@MainActor` under Swift 6 — those types are main-actor-isolated. The `iOSToggleRow` / `iOSToggleRowsJoined` / `iOSSettingsRow` helpers in `SettingsRowHelpers.swift` follow this.
- **iPad multitasking**: `UIRequiresFullScreen: true` in `project.yml`. Split view would interrupt playback and break hero/backdrop layouts; also satisfies the "all orientations unless full screen" warning. If ever changed, the iPhone orientation list must add `UIInterfaceOrientationPortraitUpsideDown`.

**Dependencies**: `jellyfin-sdk-swift` v0.6.0, `Nuke`/`NukeUI` v12.9.0, `AVKit`/`AVPlayer`

**API protocol split** (`Packages/CinemaxKit/.../APIClientProtocol.swift`): umbrella `APIClientProtocol` is a typealias for `ServerAPI & AuthAPI & LibraryAPI & PlaybackAPI`. View models needing multiple domains depend on `APIClientProtocol`; leaf controllers narrow to the slice they use (`PlaybackReporter` / `SkipSegmentController` → `any PlaybackAPI`). `JellyfinAPIClient` conforms to all four; `MockAPIClient` declares `APIClientProtocol` and inherits transparently.

**Swift 6 `nonisolated` escape hatches**:
1. `View, Equatable` sub-type inside an `@MainActor` screen needs `nonisolated static func ==` — `Equatable` isn't main-actor-isolated. See `PlayActionButtonsSection` in `MediaDetailScreen.swift`.
2. A `@MainActor` class's `static func` returning non-Sendable types (e.g. `[BaseItemDto]`) into a `TaskGroup.addTask @Sendable` closure needs `nonisolated private static func`. See `HomeViewModel.fetchGenreItems`.

Both safe when the body only reads its parameters.

## Project Structure

```
Shared/
  DesignSystem/Components/  CinemaLazyImage, ProgressBarView, RatingBadge, LoadingStateView, ErrorStateView, PosterCard, WideCard, ContentRow, CinemaButton, FlowLayout
  Navigation/               AppNavigation (auth routing), MainTabView (tab bar/sidebar)
  Screens/                  Home/Login/ServerSetup/Search/MediaDetail/MovieLibrary/TVSeries/Settings/VideoPlayer (+ NativeVideoPresenter, HLSManifestLoader, PlayLink, TrackPickerSheet, MediaQualityBadges, SettingsRowHelpers)
    VideoPlayer/            PlaybackReporter, SkipSegmentController, SleepTimerController
  ViewModels/               Home/Login/Search/ServerSetup/MediaDetail/MediaLibrary ViewModels, VideoPlayerCoordinator
iOS/ tvOS/                  app entry points
Resources/{fr,en}.lproj/    Localization (fr default)
Packages/CinemaxKit/        Models, Networking (JellyfinAPIClient, ImageURLBuilder), Persistence (KeychainService)
```

## Design System

- Color/font/spacing tokens in `CinemaGlassTheme.swift`. All `CinemaColor` tokens use `Color.dynamic(light:dark:)` backed by `UIColor(dynamicProvider:)` — they resolve against the active `UITraitCollection`. **Never use `Color(hex:)` for new tokens.**
- **Shared toggle**: `CinemaToggleIndicator` (Capsule+Circle pill, in `SettingsScreen.swift`) — used on both platforms. Parent-driven (wrap in `Button { value.toggle() }`). Never use system `Toggle` in settings.
- **No 1px borders** — use color shifts. Glass panels: `.glassPanel()`.
- **Dynamic accent**: `themeManager.accent` / `.accentContainer` / `.accentDim` / `.onAccent` — never `CinemaColor.tertiary*`. All four are dual-mode via `Color.dynamic`.
- **Dark/Light mode**: `ThemeManager.darkModeEnabled` → `.preferredColorScheme()` at root (set in `AppNavigation`, nowhere else). Colors flip via `UITraitCollection`. **Always route through `themeManager.darkModeEnabled =`** — direct `@AppStorage("darkMode")` writes bypass `_accentRevision` and break reactivity. Same for `themeManager.accentColorKey`.
- **Hardcoded `.white`/`.black`**: only acceptable inside the video player (always dark) and on elements sitting directly on a saturated `accentContainer`. Elsewhere use `CinemaColor.onSurface` / `.onSurfaceVariant`.
- **Font scaling**: `CinemaScale.factor` = 1.4× base on tvOS × user `uiScale` (80–130%). All `CinemaFont` and `CinemaScale.pt()` multiply by this. **Exception**: Play/Lecture button labels hardcode `28pt` on tvOS.
- **tvOS focus**: `@FocusState` + `.focusEffectDisabled()` + `.hoverEffectDisabled()`. Indicator is a 2px accent `strokeBorder` — no scale, no white bg. Cards: `CinemaTVCardButtonStyle`. Settings rows: `.tvSettingsFocusable()`. **Trait-collection caveat**: a focused `Button` overrides the `UITraitCollection` inside its label, flipping all `Color.dynamic` tokens to light-mode values. `tvSettingsFocusable` takes a `colorScheme` parameter and injects `.environment(\.colorScheme, colorScheme)` on both content and background shape. Always pass `colorScheme: themeManager.darkModeEnabled ? .dark : .light`.
- **iOS focus**: `.cinemaFocus()` (accent border + shadow).
- **Motion Effects**: `motionEffectsEnabled` env key (from `AppNavigation` via `@AppStorage("motionEffects")`). When off, all `.animation()` calls use `nil`. Consumed by `CinemaFocusModifier`, `CinemaTVButtonStyle`, `CinemaTVCardButtonStyle`, toggle indicators.
- Platform-adaptive layouts: `#if os(tvOS)` or `horizontalSizeClass`.

## Navigation

- `AppNavigation` → Keychain session check → `apiClient.reconnect()` + `fetchServerInfo()`. Injects `ThemeManager`, `LocalizationManager`, `ToastCenter`; applies `.preferredColorScheme()` at root.
- No server → `ServerSetupScreen` → `LoginScreen` → `MainTabView` (top tabs on tvOS, sidebar on iPad, bottom tabs on iPhone).
- All play buttons use `PlayLink<Label>` (Button+coordinator on tvOS, NavigationLink on iOS) — never direct `NavigationLink` to `VideoPlayerView`.

## Media Library (`MediaLibraryScreen`)

Unified screen parameterized by `BaseItemKind` (movies or series).

**Sort & Filter state** (`LibrarySortFilterState`):
- Default: `dateCreated` descending. `isNonDefault` = sort or filter differs from default.
- `isFiltered` = genre chips selected OR `showUnwatchedOnly` OR `selectedDecades` non-empty.
- **Browse vs filtered**: browse view (genre rows) whenever `isFiltered == false`, regardless of sort. Any filter switches to the flat filtered grid.
- **Title count** uses `isFiltered` (not `isNonDefault`) — sort-only changes don't affect count. Shows `filteredTotalCount` when filtered, `totalCount` otherwise.
- Sort change → `reloadGenreItems`; filter change → `applyFilter`.
- `loadInitial` guarded by `hasLoaded` (prevents re-randomization on tab switch). `reload(using:)` bypasses the guard — triggered by pull-to-refresh (iOS) and `.cinemaxShouldRefreshCatalogue`.

**Filters**:
- Unwatched → `filters: [.isUnplayed]`.
- Decade: `selectedDecades: Set<Int>` (starting year, e.g. `1980`). `expandedYears` explodes into every concrete year for `getItems(years:)`. UI: 1950s–2020s chips.

**tvOS filter bar**: inline (not modal) — sort pills + watch-status + decade + genre chips (`FlowLayout`, multi-line) + Reset. `TVFilterChipButtonStyle` for chip focus.

**iOS alphabetical jump bar**: `AlphabeticalJumpBar` (Contacts-style capsule, ultraThinMaterial, right edge). Uses `ScrollViewReader` + `proxy.scrollTo(firstItemID(for: letter))` + `UISelectionFeedbackGenerator` per-letter haptics. Only rendered when `sortBy == .sortName && sortAscending && items.count > 20`.

## Video Playback

### Playback Flow
1. `getItem()` — fetch full metadata.
2. Resolve non-playable items: Series → `getNextUp()` or first episode; Season → first episode. **Series/Season have no media sources — must resolve to Episode first.**
3. POST PlaybackInfo with `DeviceProfile` (`isAutoOpenLiveStream=true`, `mediaSourceID`, `userID`).
4. Build stream URL: `transcodingURL` if present (HLS), else direct stream `/Videos/{id}/stream?static=true&...`.
5. Fallback: direct stream without PlaybackInfo session.

**DeviceProfile**: DirectPlay for mp4/m4v/mov + h264/hevc; transcode to HLS mp4 with `hevc,h264` only. **Never include `mpeg4`** — not a valid HLS transcode target on Apple platforms; causes Jellyfin to inject `mpeg4-*` URL params AVFoundation doesn't recognise. `maxBitrate`: 120 Mbps (4K) or 20 Mbps (1080p) via `@AppStorage("render4K")`.

### Native Player (`NativeVideoPresenter.swift`)

Both platforms use native `AVPlayerViewController` presented via UIKit modal (`UIViewController.present()`). Three `@MainActor` sub-controllers in `Shared/Screens/VideoPlayer/` own cohesive slices:
- `PlaybackReporter` — reportStart/Stop/Background + periodic progress (10-tick throttle).
- `SkipSegmentController` — intro/outro affordance (iOS floating UIButton / tvOS `contextualActions`). Loads segments per item, cancels in-flight fetches on teardown, shows/hides purely from `onTick(currentTime:)`.
- `SleepTimerController` — countdown + "Still watching?" prompt. Presenter owns `playerVC` lifecycle, passes a `playerVCProvider` closure + `onStopPlayback` callback.

Presenter keeps **one** `addPeriodicTimeObserver` (1 s) and fans ticks to both `skipSegments.onTick` + `playbackReporter.onTick`. Sub-controllers never add their own observers — preserves the single-observer invariant.

- **MUST present via UIKit modal**, not SwiftUI — SwiftUI presentation corrupts `TabView`/`NavigationSplitView` focus on dismiss.
- **iOS dismiss detection**: `PlayerHostingVC` wrapper with `viewWillDisappear(isBeingDismissed:)`.
- **tvOS dismiss detection**: `TVDismissDelegate` using `playerViewControllerDidEndDismissalTransition`. Do NOT embed `AVPlayerViewController` as a child VC on tvOS — causes internal constraint conflicts and `-12881`.

**Audio track menus**: injected via `transportBarCustomMenuItems` — first-class on tvOS, accessed via ObjC runtime KVC on iOS (marked `API_UNAVAILABLE(ios)` in SDK but exists on iOS 16+). Shows Jellyfin track names instead of AVKit's "Unknown".

**Subtitles**:
- **iOS**: `enableSubtitlesInManifest: true` + `.hls` profiles → Jellyfin includes WebVTT renditions. `HLSManifestLoader` (`AVAssetResourceLoaderDelegate` with `cinemax-https://` custom scheme) strips `#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS` from playlists and ASS/SSA tags (`{\i1}`, `{\b}`, `{comments}`) from VTT segments. AVKit shows one unified native Subtitles menu. **Fallback**: `HLSManifestLoader` can also fail with `-12881` on iOS — `retryWithDirectURL` automatically retries with the direct HLS URL (no custom scheme). ASS tags won't be stripped on fallback. `hasRetriedDirectURL` resets on episode navigation.
- **tvOS**: `HLSManifestLoader` does NOT work (`AVAssetResourceLoaderDelegate` causes `-12881` with `AVPlayerViewController`); HLS URL used directly. ASS tags may appear in subtitle text.
- **`HLSManifestLoader` key constraint**: `contentInformationRequest.contentType` must be a **UTI**, not a MIME type. `"public.m3u-playlist"` for M3U8, `"org.w3.webvtt"` for VTT. For segment types, skip `contentType`.

**Episode navigation**: `MPRemoteCommandCenter` prev/next track on both platforms. `EpisodeRef` + `EpisodeNavigator` + `buildEpisodeNavigation` (free function in `PlayLink.swift`). `PlayLink` carries `previousEpisode`, `nextEpisode`, `episodeNavigator` through `VideoPlayerCoordinator` (tvOS) or `VideoPlayerView` (iOS) → `NativeVideoPresenter`. `itemId` / `startTime` are `var` and rebound in `navigateToEpisode` (startTime → `nil`) so new episodes report under their own identity.

**Auto-play next**: `AVPlayerItem.didPlayToEndTime` → `navigateToEpisode(next)` when `autoPlayNextEpisode` is on.

**Skip Intro / Credits**: requires the **Intro Skipper** plugin. On start and episode navigation, fetches `getMediaSegments(itemId:includeSegmentTypes: [.intro, .outro])`. Visibility is **pure time-based**: `checkSegments` shows/hides based on `currentTime ∈ [segment.start, segment.end)`. Re-entry works naturally — rewinding re-shows. Click seeks to `segment.end`; the next tick clears. Keys: `player.skipIntro`, `player.skipCredits`.

Rendering:
- **iOS**: floating `UIButton` (UIBlurEffect bg, bottom-right) added to `AVPlayerViewController.view`.
- **tvOS**: `AVPlayerViewController.contextualActions = [UIAction(…)]`. This is the ONLY mechanism that produces a focusable action button coexisting with the transport-bar focus context. **Custom subviews / overlay modals / `preferredFocusEnvironments` overrides are unreachable on tvOS while AVPlayerViewController is on screen** — the player locks its focus environment. Applies to any future in-player affordance — use `contextualActions` or other native APIs.

**Chapters** (tvOS only): built from `BaseItemDto.chapters` and applied via `AVPlayerItem.navigationMarkerGroups = [AVNavigationMarkersGroup(...)]`. Each marker carries `commonIdentifierTitle` + optional `commonIdentifierArtwork` (JPEG from `ImageURLBuilder.chapterImageURL(itemId:imageIndex:)`). `AVNavigationMarkersGroup` is tvOS-only in AVKit; iOS has no native chapter scrubber so that path is `#if os(tvOS)` no-op.

**Sleep timer**: `SleepTimerOption` enum (`Off` / 15 / 30 / 45 / 60 / 90 min) backed by `@AppStorage("sleepTimerDefaultMinutes")`. `currentDefaultSeconds` returns 15 s when `debug.fastSleepTimer` is on, else stored option. Moon-icon blur pill `mm:ss` bottom-left. On fire, pauses + shows "Still watching?" — `UIAlertController` on tvOS, custom blur card on iOS. "Keep watching" restarts; "Stop" dismisses.

**End-of-series completion**: when `didPlayToEndTime` fires with autoplay on, no next episode, `episodeNavigator != nil` — shows centered "You finished {Series Name}" overlay. `currentSeriesName` captured from the same `getItem` that fetches chapters. tvOS `UIAlertController`, iOS custom blur card.

**Picture-in-Picture** (iOS): `allowsPictureInPicturePlayback = true` + `canStartPictureInPictureAutomaticallyFromInline = true` (auto-PiP when user backgrounds app). Lifecycle in `IOSPlayerDelegate` (file-private in `NativeVideoPresenter`): `willStart` flips `isInPictureInPicture = true` and clears `didRestoreFromPiP`; modal auto-dismisses, `PlayerHostingVC.shouldFireOnDismiss` consults `isInPictureInPicture` to suppress cleanup. `restoreUserInterfaceForPictureInPictureStop…` flips `didRestoreFromPiP = true` and re-presents via `restoreFromPiP` (new `PlayerHostingVC` around the same retained `playerVC`). `didStopPictureInPicture` runs full cleanup **only** when `didRestoreFromPiP == false`. `PiPRestoreHandlerBox` (`@unchecked Sendable`) wraps the non-Sendable AVKit completion handler so Swift 6 region analysis accepts it inside `MainActor.assumeIsolated`. `PlayerHostingVC.viewDidLoad` defensively detaches `playerVC` from any prior parent — restore reuses the same controller.

**AirPlay / external playback** (iOS): `UIBackgroundModes = [audio, airplay]` in `project.yml` — required so playback continues when iPhone locks during a cast. `present` calls `activatePlaybackAudioSession()` before handing the item to the player (`.playback` + `.moviePlayback`), sets `allowsExternalPlayback = true` and `usesExternalPlaybackWhileExternalScreenIsActive = true`, and deactivates in `cleanup()` with `.notifyOthersOnDeactivation`. Picker drawn natively by transport bar. `SearchViewModel` voice-search briefly flips category to `.record` — do not start voice search during active playback.

**Error recovery**: `showPlaybackErrorAlert(error:)` — `-12881 / -12886 / -16170` → transcode guidance, `-12938 / -1001 / -1004 / -1005 / -1009` → network, else generic. On iOS the alert fires only after `retryWithDirectURL` itself fails (so we don't interrupt silent first-try recovery). `isShowingErrorAlert` prevents stacking.

**Debug tooling** (Settings → Interface → Debug, always visible, not `#if DEBUG`-gated):
- `debug.fastSleepTimer` — overrides sleep duration to 15 s.
- `debug.showSkipToEnd` — iOS purple "End" pill top-right; tvOS injects into `transportBarCustomMenuItems`. Seeks to `(duration − 15 s)` for previewing end-of-series overlay.

## Settings Screen

### Layout — two-level navigation

**Landing**:
- **tvOS**: split — left (brand: `AppLogo` + title + version), right (4 nav pills). Centered accent bloom in `.background {}` persists across all settings pages. No intermediate panel backgrounds.
- **iOS**: vertical scroll — logo header, 4 nav buttons (first accent-highlighted), device info footer. `NavigationStack` + `navigationDestination(item:)`.

**Detail pages** (Appearance, Account, Server, Interface):
- tvOS: `ScrollView` with back button at top. Menu button → `.onExitCommand { selectedCategory = nil }`.
- iOS: pushed via `NavigationStack`.

### tvOS focus rules
- Each row is a **single focusable unit** — never individual sub-items.
- Accent color row: left/right cycle colors; select cycles. Uses `onMoveCommand`.
- Language row: left/right or select toggles fr↔en. `onMoveCommand`.
- Category pills on landing: focused = `accentContainer` fill + scale 1.05 + glow.
- Back button: `.focused($focusedItem, equals: .back)`, highlighted with accent.

### Settings row SSOT (`SettingsRowHelpers.swift` + platform extensions)

Every boolean toggle is declared once as `SettingsToggleRow` and rendered on both platforms from the same list. Four catalogue properties on `SettingsScreen` — `interfaceToggleRows`, `homePageToggleRows`, `detailPageToggleRows`, `debugToggleRows` — are authoritative. Adding/renaming a toggle is a one-line `.init(id:icon:label:value:)` edit.

- `SettingsToggleRow` — `id`, `icon`, `label`, `value: Binding<Bool>`, optional `tint`.
- `iOSToggleRowsJoined(_ rows:accent:animated:)` — iOS `@MainActor @ViewBuilder` expander (rows + dividers).
- `tvToggleList(_ rows:)` — tvOS expander. Ignores `row.tint`; tvOS uses `themeManager.accent` uniformly. iOS-only debug-orange `tint:` consumed by `iOSToggleRowsJoined` only.
- `tvActionRow(id:icon:label:subtitle:showsChevron:action:)` — tvOS "tappable row with icon + title + optional subtitle + optional chevron". Two overloads (generic `.toggle(id)` focus or any `SettingsFocus` case). Consolidates Refresh Catalogue, Refresh Connection, Licenses.
- iOS row atoms (reused by `navigationRow` + `iOSToggleRow` + bespoke rows): `iOSSettingsRow`, `iOSRowIcon`, `iOSSettingsDivider`, `iOSSettingsSectionHeader`, `iOSToggleRow`, `navigationRow(icon:label:action:)`.
- tvOS row atom: `tvGlassToggle(icon:label:key:value:)`.

### Assets
- `AppLogo.imageset`: iOS `app_logo.png` (full icon); tvOS `app_logo_tv.png` (front parallax layer — transparent bg, jellyfish only). No `clipShape` on tvOS logo.

### `@AppStorage` keys (shared iOS/tvOS, declared in `SettingsScreen`)
| Key | Default | Effect |
|-----|---------|--------|
| `motionEffects` | `true` | `motionEffectsEnabled` env key — disables all animations when off |
| `forceSubtitles` | `false` | Auto-selects first `.legible` track; disables `appliesMediaSelectionCriteriaAutomatically` |
| `render4K` | `true` | `maxBitrate` 120 Mbps (on) / 20 Mbps (off) |
| `autoPlayNextEpisode` | `true` | Auto-navigates next via `didPlayToEndTime` |
| `sleepTimerDefaultMinutes` | `0` | Sleep timer duration (0/15/30/45/60/90) via `SleepTimerOption` |
| `uiScale` | `1.0` | Font scale 80–130%. Bumps `_accentRevision` |
| `darkMode` | `true` | **Toggle via `themeManager.darkModeEnabled`**, not directly |
| `accentColor` | `"blue"` | Set via `themeManager.accentColorKey` for same reason |
| `home.showContinueWatching` | `true` | Continue Watching row |
| `home.showRecentlyAdded` | `true` | Recently Added row |
| `home.showGenreRows` | `true` | All 4 genre rows |
| `home.showWatchingNow` | `true` | Watching Now row |
| `detail.showQualityBadges` | `true` | Quality pill row on `MediaDetailScreen` |
| `debug.fastSleepTimer` | `false` | Overrides sleep to 15 s |
| `debug.showSkipToEnd` | `false` | "End" button seeking to `(duration − 15 s)` |

### Quick user switch
`UserSwitchSheet` (Settings → Account) — two-step: user grid → password prompt → re-auth. Updates `AppState.accessToken` / `currentUserId`, calls `apiClient.reconnect(url:accessToken:)` without clearing server URL, emits success toast, dismisses. Errors stay inline.

### Refresh Catalogue (single trigger)
Settings → Server has "Refresh Catalogue" → `apiClient.clearCache()` + posts `.cinemaxShouldRefreshCatalogue`. `HomeScreen` and `MediaLibraryScreen` observe this and reload. Success toast. **No per-page refresh buttons** — Settings is the single source of truth. iOS also gets `.refreshable { reload() }`.

### Debug section
Always visible (not `#if DEBUG`-gated) so QA / power users don't need a custom build. Icons orange to signal developer territory.

## MediaDetailScreen

- `MediaDetailViewModel` auto-resolves Episode/Season → parent Series (by `seriesID`, loads seasons + episodes) and calls `getNextUp()` to populate `nextUpEpisode`. `selectSeason()` uses a generation counter to discard stale results on rapid selection.
- `nextUpEpisodes: [BaseItemDto]` — when `nextUpEpisode.seasonID ≠ selectedSeasonId`, the next-up's season is fetched separately so `episodeNavigation(for:)` can build prev/next for the resume button.
- Use `resolvedType` (not initial `itemType`) for layout decisions.
- tvOS overview text uses `.focusable()` for focus-driven scrolling past non-interactive content.
- **tvOS detail refresh**: `VideoPlayerCoordinator.lastDismissedAt: Date?` updated via `onDismiss` (triggered by `TVDismissDelegate`); `MediaDetailScreen` observes `.onChange(of: coordinator.lastDismissedAt)` to reload after dismiss (iOS reloads automatically via `.task` on NavigationLink pop).

**Resume / next-up in `actionButtons`**: parent `actionButtons(_:)` resolves data and delegates rendering to `PlayActionButtonsSection: View, Equatable` (bottom of `MediaDetailScreen.swift`). Custom `nonisolated static func ==` compares resume state + prev/next episode identity and explicitly ignores the `epNavigator` closure — so `.equatable()` short-circuits re-renders when unrelated VM state changes.
- Movie with `playbackPositionTicks > 0` and not `isPlayed`: progress bar (accent, `playButtonWidth`) + `loc.remainingTime(minutes:)` + "Lecture" resuming via `PlayLink(startTime:)`.
- Series: uses `viewModel.nextUpEpisode`. In-progress → progress bar + remaining + resume. Finished/next → episode label + play. Falls back to series-level play if no next-up.
- **Play from beginning**: when `showResume`, a secondary ghost `PlayLink` (`detail.playFromBeginning`, `backward.end.fill`) under the resume button with `startTime: nil`.
- `userData.playbackPositionTicks` and `runTimeTicks` are `Int?` (not `Int64`); `isPlayed` is `userData.isPlayed: Bool?`.
- Episode rows show thin accent progress overlay at thumbnail bottom for partially-watched episodes.

**Quality badges** (`MediaQualityBadges.swift`): pill row between `actionButtons` and overview. Gated on `@AppStorage("detail.showQualityBadges")`. Derived from `item.mediaSources?.first` — first `.video` stream for resolution/HDR/codec, default audio stream (`defaultAudioStreamIndex`) for format/channels.
- Resolution by height: "4K" / "1080p" / "720p" / "SD".
- HDR: `VideoRangeType` → "Dolby Vision" (any `dovi*`), "HDR10+", "HDR10", "HDR" (for `hlg`); `VideoRange.hdr` as fallback. No badge for SDR.
- Video codec: "HEVC" (hevc/h265), "H.264", "AV1", "VP9", else uppercased raw.
- Audio format (first-hit): Atmos (from `profile`/`displayTitle`), TrueHD, "Dolby Digital+" (EAC3), "Dolby Digital" (AC3), DTS, AAC, FLAC, Opus, MP3, else uppercased raw.
- Channels: `channelLayout` uppercased (Stereo/Mono title-cased); fallback from count (8→7.1, 6→5.1, 2→Stereo, 1→Mono).
- Returns `EmptyView()` when no streams produce badges.

**Episode navigation wiring**: `episodeNavigation(for:)` is O(1) lookup from precomputed `viewModel.episodeNavigationMap` (current season) or `nextUpNavigationMap` (cross-season next-up). Both `actionButtons` and each `episodeRow` pass `previousEpisode`, `nextEpisode`, `episodeNavigator` to `PlayLink`.

**Ratings row**: backdrop-adjacent. `communityRating` (yellow star + `%.1f`) and `criticRating` (Rotten-Tomatoes-style — green if ≥ 60, red otherwise — + `%d%%`). Either or both optional.

**Studio / Network label** (`studioLine`): below overview. Up to 2 names from `item.studios`. Label "STUDIO" for movies, "NETWORK" for series. `EmptyView` when empty.

**Episode metadata line** (`episodeMetadataLine`): shared by tvOS `episodeRow` and iOS `iOSEpisodeCard`. Joined with ` • `:
- In-progress (not `isPlayed`, `ticks > 0`, remaining > 0): "Xm remaining" via `loc.remainingTime(minutes:)`.
- Else if `runTimeTicks > 0`: total runtime via `detail.runtime.min`.
- Plus `premiereDate` as `.dateTime.month(.abbreviated).day().year()` when present.

## HomeScreen

- `HomeViewModel` loads `resumeItems` + `latestItems` in parallel via `TaskGroup`.
- `heroItem = resumeItems.first ?? latestItems.first`.
- **Resume navigation**: for each resume episode, season's episode list is fetched (grouped by `seasonID` to dedupe). `precomputeEpisodeRefs(_:)` (in `PlayLink.swift`) builds `(refs, indexByID)` once per season; each episode calls the O(1) `buildEpisodeNavigation(for:refs:indexByID:apiClient:userId:)` overload. Results in `resumeNavigation: [String: (previous, next, navigator)]`. `MediaDetailViewModel.makeNavigationMap(from:)` uses the same helper.
- Hero and each "Reprendre" `PlayLink` pass `startTime` (from `ticks / 10_000_000`, nil for no-progress items) + `previousEpisode`/`nextEpisode`/`episodeNavigator` from `resumeNavigation[id]` (nil for movies).

**Genre rows**: `genreRows: [GenreRow]` where `state` is `.items([BaseItemDto])` or `.failed`. After resume/latest, fetches all genres via `getGenres(userId:includeItemTypes: [.movie, .series])`, shuffles, picks 4. Items fetched in parallel via `TaskGroup` (`getItems(sortBy: [.random], genres: [genre], limit: 10, includeItemTypes: [.movie, .series])`). Empty-success rows dropped; **failures become `.failed`** so UI renders a retry capsule (wired to `retryGenre(_:using:)`) — transient errors don't make content silently disappear.

**Watching Now**: `activeSessions` via `getActiveSessions(activeWithinSeconds: 60)`, filtered to drop current user and sessions without `nowPlayingItem`. `WideCard` + red "LIVE" pill overlay.

**Configurable layout** (all default `true`): `home.showContinueWatching`, `home.showRecentlyAdded`, `home.showGenreRows` (block-level), `home.showWatchingNow`. Hero is never gated.

**Empty state**: when `heroItem`, resume, latest, and genre rows are all empty → `EmptyStateView` with Refresh action, wrapped in `ScrollView` so pull-to-refresh still works.

**Scroll-to-top on reappearance (tvOS)**: content wrapped in `ScrollViewReader` with a zero-height `.id("home.top")` sentinel. `.onAppear` fires `proxy.scrollTo("home.top", anchor: .top)` so the system top tab bar resurfaces after deep-nav pop or tab switch. Same pattern in `MovieLibraryScreen`, `SearchScreen`, and Settings tvOS landing.

## SearchScreen

- `SearchViewModel.search(using:)` debounces 400 ms → `searchItems(userId:searchTerm:limit:30)`.
- **Decomposition**: `SearchScreen.swift` owns the shell; file-private structs at bottom — `VoiceSearchButton` (iOS-only, owns `isPulsing`) and `SearchResultsGrid` + `SearchResultCard`. Lets SwiftUI skip grid diff on parent state changes.
- iOS mic → `SpeechRecognitionHelper` (SFSpeechRecognizer + AVAudioEngine wrapper).
- **Surprise Me**: two pills in the empty state. `fetchRandomMovie(using:)` / `fetchRandomSeries(using:)` call `getItems(includeItemTypes: [.movie or .series], sortBy: [.random], limit: 1)`. Two separate methods (not parameterized) because Swift 6 flags a `[BaseItemKind]` built from a parameter as non-Sendable when crossing to the API actor — literal arrays work fine. Success pushes `MediaDetailScreen` via `navigationDestination(item:)`; empty library emits error toast.

## Localization

- `LocalizationManager` (`@Observable`, injected from `AppNavigation`). Default `fr`, also `en`.
- All strings via `loc.localized("key")` / `loc.localized("key", args...)` — never hardcoded.
- Strings at `Resources/{lang}.lproj/Localizable.strings`.
- Reactivity: `@ObservationIgnored` + `@AppStorage` + `_revision` counter (same as `ThemeManager`).
- Plural-aware helpers on `LocalizationManager` (e.g. `remainingTime(minutes:)` picks `home.remainingTime.hours` vs `.minutes`). Use the helper, not inline branching.

## Toasts

- `ToastCenter` (`@Observable`, injected at `AppNavigation` root) — single-toast queue with auto-dismiss.
- `ToastOverlay` renders a top-anchored glass pill (level-tinted SF Symbol + title + optional message).
- API: `.success(_:)`, `.error(_:)`, `.info(_:)` with optional `message:` and `duration:`.
- Use for action feedback and recoverable errors. NOT for critical errors needing a user decision — use `UIAlertController`.

## Empty states

`EmptyStateView` (icon + title + optional subtitle + optional action). Used by: Home when everything empty; filtered library grid when no results (offers "Clear filters" that resets `LibrarySortFilterState()`); `UserSwitchSheet` when empty.

## Dynamic Type (iOS)

- `.dynamicTypeSize(.xSmall ... .accessibility2)` at `AppNavigation` root — honors OS text-size preference while capping below accessibility sizes that break hero/tab-bar layouts.
- `CinemaFont.dynamicBody / dynamicBodyLarge / dynamicLabel(_:)` use `UIFontMetrics(forTextStyle:).scaledValue(for:)` so final size is `baseSize × CinemaScale.factor (app uiScale) × dynamicTypeMultiplier (OS)`.
- Apply dynamic variants only to reading-heavy surfaces. Hero/display/headline titles keep fixed `CinemaFont.body` / `.headline()` to protect layout.

## Image Patterns

- `ImageURLBuilder` → `/Items/{id}/Images/{type}`.
- **Backdrop sizing**: use `ImageURLBuilder.screenPixelWidth` — never hardcode `1920`.
- **Image cache**: `AppNavigation.init()` configures `ImagePipeline.shared` with a 500 MB disk cache (`com.cinemax.images`).
- **Backdrop fallback**: `item.parentBackdropItemID ?? item.seriesID ?? item.id`.
- **All image loading via `CinemaLazyImage`** — never `LazyImage` directly. Params: `url`, `fallbackIcon: String?`, `fallbackBackground: Color`, `showLoadingIndicator: Bool`.
- **Card containers**: `Color.clear` + `.aspectRatio()` + `.frame(maxWidth: .infinity)` + `.overlay { CinemaLazyImage }` + `.clipped()`.
- **Backdrop (full-bleed ZStack)**: `CinemaLazyImage` inside a `ZStack` must have `.frame(maxWidth: .infinity, maxHeight: .infinity)` — otherwise ZStack sizes from the image's natural dimensions (e.g. 1920px), pushing the title VStack off-screen. Outer container must be `LazyVStack(alignment: .leading)`.
- **PosterCard title alignment**: hidden `Text("M\nM").hidden()` placeholder + actual title overlaid top-aligned → uniform row height.

## App Icons

- **iOS**: `Resources/Assets.xcassets/AppIcon.appiconset/` — 1024×1024 in three variants (light, dark, tinted).
- **tvOS**: `Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets/` — 3-layer parallax imagestack + Top Shelf (1920×720) + Top Shelf Wide (2320×720).
- **In-app logo**: `Resources/Assets.xcassets/AppLogo.imageset/` — iOS full icon; tvOS front parallax layer only (transparent bg).
- **Standalone source**: `appIcon.png` at project root.

## Build

```bash
# iOS
xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# tvOS
xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'

# Regenerate Xcode project
cd Cinemax && xcodegen generate
```
