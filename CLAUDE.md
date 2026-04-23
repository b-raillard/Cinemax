# Cinemax - Jellyfin Client for Apple Platforms

Native Jellyfin media streaming client for iOS 26+ and tvOS 26+. "Cinema Glass" design system (dark glassmorphism, editorial layouts, no borders).

## Architecture

- **SwiftUI** multi-platform (single Xcode project, iOS + tvOS targets)
- **CinemaxKit** local Swift Package at `Packages/CinemaxKit` — shared networking, models, persistence
- **Swift 6** strict concurrency; **@Observable** + `@MainActor` for all state
- **JellyfinClient** wrapped with `NSLock` + `nonisolated(unsafe)` for Sendable conformance
- **iOS `NavigationStack` caveat**: destinations pushed via `navigationDestination(item:)` render in a separate context — `@Observable` changes to environment objects won't re-render the destination unless it is a standalone `View` struct with its own `@Environment` properties. Use a proper struct, not an extension method returning `some View`.

### Modern API requirements (iOS 26 / tvOS 26)

- **`UIButton`**: never use `UIButton(type:)` + `setTitle/setTitleColor/titleLabel?.font/backgroundColor/contentEdgeInsets`. Build with `UIButton.Configuration` (see the skip-intro button and debug "End" pill in `NativeVideoPresenter` for the pattern). Frosted background via `config.background.customView = UIVisualEffectView(...)`.
- **Free SwiftUI helpers**: free functions returning `some View` that touch SwiftUI types (`PrimitiveButtonStyle.plain`, `Font`, etc.) must be `@MainActor` under Swift 6 — those types are main-actor-isolated. The `iOSToggleRow` / `iOSToggleRowsJoined` / `iOSSettingsRow` helpers in `SettingsRowHelpers.swift` follow this.
- **iPad multitasking**: `UIRequiresFullScreen` was removed with the iOS 26 bump (Apple deprecated it and will ignore it in a future release). Both iPhone and iPad orientation lists include `UIInterfaceOrientationPortraitUpsideDown` to silence the "all orientations must be supported" warning. iPad split view / Stage Manager is therefore allowed at runtime — hero/backdrop layouts and playback-through-resize have not been hardened for that yet, so expect visual glitches on resized iPad windows until that work is done.
- **Toolbar buttons + Liquid Glass**: in iOS 26, navigation-bar `ToolbarItem` buttons are automatically rendered with Liquid Glass by the system. **Do not add `.buttonStyle(.glass)` / `.glassProminent` on toolbar items** — it nests a second glass capsule inside the toolbar's own container (see `MovieLibraryScreen.filterButton`). Signal active state with `.tint(themeManager.accent)` + a `.fill` icon variant instead.

**Dependencies**: `jellyfin-sdk-swift` v0.6.0, `Nuke`/`NukeUI` v12.9.0, `AVKit`/`AVPlayer`

**API protocol split** (`Packages/CinemaxKit/.../APIClientProtocol.swift`): umbrella `APIClientProtocol` is a typealias for `ServerAPI & AuthAPI & LibraryAPI & PlaybackAPI & AdminAPI`. View models needing multiple domains depend on `APIClientProtocol`; leaf controllers narrow to the slice they use (`PlaybackReporter` / `SkipSegmentController` → `any PlaybackAPI`). `JellyfinAPIClient` conforms to all five; `MockAPIClient` declares `APIClientProtocol` and inherits transparently. `AdminAPI` is a privilege boundary (not a domain) — admin screens gate entry on `AppState.isAdministrator` so non-admins never reach those methods in the first place.

**Swift 6 `nonisolated` escape hatches**:
1. `View, Equatable` sub-type inside an `@MainActor` screen needs `nonisolated static func ==` — `Equatable` isn't main-actor-isolated. See `PlayActionButtonsSection` in `MediaDetailScreen.swift`.
2. A `@MainActor` class's `static func` returning non-Sendable types (e.g. `[BaseItemDto]`) into a `TaskGroup.addTask @Sendable` closure needs `nonisolated private static func`. See `HomeViewModel.fetchGenreItems`.

Both safe when the body only reads its parameters.

## Project Structure

