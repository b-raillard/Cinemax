# Cinemax - Jellyfin Client for Apple Platforms

Native Jellyfin client for iOS 26+ and tvOS 26+. "Cinema Glass" design system (dark glassmorphism, editorial layouts, no borders).

## Architecture

- **SwiftUI** multi-platform (single Xcode project, iOS + tvOS targets)
- **CinemaxKit** local Swift Package at `Packages/CinemaxKit` — networking, models, persistence
- **Swift 6** strict concurrency; `@Observable` + `@MainActor` for all state
- **JellyfinClient** wrapped with `NSLock` + `nonisolated(unsafe)` for Sendable
- **iOS `NavigationStack` caveat**: destinations pushed via `navigationDestination(item:)` render in a separate context — `@Observable` changes won't re-render unless the destination is a standalone `View` struct with its own `@Environment` properties, not an extension method returning `some View`.

### iOS 26 / tvOS 26 API rules

- **`UIButton`**: use `UIButton.Configuration`; never `UIButton(type:)` + `setTitle/titleLabel?.font/backgroundColor/contentEdgeInsets`. Pattern in `NativeVideoPresenter` (skip-intro button, debug "End" pill). Frosted bg via `config.background.customView = UIVisualEffectView(...)`.
- **Free SwiftUI helpers** returning `some View` that touch `PrimitiveButtonStyle.plain`/`Font`/etc. must be `@MainActor` under Swift 6.
- **iPad multitasking**: `UIRequiresFullScreen` removed (deprecated). iPad split view / Stage Manager allowed — hero/backdrop layouts not yet hardened for resize, expect glitches.
- **Toolbar + Liquid Glass**: iOS 26 auto-renders `ToolbarItem` buttons with Liquid Glass. **Never** add `.buttonStyle(.glass)` / `.glassProminent` on toolbar items — nests double capsules. Signal active state via `.tint(themeManager.accent)` + `.fill` icon variant.

**Dependencies**: `jellyfin-sdk-swift` v0.6.0, `Nuke`/`NukeUI` v12.9.0, `AVKit`/`AVPlayer`

**API protocol split** (`Packages/CinemaxKit/.../APIClientProtocol.swift`): `APIClientProtocol = ServerAPI & AuthAPI & LibraryAPI & PlaybackAPI & AdminAPI`. View models needing multiple domains take `APIClientProtocol`; leaf controllers narrow to a slice (`PlaybackReporter` / `SkipSegmentController` → `any PlaybackAPI`). `AdminAPI` is a privilege boundary — gated on `AppState.isAdministrator`; server enforces authoritatively.

**Swift 6 `nonisolated` escape hatches** (safe when body only reads parameters):
1. `View, Equatable` sub-type inside a `@MainActor` screen needs `nonisolated static func ==` — `Equatable` isn't main-actor-isolated. See `PlayActionButtonsSection` in `MediaDetailScreen.swift`.
2. A `@MainActor` class's `static func` returning non-Sendable types into a `TaskGroup @Sendable` closure needs `nonisolated private static func`. See `HomeViewModel.fetchGenreItems`.

## Project Structure

```
Shared/
  DesignSystem/             CinemaGlassTheme, ThemeManager, AccentOption (+ AccentEasterEgg), LocalizationManager, ToastCenter, GlassModifiers, FocusScaleModifier, AdaptiveLayout, TVButtonStyles, SettingsKeys, SleepTimerOption
  DesignSystem/Components/  CinemaButton, CinemaLazyImage, PosterCard, WideCard, CastCircle, ContentRow, ProgressBarView, RatingBadge, GlassTextField, FlowLayout, ToastOverlay, EmptyStateView, ErrorStateView, LoadingStateView, AlphabeticalJumpBar, CinemaToggleIndicator, RainbowAccentSwatch, MediaQualityBadges, UserAvatar
  Navigation/               AppNavigation (auth routing), MainTabView
  Screens/                  Home/Login/ServerSetup/Search/MediaDetail/MovieLibrary/TVSeries/Settings screens, VideoPlayerView, NativeVideoPresenter, HLSManifestLoader, PlayLink, sheets/helpers
    VideoPlayer/            PlaybackReporter, SkipSegmentController, SleepTimerController
    Admin/                  (iOS-only) Dashboard/Users/Devices/Activity/Tasks/Plugins/Catalog/Playback/Network/Logs/ApiKeys/Metadata/Identify
    Admin/Components/       AdminLoadStateContainer, AdminFormScreen, AdminTabBar, AdminSectionGroup, AdminItemMenu, DestructiveConfirmSheet, AdminComingSoonScreen
  ViewModels/               per-screen view models + VideoPlayerCoordinator
iOS/ tvOS/                  app entry points
Resources/{fr,en}.lproj/    Localization (fr default)
Packages/CinemaxKit/        Models, Networking (JellyfinAPIClient, ImageURLBuilder), Persistence (KeychainService)
docs/design-system/         Canonical design system reference
```

`Shared/Screens/` is flat (no `Settings/`/`Home/` subfolders). `PlayLink.swift` stays in `Screens/` because it knows about `VideoPlayerView`/`VideoPlayerCoordinator`. `SettingsRowHelpers.swift` stays because tvOS renderers capture `@FocusState`. Exception: `Shared/Screens/Admin/` is feature-grouped (30+ files).

## Design System

**Before editing UI: read `docs/design-system/README.md` and the relevant topic file. The PR rejection checklist in `conventions.md` is authoritative.** Summary:

- Tokens in `CinemaGlassTheme.swift`. All `CinemaColor` use `Color.dynamic(light:dark:)` via `UIColor(dynamicProvider:)`. **Never `Color(hex:)` for new tokens.**
- **Shared toggle**: `CinemaToggleIndicator` (Capsule+Circle pill). Parent-driven (`Button { value.toggle() }`). Never system `Toggle` in settings.
- **No 1px borders** — use color shifts. Glass panels: `.glassPanel()`.
- **Accent**: `themeManager.accent` / `.accentContainer` / `.accentDim` / `.onAccent` — never `CinemaColor.tertiary*`. All dual-mode.
- **Dark/Light mode**: `ThemeManager.darkModeEnabled` → `.preferredColorScheme()` at root (in `AppNavigation` only). Colors flip via `UITraitCollection`. **Always route through `themeManager.darkModeEnabled =`** — direct `@AppStorage("darkMode")` writes bypass `_accentRevision` and break reactivity. Same for `themeManager.accentColorKey`.
- **Hardcoded `.white`/`.black`**: only inside the video player (always dark) and on elements on saturated `accentContainer`. Else `CinemaColor.onSurface` / `.onSurfaceVariant`.
- **Font scaling**: `CinemaScale.factor` = 1.4× base on tvOS × user `uiScale` (80–130%). Exception: Play/Lecture button labels hardcode 28pt on tvOS.
- **tvOS focus**: `@FocusState` + `.focusEffectDisabled()` + `.hoverEffectDisabled()`. 2px accent `strokeBorder`, no scale/white bg. Cards: `CinemaTVCardButtonStyle`. Settings rows: `.tvSettingsFocusable()`. **Trait caveat**: a focused `Button` flips `UITraitCollection` inside its label to light-mode values; `tvSettingsFocusable` takes `colorScheme` and injects it on both content and background shape — always pass `themeManager.darkModeEnabled ? .dark : .light`.
- **iOS focus**: `.cinemaFocus()` (accent border + shadow).
- **CinemaButton styles**: `.accent` = primary CTAs (saturated `accentContainer` + `.white` text — Play/Login/ServerSetup/every admin save). `.primary` = neutral gradient, survives only on `DestructiveConfirmSheet`. `.ghost` = secondary (Retry, Clear Filters).
- **Motion Effects**: `motionEffectsEnabled` env key (from `@AppStorage("motionEffects")`). When off, all `.animation()` → nil. Consumed by `CinemaFocusModifier`, `CinemaTVButtonStyle`, `CinemaTVCardButtonStyle`, toggle indicators.
- Platform-adaptive: `#if os(tvOS)` or `horizontalSizeClass`.

## Navigation

- `AppNavigation` → Keychain session check → `apiClient.reconnect()` + `fetchServerInfo()`. Injects `ThemeManager`, `LocalizationManager`, `ToastCenter`; applies `.preferredColorScheme()` at root.
- Flow: no server → `ServerSetupScreen` → `LoginScreen` → `MainTabView` (top tabs on tvOS, sidebar on iPad, bottom tabs on iPhone).
- All play buttons use `PlayLink<Label>` (Button+coordinator on tvOS, `NavigationLink` on iOS) — never direct `NavigationLink` to `VideoPlayerView`.

## Server Setup & Login

Two-step pre-auth flow. Shared mobile design (icon block, tracked label / big black title / centered subtitle, glass-panel form, primary `CinemaButton` + helper-link footer) so Server → Login feels like one journey.

**Server discovery** (`JellyfinServerDiscovery` + `ServerDiscoverySheet`):
- UDP `"Who is JellyfinServer?"` broadcast on port 7359, JSON `{Address,Id,Name}` replies.
- Probes both the limited broadcast (`255.255.255.255`) **and** each interface's directed broadcast via `getifaddrs` — many consumer routers drop limited but pass directed.
- `scan()` clears `servers` at start, auto-retries once after 800ms on empty (handles the iOS local-network permission race where the first probe is silently blocked). Re-scans on `scenePhase == .active`. `NSLocalNetworkUsageDescription` in `iOS/Info.plist`.

**`AppState.disconnectServer()`**: clears keychain server URL + `hasServer = false` → `ServerSetupScreen`. Surfaced as "Change server" in `LoginScreen.mobileLayout`. Doesn't touch auth state (user isn't authenticated yet).

**LoginScreen mobile caveat**: ServerSetupScreen's `.padding(.horizontal, spacing4)` outside `.glassPanel` works there but is silently dropped in `LoginScreen.mobileLayout` under iOS 26 (root cause untracked — likely multi-`GlassTextField` + `.ultraThinMaterial`). Workaround: `.frame(maxWidth: formMaxWidth)` (350pt) on form panel + actions VStack, outer VStack centers. Don't "fix" without pixel-sampling.