```
Shared/
  DesignSystem/             CinemaGlassTheme, ThemeManager, AccentOption (+ AccentEasterEgg), LocalizationManager, ToastCenter, GlassModifiers, FocusScaleModifier, AdaptiveLayout, TVButtonStyles, SettingsKeys, SleepTimerOption
  DesignSystem/Components/  CinemaButton, CinemaLazyImage, PosterCard, WideCard, CastCircle, ContentRow, ProgressBarView, RatingBadge, GlassTextField, FlowLayout, ToastOverlay, EmptyStateView, ErrorStateView, LoadingStateView, AlphabeticalJumpBar, CinemaToggleIndicator, RainbowAccentSwatch, MediaQualityBadges, UserAvatar
  Navigation/               AppNavigation (auth routing), MainTabView (tab bar/sidebar)
  Screens/                  HomeScreen, LoginScreen, ServerSetupScreen, SearchScreen, MediaDetailScreen, MovieLibraryScreen, TVSeriesScreen, SettingsScreen (+ SettingsScreen+iOS, +tvOS, SettingsAppearanceView+iOS, SettingsRowHelpers, PrivacySecurityScreen, LicensesView), VideoPlayerView, NativeVideoPresenter, HLSManifestLoader, PlayLink, TrackPickerSheet, LibraryGenreRow, LibraryHeroSection, LibraryPosterCard, LibrarySortFilterSheet, ServerDiscoverySheet, ServerHelpSheet, UserSwitchSheet
    VideoPlayer/            PlaybackReporter, SkipSegmentController, SleepTimerController
    Admin/                  (iOS-only) AdminLandingScreen, AdvancedAdminLandingScreen, Dashboard/, Users/, Devices/, Activity/, Tasks/, Plugins/, Catalog/, Playback/, Network/, Logs/, ApiKeys/, Metadata/
    Admin/Components/       AdminLoadStateContainer, AdminFormScreen, AdminTabBar, AdminSectionGroup, DestructiveConfirmSheet, AdminComingSoonScreen
  ViewModels/               Home/Login/Search/ServerSetup/MediaDetail/MediaLibrary ViewModels, VideoPlayerCoordinator
iOS/ tvOS/                  app entry points
Resources/{fr,en}.lproj/    Localization (fr default)
Packages/CinemaxKit/        Models, Networking (JellyfinAPIClient, ImageURLBuilder), Persistence (KeychainService)
docs/design-system/         Canonical design system reference (colors, typography, components, patterns, platforms, conventions)
```

> `Shared/Screens/` is flat — no `Settings/` or `Home/` subfolders. `PlayLink.swift` intentionally stays in `Screens/` because it knows about `VideoPlayerView` (iOS) and `VideoPlayerCoordinator` (tvOS) — making it a design-system component would invert the dependency direction. `SettingsRowHelpers.swift` also stays because the tvOS renderers in `SettingsScreen+tvOS.swift` capture `@FocusState` from the screen.
>
> **Exception**: `Shared/Screens/Admin/` is grouped by feature (Dashboard/Users/Devices/Activity/…). The admin surface holds 30+ files by the time Metadata Manager lands in P3b; a flat folder would be unreadable.

## Design System

**Before editing any UI surface, read `docs/design-system/README.md` and the relevant topic file (colors / typography / spacing-layout / motion / components / patterns / platforms / conventions). The PR rejection checklist in `conventions.md` codifies load-bearing rules — consult it before adding borders, literal fonts, or new tokens.** The bullets below are a quick summary; the `docs/design-system/` folder is authoritative.

- Color/font/spacing tokens in `CinemaGlassTheme.swift`. All `CinemaColor` tokens use `Color.dynamic(light:dark:)` backed by `UIColor(dynamicProvider:)` — they resolve against the active `UITraitCollection`. **Never use `Color(hex:)` for new tokens.**
- **Shared toggle**: `CinemaToggleIndicator` (Capsule+Circle pill, in `DesignSystem/Components/`) — used on both platforms. Parent-driven (wrap in `Button { value.toggle() }`). Never use system `Toggle` in settings.
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

## Server Setup & Login

Two-step pre-auth flow with a shared mobile design language so users perceive Server → Login as one journey. The two screens' `mobileLayout`s share: same icon block (rounded `surfaceContainerHigh` rect + accent-tinted symbol + shadow), same tracked label / big black title / centered subtitle (max 280pt), same glass-panel form, same primary `CinemaButton` + helper-link footer.

**Server discovery** (`JellyfinServerDiscovery` in CinemaxKit + `ServerDiscoverySheet`):
- UDP `"Who is JellyfinServer?"` broadcast on port 7359, listen for JSON `{Address,Id,Name}` replies.
- Probes both the limited broadcast (`255.255.255.255`) **and** each interface's directed broadcast (e.g. `192.168.1.255`) via `getifaddrs` — many consumer routers drop the limited form but pass directed.
- `ServerDiscoverySheet.scan()` clears `servers` at start (visible transition), then auto-retries once after 800ms when the first scan returns empty — covers the iPhone case where the very first probe races the iOS local-network permission prompt and gets silently blocked before the user can approve. Also re-scans on `scenePhase == .active` for the "user toggled Local Network in Settings.app and came back" path. iOS needs `NSLocalNetworkUsageDescription` in `iOS/Info.plist` (already declared).

**`AppState.disconnectServer()`**: clears keychain server URL + flips `hasServer = false` so `AppNavigation` sends the user back to `ServerSetupScreen`. Surfaced as the "Change server" helper link in the bottom action area of `LoginScreen.mobileLayout`. Doesn't touch auth state — the user isn't authenticated at that point.

**LoginScreen mobile layout caveat**: ServerSetupScreen's form uses `.padding(.horizontal, spacing4)` outside the `.glassPanel` to set its visual margin. The same modifier chain in `LoginScreen.mobileLayout` is silently dropped under iOS 26 (root cause untracked — possibly related to the multi-`GlassTextField` + `.ultraThinMaterial` interaction). Workaround: `.frame(maxWidth: formMaxWidth)` (350pt) on both the form panel and the actions VStack, letting the outer VStack center them. Don't "fix" this back to padding without verifying with pixel sampling.

**Rainbow accent easter egg**: the rounded-icon block at the top of both mobile layouts is a `Button` that triggers `AccentEasterEgg.tap(…)` (pure resolver in `SettingsScreen.swift`). Each tap advances through `AccentOption.cyclingCases` (the 9 base accents) with a light haptic. When `previousTapCount + 1 >= cycle.count` and rainbow is still locked, the resolver returns `unlockedRainbow: true`; the screen then flips `@AppStorage(SettingsKey.rainbowUnlocked) = true`, applies `AccentOption.rainbow`, plays a success haptic, and emits a `toasts.success(…)` using `easterEgg.rainbow.title` / `.message`. `rainbow` has a placeholder palette because `ThemeManager` checks `isRainbow` first and returns HSB colors driven by `_rainbowHue` — a `Task { @MainActor }` advances the hue every ~33 ms while rainbow is the active accent and bumps `_accentRevision`; the task self-cancels as soon as the user picks a static accent (no cost outside easter-egg state). Pickers use `AccentOption.visibleCases(rainbowUnlocked:)` to hide rainbow until unlocked and `RainbowAccentSwatch` (conic gradient) as its preview dot on both platforms.

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

### `@AppStorage` keys (key names + defaults in `SettingsKey` / `SettingsKey.Default` — `Shared/DesignSystem/SettingsKeys.swift`)
| Key | Default | Effect |
|-----|---------|--------|
| `motionEffects` | `true` | `motionEffectsEnabled` env key — disables all animations when off |
| `forceSubtitles` | `false` | Auto-selects first `.legible` track; disables `appliesMediaSelectionCriteriaAutomatically` |
| `render4K` | `true` | `maxBitrate` 120 Mbps (on) / 20 Mbps (off) |
| `autoPlayNextEpisode` | `true` | Auto-navigates next via `didPlayToEndTime` |
| `sleepTimerDefaultMinutes` | `0` | Sleep timer duration (0/15/30/45/60/90) via `SleepTimerOption` |
| `uiScale` | `1.0` | Font scale 80–130%. Bumps `_accentRevision` |
| `darkMode` | `true` | **Toggle via `themeManager.darkModeEnabled`**, not directly |
| `accentColor` | `"green"` | Set via `themeManager.accentColorKey` for same reason |
| `home.showContinueWatching` | `true` | Continue Watching row |
| `home.showRecentlyAdded` | `true` | Recently Added row |
| `home.showGenreRows` | `true` | All 4 genre rows |
| `home.showWatchingNow` | `true` | Watching Now row |
| `detail.showQualityBadges` | `true` | Quality pill row on `MediaDetailScreen` |
| `privacy.maxContentAge` | `0` | Content rating ceiling (years). `0` = unrestricted; 10/12/14/16/18 hide items rated above the ceiling. Applied via `apiClient.applyContentRatingLimit` |
| `debug.fastSleepTimer` | `false` | Overrides sleep to 15 s |
| `debug.showSkipToEnd` | `false` | "End" button seeking to `(duration − 15 s)` |
| `easterEgg.rainbowUnlocked` | `false` | Unlocks the rainbow accent in the picker — flipped by the logo-tap easter egg on Server/Login mobile screens |