**Rainbow accent easter egg**: icon block at top of both mobile layouts is a `Button` → `AccentEasterEgg.tap(…)` (resolver in `SettingsScreen.swift`). Each tap advances `AccentOption.cyclingCases` (9 base accents) with light haptic. When `previousTapCount + 1 >= cycle.count` and rainbow still locked, resolver returns `unlockedRainbow: true`; screen flips `@AppStorage(SettingsKey.rainbowUnlocked) = true`, applies `.rainbow`, success haptic + toast. Rainbow palette is placeholder — `ThemeManager` checks `isRainbow` first and returns HSB colors driven by `_rainbowHue` (Task advances every ~33ms, self-cancels on static accent). Pickers use `AccentOption.visibleCases(rainbowUnlocked:)` and `RainbowAccentSwatch`.

## Media Library (`MediaLibraryScreen`)

Unified, parameterized by `BaseItemKind` (movies or series).

**Sort & Filter** (`LibrarySortFilterState`):
- Default: `dateCreated` descending. `isNonDefault` = sort or filter differs.
- `isFiltered` = genre chips OR `showUnwatchedOnly` OR `selectedDecades` non-empty.
- **Browse vs filtered**: browse (genre rows) when `!isFiltered`, regardless of sort. Any filter → flat grid.
- Title count uses `isFiltered` (not `isNonDefault`) — sort-only changes don't affect count. `filteredTotalCount` when filtered else `totalCount`.
- Sort change → `reloadGenreItems`; filter change → `applyFilter`.
- `loadInitial` guarded by `hasLoaded` (prevents re-randomization on tab switch). `reload(using:)` bypasses — triggered by pull-to-refresh and `.cinemaxShouldRefreshCatalogue`.

**Filters**:
- Unwatched → `filters: [.isUnplayed]`.
- Decade: `selectedDecades: Set<Int>` (starting year). `expandedYears` explodes for `getItems(years:)`. UI: 1950s–2020s chips.

**tvOS filter bar**: inline — sort pills + watch-status + decade + genre chips (`FlowLayout`) + Reset. `TVFilterChipButtonStyle`.

**iOS jump bar**: `AlphabeticalJumpBar` (right edge, Contacts-style, `ultraThinMaterial`). `ScrollViewReader` + `proxy.scrollTo(firstItemID(for: letter))` + `UISelectionFeedbackGenerator`. Only when `sortBy == .sortName && sortAscending && items.count > 20`.

## Video Playback

### Flow
1. `getItem()` — full metadata.
2. Resolve non-playable: Series → `getNextUp()` or first episode; Season → first episode. **Must resolve to Episode — Series/Season have no media sources.**
3. POST PlaybackInfo with `DeviceProfile` (`isAutoOpenLiveStream=true`, `mediaSourceID`, `userID`).
4. Build URL: `transcodingURL` (HLS) if present, else `/Videos/{id}/stream?static=true&...`.
5. Fallback: direct stream without PlaybackInfo session.

**DeviceProfile**: DirectPlay for mp4/m4v/mov + h264/hevc; transcode to HLS mp4 with `hevc,h264` only. **Never include `mpeg4`** — not a valid HLS transcode target on Apple; causes Jellyfin to inject `mpeg4-*` URL params AVFoundation rejects. `maxBitrate`: 120 Mbps (4K) / 20 Mbps (1080p) via `@AppStorage("render4K")`.

### Native Player (`NativeVideoPresenter.swift`)

Both platforms use `AVPlayerViewController` presented via UIKit modal (`UIViewController.present()`). Three `@MainActor` sub-controllers in `Shared/Screens/VideoPlayer/`:
- `PlaybackReporter` — reportStart/Stop/Background + periodic progress (10-tick throttle).
- `SkipSegmentController` — intro/outro (iOS floating UIButton / tvOS `contextualActions`). Cancels in-flight fetches on teardown.
- `SleepTimerController` — countdown + "Still watching?" prompt. Presenter passes `playerVCProvider` closure + `onStopPlayback` callback.

Presenter keeps **one** `addPeriodicTimeObserver` (1s) and fans ticks to both `skipSegments.onTick` + `playbackReporter.onTick`. Sub-controllers never add their own observers.

- **MUST present via UIKit modal** — SwiftUI presentation corrupts `TabView`/`NavigationSplitView` focus on dismiss.
- **iOS dismiss detection**: `PlayerHostingVC` wrapper with `viewWillDisappear(isBeingDismissed:)`.
- **tvOS dismiss detection**: `TVDismissDelegate` using `playerViewControllerDidEndDismissalTransition`. Do NOT embed `AVPlayerViewController` as a child VC on tvOS — causes internal constraint conflicts and `-12881`.

**Audio track menus**: via `transportBarCustomMenuItems` — first-class on tvOS, ObjC KVC on iOS (marked `API_UNAVAILABLE(ios)` in SDK but exists on iOS 16+). Shows Jellyfin track names instead of AVKit's "Unknown".