### Quick user switch
`UserSwitchSheet` (Settings → Account) — two-step: user grid → password prompt → re-auth. Updates `AppState.accessToken` / `currentUserId`, calls `apiClient.reconnect(url:accessToken:)` without clearing server URL, emits success toast, dismisses. Errors stay inline.

### Refresh Catalogue (single trigger)
Settings → Server has "Refresh Catalogue" → `apiClient.clearCache()` + posts `.cinemaxShouldRefreshCatalogue`. `HomeScreen` and `MediaLibraryScreen` observe this and reload. Success toast. **No per-page refresh buttons** — Settings is the single source of truth. iOS also gets `.refreshable { reload() }`.

### Debug section
Always visible (not `#if DEBUG`-gated) so QA / power users don't need a custom build. Icons orange to signal developer territory.

## Admin Section (iOS / iPadOS only)

Admin workflows are mobile-only by product decision — the admin Settings categories are filtered out of the tvOS landing (`SettingsCategory.visibleCases(isAdmin:isTVOS:)` short-circuits when `isTVOS == true`), and every file under `Shared/Screens/Admin/` is wrapped in `#if os(iOS)` so tvOS compiles it as an empty module.

**Gating** — `AppState.isAdministrator` (cached, refreshed on login / reconnect / user switch via `AppState.refreshCurrentUser()`). Every admin entry point reads this flag. The server is the authoritative authorization boundary; client gating is UX only — non-admins who somehow reach an admin endpoint just get a 401/403 surfaced as a toast. `AppState.currentUser: UserDto?` is populated alongside the flag so screens (Settings profile header, admin Users grid) can reuse the same primary-image tag without re-fetching.