**Subtitles**:
- **iOS**: `enableSubtitlesInManifest: true` + `.hls` profiles → WebVTT renditions. `HLSManifestLoader` (`AVAssetResourceLoaderDelegate` with `cinemax-https://` custom scheme) strips `#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS` from playlists and ASS/SSA tags (`{\i1}`, `{\b}`, `{comments}`) from VTT. AVKit shows one unified Subtitles menu. **Fallback**: `HLSManifestLoader` can also fail with `-12881` — `retryWithDirectURL` retries with direct HLS URL (no custom scheme; ASS tags won't strip on fallback). `hasRetriedDirectURL` resets on episode navigation.
- **tvOS**: `HLSManifestLoader` does NOT work (`AVAssetResourceLoaderDelegate` causes `-12881`); direct URL. ASS tags may appear.
- **`HLSManifestLoader` key constraint**: `contentInformationRequest.contentType` must be a **UTI**, not MIME: `"public.m3u-playlist"` (M3U8), `"org.w3.webvtt"` (VTT). Skip `contentType` for segment types.

**Episode navigation**: `MPRemoteCommandCenter` prev/next on both. `EpisodeRef` + `EpisodeNavigator` + `buildEpisodeNavigation` in `PlayLink.swift`. `PlayLink` carries `previousEpisode`/`nextEpisode`/`episodeNavigator` through `VideoPlayerCoordinator` (tvOS) or `VideoPlayerView` (iOS) → presenter. `itemId`/`startTime` are `var`, rebound in `navigateToEpisode` (startTime → `nil`) so new episodes report under their own identity.

**Auto-play next**: `AVPlayerItem.didPlayToEndTime` → `navigateToEpisode(next)` when `autoPlayNextEpisode` on.

**Skip Intro/Credits**: requires **Intro Skipper** plugin. Fetches `getMediaSegments(itemId:includeSegmentTypes: [.intro, .outro])` on start and episode nav. Pure time-based: `checkSegments` shows/hides based on `currentTime ∈ [segment.start, segment.end)`. Re-entry works (rewinding re-shows). Click seeks to `segment.end`. Keys: `player.skipIntro`, `player.skipCredits`.

Rendering:
- **iOS**: floating `UIButton` (UIBlurEffect bg, bottom-right) on `AVPlayerViewController.view`.
- **tvOS**: `AVPlayerViewController.contextualActions = [UIAction(…)]`. **This is the ONLY mechanism that produces a focusable action button coexisting with the transport-bar focus context** — custom subviews / overlay modals / `preferredFocusEnvironments` overrides are unreachable on tvOS while `AVPlayerViewController` is on screen. Applies to any future in-player affordance.

**Chapters** (tvOS only): from `BaseItemDto.chapters` → `AVPlayerItem.navigationMarkerGroups = [AVNavigationMarkersGroup(...)]`. Each marker carries `commonIdentifierTitle` + optional `commonIdentifierArtwork` (JPEG from `ImageURLBuilder.chapterImageURL(itemId:imageIndex:)`). `AVNavigationMarkersGroup` is tvOS-only; iOS path is `#if os(tvOS)` no-op.

**Sleep timer**: `SleepTimerOption` enum (Off/15/30/45/60/90 min) via `@AppStorage("sleepTimerDefaultMinutes")`. `currentDefaultSeconds` returns 15s when `debug.fastSleepTimer` on. Moon-icon blur pill bottom-left. On fire: pauses + "Still watching?" — `UIAlertController` (tvOS), custom blur card (iOS).

**End-of-series completion**: `didPlayToEndTime` + autoplay + no next + `episodeNavigator != nil` → "You finished {Series Name}" overlay. `currentSeriesName` captured with the same `getItem` that fetches chapters.

**Picture-in-Picture** (iOS): `allowsPictureInPicturePlayback = true` + `canStartPictureInPictureAutomaticallyFromInline = true`. `IOSPlayerDelegate` (file-private): `willStart` flips `isInPictureInPicture = true` and clears `didRestoreFromPiP`; modal auto-dismisses, `PlayerHostingVC.shouldFireOnDismiss` suppresses cleanup. `restoreUserInterfaceForPictureInPictureStop…` flips `didRestoreFromPiP = true` and re-presents via `restoreFromPiP` (new `PlayerHostingVC` around same retained `playerVC`). `didStopPictureInPicture` runs full cleanup **only** when `didRestoreFromPiP == false`. `PiPRestoreHandlerBox` (`@unchecked Sendable`) wraps the non-Sendable AVKit completion handler for Swift 6 region analysis. `PlayerHostingVC.viewDidLoad` defensively detaches `playerVC` from any prior parent.

**AirPlay** (iOS): `UIBackgroundModes = [audio, airplay]` in `project.yml` — required so playback continues when iPhone locks during a cast. `present` calls `activatePlaybackAudioSession()` (`.playback` + `.moviePlayback`), sets `allowsExternalPlayback = true` + `usesExternalPlaybackWhileExternalScreenIsActive = true`; `cleanup()` deactivates with `.notifyOthersOnDeactivation`. `SearchViewModel` voice-search briefly flips category to `.record` — do not start voice search during active playback.

**Error recovery**: `showPlaybackErrorAlert(error:)` — `-12881 / -12886 / -16170` → transcode guidance, `-12938 / -1001 / -1004 / -1005 / -1009` → network, else generic. On iOS the alert fires only after `retryWithDirectURL` itself fails. `isShowingErrorAlert` prevents stacking.

**Debug tooling** (Settings → Interface → Debug, always visible):
- `debug.fastSleepTimer` — sleep → 15s.
- `debug.showSkipToEnd` — iOS purple "End" pill top-right; tvOS injects into `transportBarCustomMenuItems`. Seeks to `(duration − 15s)` for previewing end-of-series overlay.

## Settings Screen

### Layout — two-level navigation

**Landing**:
- **tvOS**: split — left brand (`AppLogo` + title + version), right 4 nav pills. Centered accent bloom in `.background {}` persists across all pages.
- **iOS**: vertical scroll — logo header, 4 nav buttons (first accent-highlighted), device info footer. `NavigationStack` + `navigationDestination(item:)`.

**Detail pages** (Appearance, Account, Server, Interface):
- tvOS: `ScrollView` with back button. Menu button → `.onExitCommand { selectedCategory = nil }`.
- iOS: pushed via `NavigationStack`.

### tvOS focus rules
- Each row is a **single focusable unit** — never individual sub-items.
- Accent row / Language row: left/right or select cycles. `onMoveCommand`.
- Category pills (landing): focused = `accentContainer` fill + scale 1.05 + glow.
- Back button: `.focused($focusedItem, equals: .back)`, accent-highlighted.

### Settings row SSOT (`SettingsRowHelpers.swift` + platform extensions)

Every boolean toggle declared once as `SettingsToggleRow`, rendered on both platforms from the same list. Four catalogue properties on `SettingsScreen`: `interfaceToggleRows` / `homePageToggleRows` / `detailPageToggleRows` / `debugToggleRows`. Adding/renaming a toggle is a one-line edit.

- `SettingsToggleRow` — `id, icon, label, value: Binding<Bool>`, optional `tint`.
- `iOSToggleRowsJoined(_:accent:animated:)` — iOS `@MainActor @ViewBuilder` expander.
- `tvToggleList(_:)` — tvOS expander. Ignores `row.tint`; uses `themeManager.accent` uniformly. `tint:` is iOS-only (debug-orange).
- `tvActionRow(id:icon:label:subtitle:showsChevron:action:)` — tvOS tappable row. Two overloads. Consolidates Refresh Catalogue / Refresh Connection / Licenses.
- iOS row atoms: `iOSSettingsRow`, `iOSRowIcon`, `iOSSettingsDivider`, `iOSSettingsSectionHeader`, `iOSToggleRow`, `navigationRow(icon:label:action:)`.
- tvOS row atom: `tvGlassToggle(icon:label:key:value:)`.

### Assets
`AppLogo.imageset`: iOS `app_logo.png` (full icon); tvOS `app_logo_tv.png` (front parallax layer — transparent bg, jellyfish only). No `clipShape` on tvOS logo.

### `@AppStorage` keys (in `SettingsKey` / `SettingsKey.Default` — `Shared/DesignSystem/SettingsKeys.swift`)
| Key | Default | Effect |
|-----|---------|--------|
| `motionEffects` | `true` | `motionEffectsEnabled` env — disables all animations when off |
| `forceSubtitles` | `false` | Auto-selects first `.legible`; disables `appliesMediaSelectionCriteriaAutomatically` |
| `render4K` | `true` | `maxBitrate` 120/20 Mbps |
| `autoPlayNextEpisode` | `true` | Auto-nav via `didPlayToEndTime` |
| `sleepTimerDefaultMinutes` | `0` | 0/15/30/45/60/90 via `SleepTimerOption` |
| `uiScale` | `1.0` | Font scale 80–130%. Bumps `_accentRevision` |
| `darkMode` | `true` | **Via `themeManager.darkModeEnabled`**, not directly |
| `accentColor` | `"green"` | **Via `themeManager.accentColorKey`** |
| `home.showContinueWatching` | `true` | Continue Watching row |
| `home.showRecentlyAdded` | `true` | Recently Added row |
| `home.showGenreRows` | `true` | All 4 genre rows |
| `home.showWatchingNow` | `true` | Watching Now row |
| `detail.showQualityBadges` | `true` | Quality pill row on `MediaDetailScreen` |
| `privacy.maxContentAge` | `0` | Rating ceiling (0=unrestricted; 10/12/14/16/18). Via `apiClient.applyContentRatingLimit` |
| `debug.fastSleepTimer` | `false` | Overrides sleep to 15s |
| `debug.showSkipToEnd` | `false` | "End" button seeking to `(duration − 15s)` |
| `easterEgg.rainbowUnlocked` | `false` | Rainbow accent visibility — flipped by logo-tap easter egg |

### Quick user switch
`UserSwitchSheet` (Settings → Account) — two-step grid → password → re-auth. Updates `AppState.accessToken`/`currentUserId`, calls `apiClient.reconnect(url:accessToken:)` without clearing server URL, success toast, dismisses.

### Refresh Catalogue (single trigger)
Settings → Server: `apiClient.clearCache()` + posts `.cinemaxShouldRefreshCatalogue`. `HomeScreen` + `MediaLibraryScreen` observe and reload. **No per-page refresh buttons** — Settings is SSOT. iOS also `.refreshable { reload() }`.

### Debug section
Always visible (not `#if DEBUG`-gated) so QA/power users don't need a custom build. Icons orange.

## Admin Section (iOS / iPadOS only)

Admin workflows mobile-only by product decision. `SettingsCategory.visibleCases(isAdmin:isTVOS:)` short-circuits when `isTVOS`; every file under `Shared/Screens/Admin/` is wrapped in `#if os(iOS)` so tvOS compiles an empty module.

**Gating** — `AppState.isAdministrator` (cached, refreshed on login/reconnect/user switch via `AppState.refreshCurrentUser()`). Server is authoritative; client gating is UX. `AppState.currentUser: UserDto?` populated alongside for shared reuse (Settings profile header, admin Users grid).

**API surface** — `AdminAPI` slice in `APIClientProtocol.swift` (5-way typealias). Device listing/revocation stays on `AuthAPI` (server returns full fleet to admins, caller's own devices otherwise — same endpoint, payload by caller identity).

**Settings routing** — `.administration` (Dashboard + Metadata Manager) and `.advancedAdmin` (Users/Devices/Activity/Playback/Plugins/Catalog/Tasks/Network/Logs/API Keys). Hidden when `!isAdministrator`.

**Generic scaffolds** (`Shared/Screens/Admin/Components/`):
- `AdminLoadStateContainer` — loading / error / empty / content switcher.
- `AdminFormScreen` — sticky `Sauvegarder` footer + `interactiveDismissDisabled(isDirty)` + discard-changes confirmation. **Every admin editor uses explicit save (never auto-save)** — admin-scoped changes have blast radius (policy revocations, password resets).
- `AdminTabBar` — horizontally-scrolling segmented pills.
- `AdminSectionGroup` — iOS grouped-list section.
- `AdminItemMenu` — shared `Menu` (ellipsis) for one `BaseItemDto`. Actions: Identifier / Edit metadata / Refresh (fire-and-forget) / Delete (via `DestructiveConfirmSheet`). Hosts its own `.navigationDestination(item:)` so actions push onto the ambient `NavigationStack`. Mounted on `MediaDetailScreen` (Admin pill next to Play) and `LibraryPosterCard` overlay.
- `DestructiveConfirmSheet` — type-to-confirm sheet reserved for truly irreversible ops (delete user, delete item). Reversible destructives (revoke device, uninstall plugin) use `.confirmationDialog` with `.destructive` role.

**Shared** — `UserAvatar` (primary image + accent-gradient+initial fallback). `CinemaLazyImage.fallbackBackground = .clear` lets gradient show through on 404/loading.

**Self-protection** (client-side; server enforces too):
- Can't delete yourself (Users detail hides toolbar delete menu on self).
- Can't demote/disable yourself (toggles disabled with hint on self).
- Can't revoke current device (`KeychainService.getOrCreateDeviceID()` vs `DeviceInfoDto.id`; swipe action elided, "THIS DEVICE" pill).
- Creating users: optimistic local append + sort.

**Performance** — Dashboard fans out with `async let` (partial render on single failure). Activity log: infinite-scroll (50/page) on last-row `.onAppear`. Tasks: live polling every 2s while any task running, self-cancels. Users/Devices: small, fully loaded, cached with optimistic mutations. Admin gate cached on `AppState` — refreshed only on login/reconnect/user switch.

**Identify flow** (`Shared/Screens/Admin/Identify/`):
- `IdentifyFlowModel` (`@Observable`) — hosted by standalone `IdentifyScreen` and composed into `MetadataEditorViewModel.identify`.
- Shared subviews: `IdentifyFormView` / `IdentifyResultsGridView` / `IdentifyConfirmView`.
- Standalone wizard: form → results grid → confirm. Back decrements step (doesn't dismiss).
- Kind-aware form: movies show IMDb / TMDb Film / TMDb Coffret; series show IMDb / TMDb / TVDb. Provider IDs stamped on `MovieInfo.providerIDs` / `SeriesInfo.providerIDs` under `"Imdb"`, `"Tmdb"`, `"TmdbCollection"`, `"Tvdb"`.
- `MetadataIdentifyTab` hosts the same subviews in the editor tab (form → grid inline, confirm in sheet).
- Reachable from `AdminItemMenu` and Metadata Manager's Identify tab.

**Metadata Manager** — five-tab editor (General / Images / Cast / Identify / Actions) reached from Settings → Metadata Manager (library picker → items grid → editor) and from `MediaDetailScreen` via the admin 3-dot menu. Images use `downloadRemoteImage` (server fetches from URL, no proxy through phone). Identify scoped to `.movie`/`.series`. Delete via `DestructiveConfirmSheet` with title as confirm phrase.

**Poster-card admin overlay** — `LibraryPosterCard` paints ellipsis-in-blur-circle `AdminItemMenu` at bottom-right when `isAdministrator`. Menu and detail-push `NavigationLink` are `ZStack` siblings (not nested) — tapping ellipsis opens Menu, tapping elsewhere navigates. Title/subtitle rows have own `NavigationLink`.

**ImageType quirk** — CinemaxKit's `ImageType` (Primary/Backdrop/Thumb/Logo/Banner) is narrower than `JellyfinAPI.ImageType` (13 cases). Admin metadata code uses `JellyfinAPI.ImageType` explicitly-qualified; `ImageURLBuilder.imageURLRaw(itemId:imageTypeRaw:)` string-keyed overload renders the wider set without widening `CinemaxKit.ImageType`.

**API key security** (`Shared/Screens/Admin/ApiKeys/`) — keys = passwords:
- Masked by default (first 4 + last 4, dots between). Per-row `eye` toggles reveal; `revealedKeyIds: Set<Int>` dropped on `onDisappear`.
- Token text is `.privacySensitive()` (redacts during mirroring / Control Center capture).
- Per-row Copy button is the only export path — no share sheet.
- `appState.accessToken` match → tagged `CURRENT SESSION`, revoke hidden (would log us out).
- Create: refetch, identify new key by id-delta (not timestamp, collisions), auto-open dedicated "copy this now" modal with explicit Done.
- Never log key values or send to analytics. `revokeApiKey` takes the token itself as identifier (Jellyfin quirk); forget value on return.

## MediaDetailScreen

- `MediaDetailViewModel` auto-resolves Episode/Season → parent Series (by `seriesID`, loads seasons + episodes) and calls `getNextUp()`. `selectSeason()` uses a generation counter for stale results on rapid selection.
- `nextUpEpisodes: [BaseItemDto]` — when `nextUpEpisode.seasonID ≠ selectedSeasonId`, the next-up's season is fetched separately so `episodeNavigation(for:)` can build prev/next.
- Use `resolvedType` (not initial `itemType`) for layout decisions.
- tvOS overview uses `.focusable()` for focus-driven scrolling past non-interactive content.
- **tvOS detail refresh**: `VideoPlayerCoordinator.lastDismissedAt: Date?` updated via `onDismiss` (triggered by `TVDismissDelegate`); screen observes `.onChange` to reload after dismiss (iOS reloads automatically via `.task` on `NavigationLink` pop).

**Resume / next-up** (`actionButtons` → `PlayActionButtonsSection: View, Equatable`): custom `nonisolated static func ==` compares resume state + prev/next episode identity, ignores `epNavigator` closure → `.equatable()` short-circuits re-renders.
- Movie with `playbackPositionTicks > 0` and not `isPlayed`: progress bar (accent, `playButtonWidth`) + `loc.remainingTime(minutes:)` + "Lecture" resuming via `PlayLink(startTime:)`.
- Series: uses `viewModel.nextUpEpisode`. In-progress → progress + remaining + resume. Finished/next → episode label + play. Falls back to series-level play if no next-up.
- **Play from beginning**: when `showResume`, secondary ghost `PlayLink` (`detail.playFromBeginning`, `backward.end.fill`) under resume with `startTime: nil`.
- `userData.playbackPositionTicks` and `runTimeTicks` are `Int?`; `isPlayed` is `Bool?`.
- Episode rows show thin accent progress overlay at thumbnail bottom for partially-watched.

**Quality badges** (`MediaQualityBadges.swift`): pill row between `actionButtons` and overview. Gated on `@AppStorage("detail.showQualityBadges")`. From `item.mediaSources?.first` — first `.video` stream for resolution/HDR/codec, default audio stream (`defaultAudioStreamIndex`) for format/channels.
- Resolution by height: 4K / 1080p / 720p / SD.
- HDR: `VideoRangeType` → Dolby Vision (any `dovi*`), HDR10+, HDR10, HDR (for `hlg`); `VideoRange.hdr` fallback. No SDR badge.
- Video codec: HEVC (hevc/h265), H.264, AV1, VP9, else uppercased raw.
- Audio format (first-hit): Atmos (from `profile`/`displayTitle`), TrueHD, Dolby Digital+ (EAC3), Dolby Digital (AC3), DTS, AAC, FLAC, Opus, MP3, else uppercased raw.
- Channels: `channelLayout` uppercased (Stereo/Mono title-cased); fallback from count (8→7.1, 6→5.1, 2→Stereo, 1→Mono).
- `EmptyView()` when no streams produce badges.

**Episode nav wiring**: `episodeNavigation(for:)` is O(1) lookup from precomputed `episodeNavigationMap` (current season) or `nextUpNavigationMap` (cross-season next-up).

**Ratings**: `communityRating` (yellow star + `%.1f`) and `criticRating` (Rotten-Tomatoes — green ≥60 else red + `%d%%`). Either or both optional.

**Studio / Network label** (`studioLine`): up to 2 from `item.studios`. "STUDIO" (movies) / "NETWORK" (series). `EmptyView` when empty.

**Episode metadata line** (`episodeMetadataLine`): shared by tvOS `episodeRow` + iOS `iOSEpisodeCard`, joined with ` • `:
- In-progress → "Xm remaining" via `loc.remainingTime(minutes:)`.
- Else `runTimeTicks > 0` → total runtime via `detail.runtime.min`.
- Plus `premiereDate` as `.dateTime.month(.abbreviated).day().year()`.

## HomeScreen

- `HomeViewModel` loads `resumeItems` + `latestItems` in parallel via `TaskGroup`.
- `heroItem = resumeItems.first ?? latestItems.first`.
- **Resume navigation**: per resume episode, season's episode list fetched (grouped by `seasonID` to dedupe). `precomputeEpisodeRefs(_:)` builds `(refs, indexByID)` once per season; O(1) `buildEpisodeNavigation(for:refs:indexByID:...)` per episode. Results in `resumeNavigation: [String: (previous, next, navigator)]`. `MediaDetailViewModel.makeNavigationMap(from:)` uses same helper.
- Hero and each Resume `PlayLink` pass `startTime` (`ticks / 10_000_000`, nil for no-progress) + nav.

**Genre rows**: `genreRows: [GenreRow]` with `.items` / `.failed`. Fetches `getGenres(userId:includeItemTypes: [.movie, .series])`, shuffles, picks 4. Items in parallel (`getItems(sortBy: [.random], genres:, limit: 10, ...)`). Empty-success dropped; **failures become `.failed`** so UI renders retry capsule — transient errors don't silently hide content.

**Watching Now**: `activeSessions` via `getActiveSessions(activeWithinSeconds: 60)`, filtered (drop current user, require `nowPlayingItem`). `WideCard` + red "LIVE" pill.

**Configurable layout** (all default `true`): `home.showContinueWatching` / `.showRecentlyAdded` / `.showGenreRows` / `.showWatchingNow`. Hero never gated.

**Empty state**: `EmptyStateView` with Refresh, in `ScrollView` so pull-to-refresh still works.

**Scroll-to-top on reappearance (tvOS)**: `ScrollViewReader` + zero-height `.id("home.top")` sentinel. `.onAppear` → `proxy.scrollTo("home.top", anchor: .top)` resurfaces top tab bar. Same pattern in `MovieLibraryScreen`, `SearchScreen`, Settings tvOS landing.

## SearchScreen

- `SearchViewModel.search(using:)` debounces 400ms → `searchItems(userId:searchTerm:limit:30)`.
- **Decomposition**: shell + file-private `VoiceSearchButton` (iOS, owns `isPulsing`), `SearchResultsGrid`, `SearchResultCard`. Lets SwiftUI skip grid diff on parent state changes.
- iOS mic → `SpeechRecognitionHelper` (SFSpeechRecognizer + AVAudioEngine).
- **Surprise Me**: two pills in empty state. `fetchRandomMovie(using:)` / `fetchRandomSeries(using:)` are separate methods because Swift 6 flags a `[BaseItemKind]` built from a parameter as non-Sendable crossing the API actor — literal arrays work fine. Success pushes `MediaDetailScreen` via `navigationDestination(item:)`; empty library emits error toast.

## Localization

- `LocalizationManager` (`@Observable`, injected from `AppNavigation`). Default `fr`, also `en`.
- All strings via `loc.localized("key")` / `loc.localized("key", args...)` — never hardcoded.
- Strings at `Resources/{lang}.lproj/Localizable.strings`.
- Reactivity: `@ObservationIgnored` + `@AppStorage` + `_revision` counter.
- Plural helpers (e.g. `remainingTime(minutes:)`). Use the helper, not inline branching.

## Toasts

- `ToastCenter` (`@Observable`, injected at `AppNavigation` root) — single-toast queue with auto-dismiss.
- `ToastOverlay` renders top-anchored glass pill (level-tinted SF Symbol + title + optional message).
- API: `.success(_:)`, `.error(_:)`, `.info(_:)` with optional `message:`, `duration:`.
- Use for action feedback and recoverable errors. NOT for critical errors needing a decision — use `UIAlertController`.

## Empty states

`EmptyStateView` (icon + title + optional subtitle + optional action). Used by: Home when everything empty; filtered library grid (offers "Clear filters" resetting `LibrarySortFilterState()`); `UserSwitchSheet` when empty.

## Dynamic Type (iOS)

- `.dynamicTypeSize(.xSmall ... .accessibility2)` at `AppNavigation` root — honors OS text-size preference while capping below accessibility sizes that break hero/tab-bar layouts.
- `CinemaFont.dynamicBody / dynamicBodyLarge / dynamicLabel(_:)` use `UIFontMetrics(forTextStyle:).scaledValue(for:)` so final = `baseSize × CinemaScale.factor × dynamicTypeMultiplier`.
- Apply dynamic variants only to reading-heavy surfaces. Hero/display/headline titles keep fixed `CinemaFont.body` / `.headline()` to protect layout.

## Image Patterns

- `ImageURLBuilder` → `/Items/{id}/Images/{type}`.
- **Backdrop sizing**: use `ImageURLBuilder.screenPixelWidth` — never hardcode `1920`.
- **Image cache**: `AppNavigation.init()` configures `ImagePipeline.shared` with 500 MB disk (`com.cinemax.images`).
- **Backdrop fallback**: `item.backdropItemID` (→ `parentBackdropItemID ?? seriesID ?? id`) from `BaseItemDto+Metadata`.
- **Always `CinemaLazyImage`** — never `LazyImage` directly. Params: `url`, `fallbackIcon: String?`, `fallbackBackground: Color`, `showLoadingIndicator: Bool`.
- **Card containers**: `Color.clear` + `.aspectRatio()` + `.frame(maxWidth: .infinity)` + `.overlay { CinemaLazyImage }` + `.clipped()`.
- **Backdrop (full-bleed ZStack)**: `CinemaLazyImage` must have `.frame(maxWidth: .infinity, maxHeight: .infinity)` — else ZStack sizes from image's natural dims (1920px) pushing title VStack off-screen. Outer container: `LazyVStack(alignment: .leading)`.
- **PosterCard title alignment**: hidden `Text("M\nM").hidden()` placeholder + actual title overlaid top-aligned → uniform row height.

## App Icons

- **iOS**: `Resources/Assets.xcassets/AppIcon.appiconset/` — 1024×1024 light/dark/tinted.
- **tvOS**: `Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets/` — 3-layer parallax + Top Shelf (1920×720) + Wide (2320×720).
- **In-app logo**: `AppLogo.imageset/` — iOS full icon; tvOS front parallax layer only (transparent bg).
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