**API surface** — `AdminAPI` protocol slice in `APIClientProtocol.swift`. The umbrella is now a 5-way typealias: `ServerAPI & AuthAPI & LibraryAPI & PlaybackAPI & AdminAPI`. Device listing/revocation stays on `AuthAPI` (the server returns the full fleet to admins and the caller's own devices otherwise — same endpoint, different payload by caller identity).

**Settings routing** — two new categories, `.administration` (Dashboard + Metadata Manager) and `.advancedAdmin` (Users/Devices/Activity/Playback/Plugins/Catalog/Tasks/Network/Logs/API Keys). Both hidden when `!appState.isAdministrator`. P2/P3 entries currently land on `AdminComingSoonScreen` so the menu shape is navigable from day one.

**Generic scaffolds** (`Shared/Screens/Admin/Components/`):
- `AdminLoadStateContainer` — loading / error / empty / content switcher. Used by every admin list or grid so failure modes feel consistent.
- `AdminFormScreen` — sticky `Sauvegarder` footer + `interactiveDismissDisabled(isDirty)` + discard-changes confirmation. **Every admin editor uses explicit save (never auto-save)** — admin-scoped changes have blast radius (policy revocations, password resets), so the user must intentionally confirm.
- `AdminTabBar` — horizontally-scrolling segmented pills (user detail's 4 tabs, metadata editor's 5 tabs in P3b).
- `AdminSectionGroup` — iOS grouped-list section (header + glass panel + optional footer).
- `DestructiveConfirmSheet` — type-to-confirm sheet reserved for truly irreversible operations (delete user, delete item in P3b). Reversible destructives (revoke device, uninstall plugin) use `.confirmationDialog` with `.destructive` role instead.

**Shared component** — `UserAvatar` (primary image + accent-gradient+initial fallback) collapses three identical implementations (`UserSwitchSheet`, Settings profile header, admin Users grid). Always tries the image request when a `userId` is given — `CinemaLazyImage.fallbackBackground = .clear` lets the gradient show through on 404/loading.

**Self-protection (client-side; server enforces too)**:
- Can't delete yourself (Users detail hides the toolbar delete menu when editing self).
- Can't demote/disable yourself (those toggles render disabled with a hint when editing self).
- Can't revoke the current device (`KeychainService.getOrCreateDeviceID()` compared against `DeviceInfoDto.id`; the swipe action is elided on that row and a "THIS DEVICE" pill renders instead).
- Creating users: optimistic local append + sort — avoids a second round-trip just to see the new row.

**Performance** — Dashboard fans out with `async let` so one slow endpoint doesn't gate the other (and a single failure still renders partial data rather than an error). Activity log uses infinite-scroll pagination (50/page) triggered on last-row `.onAppear`. Users / Devices lists are small enough to load fully; view models cache them and support optimistic local mutations (remove after delete, append after create). Admin gate is cached on `AppState` — refreshed only on login / reconnect / user switch, never per-view.

**Phasing** — P1 ships Dashboard / Users / Devices / Activity. **P2 ships** Playback (encoding defaults via `getNamedConfiguration(key: "encoding")` round-tripped through `AnyJSON`) / Installed Plugins (enable/disable/uninstall; `PluginStatus` badge signals restart-pending) / Plugin Catalog (search-and-install from server-configured repos) / Scheduled Tasks (grouped by category with live progress polling every 2 s while any task is running, self-cancels when none are). **P3a ships** Network (read-mostly + safe edits for ports / base URL / LAN subnets / features; explicit-confirm dialog before save since mis-config can lock clients out) / Logs (list + monospace viewer, tail-truncated at 200 KB, `.privacySensitive()`, no share sheet) / API Keys. **P3b ships** the Metadata Manager — five-tab item editor (General / Images / Cast / Identify / Actions), accessible from Settings → Metadata Manager (library picker → items grid → editor) and from `MediaDetailScreen` via an admin-gated "Edit metadata" button next to Play. Images use `downloadRemoteImage` so the server fetches from a URL rather than proxying bytes through the phone. Identify is scoped to `.movie` and `.series` in P3b (other kinds render a friendly "not supported" notice). Delete goes through `DestructiveConfirmSheet` with the item title as the type-to-confirm phrase.

**ImageType quirk** — CinemaxKit declares its own narrow `ImageType` enum (Primary/Backdrop/Thumb/Logo/Banner — the set the standard UI needs) in `ImageURLBuilder.swift`. `JellyfinAPI.ImageType` has the full 13-case enum (adds Disc, Art, BoxRear, Screenshot, Menu, Chapter, Profile, …). Admin metadata code uses `JellyfinAPI.ImageType` explicitly-qualified to avoid ambiguity, and `ImageURLBuilder` exposes an `imageURLRaw(itemId:imageTypeRaw:)` string-keyed overload so admin image slots can render the wider set without widening `CinemaxKit.ImageType`.

**API key security model** (`Shared/Screens/Admin/ApiKeys/`) — keys grant full admin access, so UI treats them like passwords:
- Masked by default (first 4 + last 4 chars, dots between). Per-row `eye` button toggles reveal; reveal state is transient (`revealedKeyIds: Set<Int>` dropped on `onDisappear`).
- Token text is `.privacySensitive()` so iOS redacts it during screen mirroring / Control Center capture.
- Copy button per row is the only export path — no share sheet (minimises accidental leak surface).
- `appState.accessToken` is compared against each key's `accessToken`; the match is tagged `CURRENT SESSION` and its revoke action is hidden entirely (revoking our own would log us out).
- Create flow refetches the list, identifies the new key by id-delta (not timestamp, which could collide), and auto-opens a dedicated "copy this now" modal. Done button explicit — no tap-outside-to-dismiss surprise.
- Never log key values, never send to analytics/error reports. `revokeApiKey` takes the token itself as the identifier (Jellyfin quirk); callers should forget the value as soon as the call returns.

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
- **Backdrop fallback**: use `item.backdropItemID` (→ `parentBackdropItemID ?? seriesID ?? id`) from `BaseItemDto+Metadata`.
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
