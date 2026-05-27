# Cinemax - Jellyfin Client for Apple Platforms

Native Jellyfin client for iOS 26+ and tvOS 26+. "Cinema Glass" design system (dark glassmorphism, editorial layouts, no borders). SwiftUI multi-platform, single Xcode project (iOS + tvOS targets). Swift 6 strict concurrency.

> This file = rules, gotchas, and non-derivable context. Feature *behavior* is derivable from the code — read the owning file. Lines tagged **RULE** override default behavior.

## Architecture

- **CinemaxKit** local Swift Package at `Packages/CinemaxKit` — networking, models, persistence.
- `@Observable` + `@MainActor` for all state. `JellyfinClient` wrapped with `NSLock` + `nonisolated(unsafe)` for Sendable.
- **RULE — iOS `NavigationStack`**: destinations pushed via `navigationDestination(item:)` render in a separate context — `@Observable` changes won't re-render unless the destination is a standalone `View` struct with its own `@Environment` properties, not an extension method returning `some View`.
- **RULE — Lazy-container navigation**: SwiftUI silently ignores `navigationDestination(item:)` inside `LazyVGrid/LazyVStack/LazyHStack/List`. Hoist the modifier to a non-lazy ancestor; bubble the action up via a callback that mutates a screen-level `@State`. Reference: `AdminItemMenu.onSelectDestination` → screen-level `@State AdminMenuPushIntent?`. Used by `MovieLibraryScreen`, `MediaDetailScreen`.

### iOS 26 / tvOS 26 API rules (all RULE)

- **`UIButton`**: use `UIButton.Configuration`; never `UIButton(type:)` + `setTitle/titleLabel?.font/backgroundColor/contentEdgeInsets`. Pattern in `NativeVideoPresenter`. Frosted bg via `config.background.customView = UIVisualEffectView(...)`.
- Free SwiftUI helpers returning `some View` that touch `PrimitiveButtonStyle.plain`/`Font`/etc. must be `@MainActor`.
- **iPad**: `UIRequiresFullScreen` removed (deprecated); split view / Stage Manager allowed but hero/backdrop layouts not yet hardened for resize.
- **Toolbar + Liquid Glass**: iOS 26 auto-renders `ToolbarItem` buttons with Liquid Glass. **Never** add `.buttonStyle(.glass)`/`.glassProminent` on toolbar items (nests double capsules). Active state via `.tint(themeManager.accent)` + `.fill` icon variant.

### Dependencies

`jellyfin-sdk-swift` v0.6.0, `Nuke`/`NukeUI` v12.9.0, `AVKit`/`AVPlayer`, `SwiftVLC` (libVLC 4.0, Swift 6 — [harflabs/SwiftVLC](https://github.com/harflabs/SwiftVLC), pinned **exactVersion 0.3.0**; ≥0.4.0 needs swift-tools 6.3 / Xcode 26.3+, toolchain is Swift 6.2.3 / Xcode 26.2; 0.3.0 is newest tag both 6.2-compatible AND shipping the PiP API — bump on Xcode 26.3+).

- `import SwiftVLC` works iOS + tvOS (`Player` is `@Observable @MainActor`; `VideoView`/iOS-only `PiPVideoView` are SwiftUI representables hosted in UIKit presenters via a child `UIHostingController`). Both `Cinemax` (iOS) and `CinemaxTV` (tvOS) targets link it — VLC is the default online playback engine on both.
- **RULE — Never re-add `VLCKitSPM`** — libVLC 3.x + 4.0 in one binary collide on `libvlc_*` C symbols. SwiftVLC replaced it (native PiP, object-based `Track` API fixing the audio-switch silence bug, Swift-6-native).
- **RULE — Adding a new file under `Shared/` requires re-running `xcodegen generate`** before it builds (the PostToolUse hook auto-regens only on `project.yml` edits, not new files; symptom of forgetting: "cannot find type X in scope" for a type that exists).
- **RULE — `@Observable` properties must NOT carry `didSet`/`willSet`**: the macro instruments setters via `withMutation { ... }`; a property observer body runs *after* the observation commits, and on collection-of-`Codable`-value-types properties (e.g. `[MenuEntry]`) the combo intermittently fails to deliver SwiftUI re-renders (symptom: bottom tab bar doesn't update after a reorder until the user taps anywhere). Pattern: keep stored properties plain `var T`, expose explicit `set*(_:)` mutator methods that mutate + persist, and use custom `Binding(get:set:)` in Pickers/Toggles so writes go through the mutator. Reference: `MenuConfigStore.setMode`/`setCustomKind` and the `Binding` projections in `MenuSettingsScreen+iOS.swift`.

### API protocol split (`Packages/CinemaxKit/.../APIClientProtocol.swift`)

`APIClientProtocol = ServerAPI & AuthAPI & LibraryAPI & PlaybackAPI & AdminAPI & DownloadAPI`. View models needing multiple domains take `APIClientProtocol`; leaf controllers narrow to a slice (`PlaybackReporter`/`SkipSegmentController` → `any PlaybackAPI`; `NowPlayingInfoController` → `any LibraryAPI`; `DownloadManager` → `any DownloadAPI`). `AdminAPI` is a privilege boundary — gated on `AppState.isAdministrator`; server enforces authoritatively.

### Swift 6 `nonisolated` escape hatches (safe when body only reads parameters)

1. `View, Equatable` sub-type inside a `@MainActor` screen needs `nonisolated static func ==` (`Equatable` isn't main-actor-isolated). See `PlayActionButtonsSection` in `MediaDetailScreen.swift`.
2. A `@MainActor` class's `static func` returning non-Sendable into a `TaskGroup @Sendable` closure needs `nonisolated private static func`. See `HomeViewModel.fetchGenreItems`.
3. A `nonisolated static func` reading a `static let` needs the constant `nonisolated` too (Sendable types only). See `SearchViewModel.sanitize` + `maxQueryLength`.
4. When `nonisolated static func ==` reads a non-Sendable DTO stored property, wrap the body in `MainActor.assumeIsolated { ... }` (safe — SwiftUI diffs on main actor). See the `MediaDetail*Section` / `MediaDetailEpisodeCard/Row` extractions.
5. **`@retroactive @unchecked Sendable` for SDK value enums**: the Jellyfin SDK doesn't annotate `BaseItemKind` (a `String`-raw enum). `@preconcurrency import` silences old warnings but Swift 6.1 region-based isolation still rejects `[BaseItemKind]?` crossing async/actor boundaries or being captured by `@Sendable` closures. Bridge in `Packages/CinemaxKit/.../Models/JellyfinSendable.swift`. Strictly scope these conformances to genuinely-safe value types (String-raw enum, no associated values).

## Project Structure

```
Shared/
  DesignSystem/             CinemaGlassTheme, ThemeManager, AccentOption (+AccentEasterEgg), LocalizationManager, ToastCenter, GlassModifiers, FocusScaleModifier, AdaptiveLayout, TVButtonStyles, SettingsKeys, SleepTimerOption
  DesignSystem/Components/   CinemaButton, CinemaLazyImage, PosterCard, WideCard, CastCircle, ContentRow, ProgressBarView, RatingBadge, GlassTextField, FlowLayout, ToastOverlay, EmptyStateView, ErrorStateView, LoadingStateView, AlphabeticalJumpBar, CinemaToggleIndicator, RainbowAccentSwatch, MediaQualityBadges, UserAvatar
  Navigation/               AppNavigation (auth routing), MainTabView, MenuConfig (MenuConfigStore + ResolvedTab)
  Screens/                  Home/Login/ServerSetup/Search/MovieLibrary/TVSeries/PrivacySecurity, MediaDetailScreen + MediaDetail* siblings, VideoPlayerView, NativeVideoPresenter, HLSManifestLoader, PlayLink
    VideoPlayer/            PlaybackReporter, SkipSegmentController, SleepTimerController, ChapterController, EndOfSeriesOverlayController, RemoteCommandController, NowPlayingInfoController, VLCStreamPresenter (covers online iOS+tvOS via stream init AND offline iOS via second init — same HUD class for both); shared extractions: PlayerTimeFormat (HH:MM:SS), PlayerEngineSurface (SwiftVLC host), PlayerTransportViews (TVScrubBar/ChapterChip/PassthroughView)
    Settings/               SettingsScreen + iOS/tvOS extensions, SettingsAppearanceView+iOS, SettingsRowHelpers, SettingsTV{AccentPicker,LanguagePicker,ProfileSection,ActionRow}, SettingsNavCoordinator (hoisted sub-nav state — see Custom menu RULES), MenuSettingsScreen + iOS/tvOS extensions (custom-menu editor)
    Downloads/              (iOS-only) DownloadButton, DownloadsScreen, OfflineLibraryView, OfflineMediaDetailView, DownloadItem+BaseItemDto
    Admin/                  (iOS-only) Dashboard/Users/Devices/Activity/Tasks/Plugins/Catalog/Playback/Network/Logs/ApiKeys/Metadata/Identify
    Admin/Components/       AdminLoadStateContainer, AdminFormScreen, AdminTabBar, AdminSectionGroup, AdminItemMenu, DestructiveConfirmSheet
  ViewModels/               per-screen VMs + VideoPlayerCoordinator + DownloadManager (iOS) + NetworkMonitor
iOS/ tvOS/                  app entry points
Resources/{fr,en}.lproj/    Localization (fr default)
Packages/CinemaxKit/        Models (incl. JellyfinSendable retroactive conformances), Networking (JellyfinAPIClient, ImageURLBuilder, +Downloads), Persistence (KeychainService, DownloadStore, DownloadStorage)
docs/design-system/         Canonical design system reference
```

`Shared/Screens/` is mostly flat. Exceptions: `Settings/` and `Admin/` feature folders. `PlayLink.swift` + `MediaDetail*.swift` siblings stay at root (tightly coupled to parents).

## Design System (all RULE — `docs/design-system/conventions.md` rejection checklist is authoritative; read `docs/design-system/README.md` before editing UI)

- Tokens in `CinemaGlassTheme.swift`. All `CinemaColor` use `Color.dynamic(light:dark:)`. **Never `Color(hex:)` for new tokens.**
- **Shared toggle**: `CinemaToggleIndicator` (Capsule+Circle pill), parent-driven (`Button { value.toggle() }`). Never system `Toggle` in settings.
- **No 1px borders** — use color shifts. Glass panels: `.glassPanel()`.
- **Accent**: `themeManager.accent`/`.accentContainer`/`.accentDim`/`.onAccent` — never `CinemaColor.tertiary*`. All dual-mode.
- **Dark/Light**: always route through `themeManager.darkModeEnabled =` / `themeManager.accentColorKey =` — direct `@AppStorage` writes bypass `_accentRevision` and break reactivity. `.preferredColorScheme()` applied at root in `AppNavigation` only.
- **Hardcoded `.white`/`.black`**: only inside the video player (always dark) and on saturated `accentContainer`. Else `CinemaColor.onSurface`/`.onSurfaceVariant`.
- **Font scaling**: `CinemaScale.factor` = 1.4× base on tvOS × user `uiScale` (80–130%). **RULE — no bare `.font(.system(size: N))` numeric literals** — wrap `N` in `CinemaScale.pt(...)` or use a `CinemaFont.*` token, else it ignores `uiScale`/tvOS 1.4×. Exception: Play/Lecture labels hardcode 28pt on tvOS (computed var, not a bare literal).
- **tvOS focus**: `@FocusState` + `.focusEffectDisabled()` + `.hoverEffectDisabled()`. 2px accent `strokeBorder`, no scale/white bg. Cards: `CinemaTVCardButtonStyle`. Settings rows: `.tvSettingsFocusable()`. **Trait caveat**: a focused `Button` flips `UITraitCollection` to light-mode inside its label; `tvSettingsFocusable` takes `colorScheme` and injects on content + background shape — always pass `themeManager.darkModeEnabled ? .dark : .light`. **Hero `.focusSection()` rule**: any hero whose Play/More Info buttons sit in `.overlay(alignment: .bottomLeading)` of a tall `Color.clear` sizing block (Home + Library) needs `.focusSection()` on the buttons row AND the immediate row above (`tvTopBar` etc.) must also be a focus section — else up-presses get absorbed in the hero bounds.
- **iOS focus**: `.cinemaFocus()` (accent border + shadow).
- **CinemaButton styles**: `.accent` = primary CTAs (saturated `accentContainer` + `.white` text). `.primary` = neutral gradient (only on `DestructiveConfirmSheet`). `.ghost` = secondary (Retry, Clear Filters).
- **Motion Effects**: `motionEffectsEnabled` env key (from `@AppStorage("motionEffects")`). When off, all `.animation()` → nil.
- Platform-adaptive via `#if os(tvOS)` or `horizontalSizeClass`.

## Navigation

- `AppNavigation` → Keychain session check → `apiClient.reconnect()` + `fetchServerInfo()`. Injects `ThemeManager`, `LocalizationManager`, `ToastCenter`, `MenuConfigStore`; applies `.preferredColorScheme()` at root.
- Flow: no server → `ServerSetupScreen` → `LoginScreen` → `MainTabView` (top tabs tvOS, sidebar iPad, bottom tabs iPhone).
- **RULE — All play buttons use `PlayLink<Label>`** (Button+coordinator on tvOS, `NavigationLink` on iOS) — never direct `NavigationLink` to `VideoPlayerView`.
- **Session expiry / 401**: `JellyfinAPIClient.setOnUnauthorized` (`@Sendable () -> Void`) → posts `.cinemaxSessionExpired`; `AppNavigation` runs `appState.logout()` + toast. Lazy recovery (no eager validation); 6 hot paths instrumented (`getResumeItems`/`getLatestMedia`/`getItems`/`getItem`/`searchItems`/`getPlaybackInfo`). Detection is string-match on `(401)`/`NSURLErrorUserAuthenticationRequired`.

### Custom menu / dynamic tabs (`MenuConfigStore`)

`MainTabView` consumes `menuConfig.resolvedTabs` (computed from `mode` / `customKind` / persisted entry arrays / `availableViews` cache). Three modes:

- **`.default`** — the canonical 5 tabs (Home, Movies, TV Shows, Search, Settings).
- **`.custom + .contentType`** — user picks which of the canonical 5 are enabled and in what order.
- **`.custom + .library`** — user surfaces individual Jellyfin libraries (returned by `getUserViews`) as tabs, filtered to video kinds only (`movies`/`tvshows`/`homevideos`/nil — see `LibraryView.nonVideoCollectionTypes` blacklist; `boxsets`/`music`/`photos` etc. excluded).

- **RULE — `MenuConfigStore.maxEnabledTabs = 5` (hard cap)**: `TabView` on iPhone in compact width instantiates a `UIMoreNavigationController` when it has >5 tabs. Any list mutation that crosses the 5↔6 boundary tears that controller down and dumps the user back to the first tab — an UIKit lifecycle quirk we can't override from SwiftUI (visible in logs as `UIScrollView does not support multiple observers ... removing old observer <UIMoreNavigationController>`). Toggling-on a 6th entry is refused via `ToggleResult.refusedCapReached` → toast.
- **RULE — Library-mode tabs accept `parentId: String?` + `overrideTitle: String?` on `MediaLibraryScreen`** so each library tab scopes its queries to that view id. `BaseItemKind?` is nilable on `MediaLibraryScreen`/`MediaLibraryViewModel`: `nil` means "no `includeItemTypes` filter" — needed for `Mixed`/`Other` libraries where Jellyfin items aren't reliably typed.
- **RULE — Don't tag a tab with `role: .search`** on iPhone in this app: per Apple WWDC 2024, a search-role tab is force-placed at the trailing edge of the bar regardless of declaration order, which conflicts with user-reorderable menus and was the source of "redirected to Search" after a drag. Search is a regular `Tab` here.
- **RULE — Use `Tab(value:)` over `.tabItem + .tag` on both iOS and tvOS**: the pre-iOS-18 `.tabItem + .tag` pattern doesn't preserve child-view `@State` across a `ForEach` collection diff on tvOS — every `MenuConfigStore` mutation was remounting `SettingsScreen` and dropping its sub-nav before this migration. `Tab(value:)` builds identity off the `value` and survives collection mutations cleanly.
- **RULE — Settings sub-navigation state lives on `SettingsNavCoordinator`, not `SettingsScreen.@State`**: tvOS's `TabView` is bridged to `UITabBarController` which indexes child view controllers by **position**. Any layout shift in the tab bar (toggle off, reorder, kind change) — even with `Tab(value:)` — recreates the `UIHostingController` for the tab whose position changed, dumping the SwiftUI `@State` inside. `selectedCategory` / `selectedInterfaceSub` are stored on `SettingsNavCoordinator` (`@MainActor @Observable`) instantiated on `AppNavigation` (which never remounts during normal usage) and injected via `.environment`. `SettingsScreen` exposes thin computed-property pass-throughs (`get`/`nonmutating set`) so call sites keep using `selectedCategory = X`; the `$`-projection cases use `@Bindable var nav = settingsNav` + `$nav.selectedCategory`. iOS doesn't exhibit the position-remount bug but uses the same coordinator for symmetry.
- **RULE — `MainTabView` renders the bar from a `@State displayedTabs` snapshot, not directly from `menuConfig.resolvedTabs`**: rendering off the live `@Observable` reconfigures the UIKit-backed bar on every fine-grained edit, which on tvOS pulls focus off the row the user is touching onto the top-bar active pill (reads to the user as a "page reload"). The snapshot is **frozen while `settingsNav.selectedInterfaceSub == .menu`** so toggle / reorder / library-refresh edits keep focus stable inside the editor. **Structural** mutations bypass the freeze and refresh live: `onChange(of: menuConfig.mode)` (covers Reset which forces `mode = .default`) and `onChange(of: menuConfig.customKind)` (entire entry set is being replaced). The bar catches up the moment the user backs out of the editor.
- Persistence is explicit (`SettingsKey.menu*`) via mutator methods on the store, **never** through property `didSet` (see Architecture RULE on `@Observable`). `refreshAvailableViews()` is idempotent (`if views != availableViews { ... }`) to avoid spurious Observation cycles during user interaction. Mandatory IDs: `[settingsID]` only — Home and Search are non-mandatory but default-on.
- **MenuSettingsScreen tvOS Mode / Kind rows use a single `CinemaToggleIndicator`**, not two pills — same shape as `tvGlassToggle` in Apparence (Dark/Light Mode). Icon + label flip with state (`rectangle.stack.fill`/`Par défaut` ↔ `slider.horizontal.3`/`Personnalisé` ; `film.stack`/`Par type de contenu` ↔ `books.vertical.fill`/`Par bibliothèque`). Each toggle fires a `menu.refresh.confirm` toast on flip — the bar rebuilds (entries swap, focus jumps), and the pill is the only signal that explains the re-layout to the user. **Do NOT** toast on the "Refresh libraries" row: the row already conveys status via spinner + `lastFetchError` subtitle, a duplicate pill on every tap is noise.

## Server Setup & Login

Two-step pre-auth flow, shared mobile design (Server → Login feels like one journey). Discovery (`JellyfinServerDiscovery` + `ServerDiscoverySheet`): UDP broadcast port 7359; probes limited (`255.255.255.255`) **and** each interface's directed broadcast via `getifaddrs`. `scan()` auto-retries once after 800ms on empty (iOS local-network permission race). `NSLocalNetworkUsageDescription` in `iOS/Info.plist`. `AppState.disconnectServer()` → `ServerSetupScreen` ("Change server").

- **RULE — LoginScreen mobile caveat**: ServerSetupScreen's `.padding(.horizontal, spacing4)` outside `.glassPanel` is silently dropped in `LoginScreen.mobileLayout` under iOS 26. Workaround: `.frame(maxWidth: formMaxWidth)` (350pt) on form panel + actions VStack. Don't "fix" without pixel-sampling.
- **Rainbow easter egg**: top icon block is a `Button` → `AccentEasterEgg.tap(…)` (resolver in `SettingsScreen.swift`). Cycles `AccentOption.cyclingCases`; unlock flips `@AppStorage(SettingsKey.rainbowUnlocked)`. `ThemeManager` checks `isRainbow` first → HSB driven by `_rainbowHue`.

## Media Library (`MediaLibraryScreen`)

Unified, parameterized by `BaseItemKind`. State: `LibrarySortFilterState` (default `dateCreated` desc).

- **Browse vs filtered**: browse layout (hero + genre rows + browse-genres grid) when `!isFiltered`; any filter → flat grid. `isFiltered` = genre chips OR `showUnwatchedOnly` OR `selectedDecades`. tvOS additionally honors `library.tvBrowseLayout` (`grid` forces flat grid even unfiltered).
- Title count uses `isFiltered` (not `isNonDefault`). `loadInitial` guarded by `hasLoaded` (prevents re-randomization on tab switch); `reload(using:)` bypasses (pull-to-refresh, `.cinemaxShouldRefreshCatalogue`).
- Filters: Unwatched → `filters:[.isUnplayed]`; Decade `selectedDecades: Set<Int>` (starting year) → `expandedYears` for `getItems(years:)`.
- **RULE — tvOS Filters button opens `LibrarySortFilterSheet` via `.fullScreenCover`, not `.sheet`** (`.sheet` on tvOS 26 renders a narrow modal whose toolbar items show as broken white pills).
- `LibrarySortFilterSheet` split bodies: iOS `NavigationStack` + toolbar Apply/Reset; tvOS explicit title + scrollable sections + sticky footer (Reset `.ghost`, Apply `.accent`), sort hidden (lives in top-bar `confirmationDialog`), per-section Clear inline as trailing FlowLayout chip.
- **tvOS button styles** (`TVButtonStyles.swift`): `TVFilterChipButtonStyle` (capsule, press scale 0.95); `TVFilterRowButtonStyle` (full-width rows, **no press scale** — visibly shifts label on wide rows).
- **iOS jump bar**: `AlphabeticalJumpBar` only when `sortBy == .sortName && sortAscending && items.count > 20`.

## Video Playback

### Playback engine (VLC default — fixes the MKV/Dolby-Vision freeze)

Online playback defaults to VLC on iOS + tvOS. Settings → Interface **"Use Native Player"** (`SettingsKey.forceNativeAVPlayer`, default `false`) falls back to `AVPlayer`/`NativeVideoPresenter`.

**Why:** `AVPlayer` can't open MKV → Jellyfin forced into a 4K HEVC + DV→SDR re-encode the server can't do real-time → frozen playback. No `AVPlayer` device profile makes Jellyfin remux DV-in-MKV (DV only passes through on DirectPlay/DirectStream, never in a transcode). VLC DirectPlays the raw file → zero server transcode, 4K/HEVC/DV preserved.

- **RULE — Device profile split** (`JellyfinAPIClient+Playback.swift`): `getPlaybackInfo(... engine:)`. `.vlc` → `buildVLCDeviceProfile` (one broad DirectPlayProfile, **no container restriction** → `/Videos/{id}/stream?static=true`, no transcode). `.native` → `buildAppleDeviceProfile` (AVKit-safe codec profiles). **API default is `.native`** so internal AVPlayer-only calls are unaffected; engine chosen explicitly at `VideoPlayerCoordinator` (tvOS) / `VideoPlayerView` (iOS) from `forceNativeAVPlayer`.
- **`VLCStreamPresenter`** (iOS+tvOS, two init shapes — stream + iOS-only offline): UIKit `UIViewController` shell + all controllers/HUD; SwiftVLC `events` `AsyncStream<PlayerEvent>` consumed in one `@MainActor` Task. Rendering: child `UIHostingController` hosting the shared `PlayerEngineSurface` — `PiPVideoView` on iOS (native PiP for ALL content incl. MKV/DV via `pip.enter` → `PiPController.toggle()`), `VideoView` on tvOS (no PiP — tvOS has none). Time strings via shared `PlayerTimeFormat`; leaf transport views live in `PlayerTransportViews.swift`. Object-based track selection (no silence bug); Jellyfin defaults applied once on `.tracksChanged` by ordinal-within-type. **libVLC 4.0 has no distinct `.ended`** — end-of-media is `.stopped`, disambiguated via `isTearingDown` flag + `lastPlayStart` (>1s) + near-end guard. Auth via `api_key` **query param** (libVLC can't reliably inject the header). Full feature parity. **AirPlay-to-TV video** still impossible on any libVLC path — deferred. **RULE — offline mode** (iOS init `VLCStreamPresenter(localURL:title:startTime:loc:onDismiss:)` + `presentOffline()`): inherits the full HUD (transport row with ±N skip + play/pause, scrub bar with remaining time, audio/subtitle pickers populated from libVLC tracks, sleep timer + still-watching, PiP, center play/pause flash, ±N skip glyph, tap to toggle HUD, double-tap to skip). Network-only affordances are auto-gated off when `info`/`apiClient`/`userId` are nil: no PlaybackReporter, no intro/outro segment skip, no chapter strip, no episode prev/next. `makeMedia` picks `:file-caching=3000` instead of `:network-caching=3000`; error retry reuses the local URL.
- `PlaybackReporter` engine-agnostic via optional `TimeSource` closure (AVPlayer → nil reads `Context.player`; VLC injects VLC time).
- **tvOS transport is custom** (no `AVPlayerViewController`): `TVScrubBar` (focusable; clickpad left/right = ±15s only while focused), focusable control bar (Prev/Next/Audio/Subtitles — **no on-screen play/pause**, center glyph flash feedback), always-on chapter strip (peeks 40pt / expands 178pt on focus). `ChapterChip` draws own focus state. After every programmatic seek `refreshTimeUISoon()` repaints (VLC emits no time updates while paused; it cancels its prior follow-ups so a scrub burst can't stack closures).
- **RULE — tvOS touch-surface scrubbing** (`TVScrubBar`): Siri Remote touchpad slide = variable scrub via an **indirect-only** `UIPanGestureRecognizer`. Must be **incremental** — consume `translation(in:)` then `setTranslation(.zero)` each `.changed` and accumulate; an absolute baseline gets stomped by the periodic tick → "jump then snap" glitch. Sensitivity is the single `scrubGain` constant (0.5 = full swipe ≈ half the timeline; tune here). No engine seek during the drag (preview labels only); one `engineSeek` on release. `VLCStreamViewController.pendingScrubTargetMs` holds the bar/labels at the target until VLC's async seek actually lands (±1.2s) so the tick can't paint the stale pre-seek position; cleared on a ±15s press. Presses ignored while `isScrubbing`. tvOS `refreshTimeUI` honors `isScrubbing` like the iOS slider.
- **Chapter thumbnails** from `getItem().chapters`; requests skipped when `imageTag` nil. Blank ⇒ server hasn't run Jellyfin Dashboard → Scheduled Tasks → "Chapter image extraction". Degrades to `film` icon + title + timestamp.
- **iOS controls** are the touch UI (`#if os(iOS)`: tap-to-toggle, `UISlider`, separate pickers, `pip.enter`). The SwiftVLC view is hosted with `isUserInteractionEnabled = false` so the `videoView` tap recognizer drives HUD toggles. Simulator has no HW HEVC/DV decoder and no PiP — judge on real hardware.

### Flow (native/AVPlayer path)

1. `getItem()`. 2. Resolve non-playable: Series → `getNextUp()` or first episode; Season → first episode (**must resolve to Episode** — Series/Season have no media sources). 3. POST PlaybackInfo with `DeviceProfile` (`isAutoOpenLiveStream=true`, `mediaSourceID`, `userID`). 4. URL: `transcodingURL` (HLS) if present, else `/Videos/{id}/stream?static=true`. 5. Fallback: direct stream without PlaybackInfo session.

- **RULE — DeviceProfile**: DirectPlay mp4/m4v/mov + h264/hevc; transcode to HLS mp4 with `hevc,h264` only. **Never include `mpeg4`** — not a valid HLS transcode target on Apple; Jellyfin injects `mpeg4-*` URL params AVFoundation rejects. `maxBitrate`: 120 Mbps (4K) / 20 Mbps (1080p) via `@AppStorage("render4K")`.

### Native Player (`NativeVideoPresenter.swift`)

Both platforms `AVPlayerViewController` presented via UIKit modal. `@MainActor` sub-controllers in `Shared/Screens/VideoPlayer/`: `PlaybackReporter`, `SkipSegmentController`, `SleepTimerController`, `ChapterController`, `EndOfSeriesOverlayController`, `RemoteCommandController`, `NowPlayingInfoController`. Presenter keeps **one** `addPeriodicTimeObserver` (1s) fanning ticks to sub-controllers — sub-controllers never add their own.

- **RULE — MUST present via UIKit modal** — SwiftUI presentation corrupts `TabView`/`NavigationSplitView` focus on dismiss.
- **RULE — Dismiss detection**: iOS `PlayerHostingVC.viewWillDisappear(isBeingDismissed:)`; tvOS `TVDismissDelegate.playerViewControllerDidEndDismissalTransition`. **Do NOT embed `AVPlayerViewController` as a child VC on tvOS** — internal constraint conflicts + `-12881`.
- **Audio track menus**: via `transportBarCustomMenuItems` — first-class tvOS, ObjC KVC iOS (marked `API_UNAVAILABLE(ios)` but exists iOS 16+). Shows Jellyfin names not "Unknown".
- **Subtitles** — iOS: `enableSubtitlesInManifest:true` + `.hls` → WebVTT; `HLSManifestLoader` (`AVAssetResourceLoaderDelegate`, `cinemax-https://` scheme) strips `CLOSED-CAPTIONS` + ASS/SSA tags. Fallback `retryWithDirectURL` on `-12881` (no scheme; tags won't strip). tvOS: `HLSManifestLoader` does NOT work (causes `-12881`) → direct URL, ASS tags may appear. **RULE — `contentInformationRequest.contentType` must be a UTI not MIME**: `"public.m3u-playlist"`, `"org.w3.webvtt"`; skip for segment types.
- **Episode navigation**: `MPRemoteCommandCenter` prev/next; `EpisodeRef`/`EpisodeNavigator`/`buildEpisodeNavigation` in `PlayLink.swift`. `itemId`/`startTime` are `var`, rebound in `navigateToEpisode` (startTime → `nil`). Auto-play next via `didPlayToEndTime` when `autoPlayNextEpisode`.
- **Skip Intro/Credits**: requires **Intro Skipper** plugin. `getMediaSegments(... [.intro,.outro])`; time-based `checkSegments`, re-entry works, click seeks to `segment.end`. Rendering: iOS floating `UIButton`; **RULE — tvOS `AVPlayerViewController.contextualActions = [UIAction(…)]` is the ONLY mechanism producing a focusable button coexisting with the transport-bar focus context** (custom subviews/overlays/`preferredFocusEnvironments` unreachable while `AVPlayerViewController` on screen — applies to any future in-player affordance).
- **Chapters** (tvOS only): `BaseItemDto.chapters` → `AVPlayerItem.navigationMarkerGroups = [AVNavigationMarkersGroup(...)]`. `AVNavigationMarkersGroup` tvOS-only; iOS `#if os(tvOS)` no-op.
- **Sleep timer**: `SleepTimerOption` (Off/15/30/45/60/90) via `@AppStorage("sleepTimerDefaultMinutes")`. On fire: pause + "Still watching?" (`UIAlertController` tvOS / blur card iOS). **RULE — PiP gating (iOS)**: `isInPictureInPictureProvider` closure → when true, timer pauses silently, skips overlay (unreachable from PiP window). `#if os(iOS)`; tvOS default `{ false }`. `AVPlayerViewController` has no public `isPictureInPictureActive` — track via delegate.
- **End-of-series**: `didPlayToEndTime` + autoplay + no next + `episodeNavigator != nil` → "You finished {Series Name}" overlay.
- **Picture-in-Picture (iOS)**: `allowsPictureInPicturePlayback` + `canStartPictureInPictureAutomaticallyFromInline`. `IOSPlayerDelegate`: `willStart` sets `isInPictureInPicture`, modal auto-dismisses (`shouldFireOnDismiss` suppresses cleanup); `restoreUserInterface…` re-presents via new `PlayerHostingVC`; `didStopPictureInPicture` full cleanup only when `didRestoreFromPiP == false`. `PiPRestoreHandlerBox` (`@unchecked Sendable`) wraps non-Sendable handler.
- **RULE — AirPlay (iOS)**: `UIBackgroundModes = [audio]` in `project.yml` (playback continues when iPhone locks during cast). **Do not add `airplay`** as a background mode — invalid key, App Store validator rejects upload (`Invalid value: 'airplay'`); `audio` covers AirPlay. `present` activates `.playback`/`.moviePlayback` + external playback; `cleanup()` deactivates `.notifyOthersOnDeactivation`. **Don't start voice search during active playback** (`SearchViewModel` flips category to `.record`).
- **Error recovery**: `showPlaybackErrorAlert` — `-12881/-12886/-16170` → transcode guidance; `-12938/-1001/-1004/-1005/-1009` → network; else generic. iOS alert only after `retryWithDirectURL` fails. `isShowingErrorAlert` prevents stacking.
- **Debug tooling** (Settings → Interface → Debug, always visible): `debug.fastSleepTimer` (→15s); `debug.showSkipToEnd` (seeks to `duration−15s`).
- **Apple TV Remote widget metadata (`NowPlayingInfoController`)**: shared by Native and VLC paths. Owns `MPNowPlayingInfoCenter.default().nowPlayingInfo` (title / artwork / elapsed / duration / rate / `MPMediaItemPropertyAlbumTitle = seriesName` / `MPMediaItemPropertyArtist = "S{parentIndexNumber}E{indexNumber}"`). `attach` publishes a title-only placeholder immediately so the iPhone Lock Screen widget fills in <1s, then fans out `getItem` (enrich series + S×E×) and an authenticated `URLSession.shared.data(for:)` against `imageBuilder.imageURL(itemId:imageType:.primary, maxWidth:600)` for poster bytes. `update(elapsed:duration:rate:)` runs from each presenter's existing 1s tick (no second timer); both engines also call it from their play/pause state-change paths for sub-second widget sync. `RemoteCommandController` is the buttons; `NowPlayingInfoController` is the metadata — never merge them.
- **RULE — `MPMediaItemArtwork` request handler MUST be `@Sendable`**: MediaPlayer invokes it on a background queue. Without explicit annotation the trailing closure inherits the enclosing `@MainActor` Task's isolation and tvOS 26 traps it with `dispatch_assert_queue` ("Block was expected to execute on queue …"). Always write `MPMediaItemArtwork(boundsSize: image.size) { @Sendable [image] _ in image }`.
- **RULE — Episode-nav race guard on metadata fetch**: `NowPlayingInfoController` bumps an internal `generation: Int` at every `attach`/`detach` and re-checks it before writing back from the `getItem` enrich task and the artwork fetch task. A slow poster arriving after a next-track press must not overwrite the new episode's metadata — without the guard, the user sees the wrong artwork on the iPhone widget for several seconds.

## Settings Screen

Three-level navigation. Landing — tvOS: split (left brand, right nav pills, persistent accent bloom); iOS: vertical scroll + `NavigationStack`. Detail pages (Appearance/Account/Server/Interface) — tvOS `ScrollView` + back button (`onExitCommand`), iOS pushed. **Interface is itself a hub** of sub-pages (Main Menu / Home page / Detail page / Playback / Debug — `InterfaceSubcategory` enum); iOS routes via a second `.navigationDestination(item: $selectedInterfaceSub)` on the landing scroll; tvOS uses the same state-machine pattern as the category level. Interface hub uses the same pill chrome as the Settings landing (`iOSInterfaceSubButton` mirrors `iOSCategoryButton`, with `accentContainer` fill on the first row).

- **RULE — `MenuSettingsScreen+iOS` uses native `List` + `Picker(.segmented)` + `Stepper` + forced `editMode .active`**: these are deliberate exceptions to the "never system `Toggle` in settings" rule. The user explicitly requested native iOS chrome for the Mode/Kind selectors (Picker), font-size (Stepper), and always-visible drag handles (forced edit mode → native ≡ grip with no `EditButton` needed). Per-row enable/disable still uses `CinemaToggleIndicator` Button with `.buttonStyle(.borderless)` so the List cell doesn't intercept taps. Add new system controls in Settings only with the same explicit user mandate.
- **RULE — Settings detail screens (`SettingsScreen.iOSLayout`) must NOT wrap their body in a nested `NavigationStack`**: `MainTabView`'s `Tab` block + the `MoreTabScreen`-style overflow path each already provide one, and a third nested stack silently breaks `.navigationDestination(item:)` routing for sub-page pushes (Interface → Main Menu was unreachable through the More overflow until this was fixed). Pushed destinations attach to whatever stack is closest above.
- **RULE — `SettingsScreen.tvOSLayout` lifecycle gotchas**: SwiftUI re-presents this view whenever the `TabView` reorders (every `MenuConfigStore` mutation), even with the `SettingsNavCoordinator` keeping sub-nav alive. Two consequences must be handled inside this surface:
  - `.task { loadServerUsers() }` must guard against re-fires with `@State serverUsersLoadAttempted` — otherwise every menu edit re-hits `getUsers`/`getPublicUsers` and the failure path surfaces a toast on every interaction. Failure also silently falls through (no toast); `UserSwitchSheet` does its own fetch when the user actually opens it.
  - **Never** `.onAppear { proxy.scrollTo("settings.top") }` on the outer `ScrollViewReader` — it fires on every re-presentation and yanks the page to the top, dropping tvOS focus to the active tab pill. The two `.onChange(of: selectedCategory/Sub)` handlers already cover the only legitimate "scroll back to top" case (popping out of a category / sub-page detail).

- **RULE — tvOS focus**: each row is a single focusable unit (never individual sub-items). Accent/Language rows: left/right or select cycles (`onMoveCommand`).
- **Settings row SSOT** (`Settings/SettingsRowHelpers.swift` + platform extensions): every boolean toggle declared once as `SettingsToggleRow`, rendered both platforms from same list. Catalogues: `interfaceToggleRows`/`homePageToggleRows`/`detailPageToggleRows`/`debugToggleRows`. Adding/renaming a toggle = one-line edit. Expanders: `iOSToggleRowsJoined(_:accent:animated:)`, `tvToggleList(_:)` (ignores `row.tint`; `tint:` is iOS-only debug-orange). `tvActionRow(...)`, iOS atoms (`iOSSettingsRow` etc.), tvOS `tvGlassToggle`.
- **Assets**: `AppLogo.imageset` — iOS `app_logo.png` (full); tvOS `app_logo_tv.png` (front parallax layer, transparent bg, no `clipShape`).
- **Quick user switch**: `UserSwitchSheet` — grid → password → re-auth, `apiClient.reconnect(url:accessToken:)` without clearing server URL.
- **Refresh Catalogue (single trigger)**: Settings → Server `apiClient.clearCache()` + posts `.cinemaxShouldRefreshCatalogue` (Home + MediaLibrary observe). **No per-page refresh buttons** — Settings is SSOT. iOS also `.refreshable`.
- **Debug section** always visible (not `#if DEBUG`-gated) so QA doesn't need a custom build. Icons orange.

### `@AppStorage` keys (`SettingsKey` / `SettingsKey.Default` — `Shared/DesignSystem/SettingsKeys.swift`)

| Key | Default | Effect |
|-----|---------|--------|
| `motionEffects` | `true` | `motionEffectsEnabled` env — disables all animations when off |
| `render4K` | `true` | `maxBitrate` 120/20 Mbps |
| `autoPlayNextEpisode` | `true` | Auto-nav via `didPlayToEndTime` |
| `forceNativeAVPlayer` | `false` | `false` ⇒ VLC online engine; `true` ⇒ native `AVPlayer` |
| `sleepTimerDefaultMinutes` | `0` | 0/15/30/45/60/90 via `SleepTimerOption` |
| `uiScale` | `1.0` | Font scale 80–130%. Bumps `_accentRevision` |
| `darkMode` | `true` | **Via `themeManager.darkModeEnabled`**, not directly |
| `accentColor` | `"green"` | **Via `themeManager.accentColorKey`** |
| `home.showContinueWatching` | `true` | Continue Watching row |
| `home.showRecentlyAdded` | `true` | Recently Added row |
| `home.showGenreRows` | `true` | All 4 genre rows |
| `home.showWatchingNow` | `true` | Watching Now row |
| `detail.showQualityBadges` | `true` | Quality pill row on `MediaDetailScreen` |
| `library.tvBrowseLayout` | `"browse"` | tvOS-only. `browse` = hero + genre rows; `grid` = flat grid. Filters force grid regardless |
| `privacy.maxContentAge` | `0` | Rating ceiling (0=unrestricted; 10/12/14/16/18) via `apiClient.applyContentRatingLimit` |
| `menu.mode` | `"default"` | `"default"` ⇒ canonical 5 tabs; `"custom"` ⇒ user-driven (see `MenuConfigStore`) |
| `menu.customKind` | `"contentType"` | Custom mode source: `"contentType"` (movies/series toggles) or `"library"` (per Jellyfin view) |
| `menu.contentTypeEntries` | — | JSON `[MenuEntry]` — order + enabled flags for content-type mode |
| `menu.libraryEntries` | — | JSON `[MenuEntry]` — order + enabled flags for library mode |
| `menu.cachedViews` | — | JSON `[LibraryView]` — last `getUserViews` snapshot (server-scoped, invalidated on server switch) |
| `debug.fastSleepTimer` | `false` | Overrides sleep to 15s |
| `debug.showSkipToEnd` | `false` | "End" button seeking to `duration−15s` |
| `easterEgg.rainbowUnlocked` | `false` | Rainbow accent visibility — flipped by logo-tap easter egg |

## Offline Downloads (iOS / iPadOS only — product decision)

Every download file `#if os(iOS)`; `SettingsCategory.downloads.isIOSOnly = true` filters it out on tvOS.

- **URL negotiation** (`JellyfinAPIClient+Downloads.swift`): `DownloadAPI.buildDownloadRequest` is `async` — POSTs PlaybackInfo with a download-specific DeviceProfile. DirectPlay mp4/m4v/mov/m4a × h264/hevc → static-stream URL bound to a `playSessionId`. TranscodingProfile `protocol=.http` (single MP4, **NOT HLS**), `container=mp4`, `context=.static`, h264/aac → `mediaSource.transcodingURL`. Last-resort `/Items/{id}/Download`. **RULE — Never use `?static=true` straight off** (got MKV files AVPlayer can't decode). **Never use `/Videos/{id}/stream.mp4` without a PlaySessionId** (Jellyfin can return audio-only mux). `resolvePlayableEpisode`/`rawPostPlaybackInfo` are `internal` (not `private`) for `+Downloads.swift` reuse.
- **`DownloadManager`** (`@MainActor @Observable`): owns a background `URLSession` (`com.cinemax.downloads`, max-concurrent 2). Delegate is nested `Adapter: NSObject, @unchecked Sendable` bridging to MainActor. `attach(apiClient:userId:)` caches user id (PlaybackInfo needs it; queued/resumed tasks have no UI call site) — fired from `AppNavigation.task` + on `currentUserId` change. `startTask`: relaunch with `resumeData` if present, else detached Task awaiting fresh PlaybackInfo → `launchTask` on MainActor. `enqueue` prefetches artwork to `art/<id>-{poster,backdrop}.jpg`. `removeAll()` → `DownloadStorage.wipeEverything()`. `reconcileOrphans` on init wipes files whose itemId isn't in catalog.
- **Background-session relaunch**: `CinemaxAppDelegate.backgroundSessionCompletion` consumed by adapter's `urlSessionDidFinishEvents`.
- **Completion (`didFinish`)** — container detection order (server authoritative, never re-encode locally): 1. `Content-Disposition: filename=` (incl. RFC 5987 `filename*=UTF-8''…`); 2. `Content-Type` mime; 3. catalog guess. **RULE — File size**: chunked responses have no `Content-Length` (`totalBytesExpectedToWrite = -1`); after move, `stat` the destination and overwrite BOTH `totalBytes` and `bytesReceived`. **Don't `bytesReceived = totalBytes`** (caused "Zéro ko" regression).
- **Storage** (`DownloadStorage.swift`): `Application Support/Cinemax/Downloads/` → `index.json` (atomic-write), `files/<id>.<ext>` (`isExcludedFromBackup=true`), `resume/<id>.resume`, `art/`. Whole subtree excluded from iCloud backup + `FileProtectionType.completeUntilFirstUserAuthentication` (iOS only — keeps background-download writes working post-boot). `totalDiskUsage` walks `files/` AND `art/`.
- **RULE — never call `DownloadStorage.totalDiskUsage()` from a SwiftUI `body`** — it's a blocking recursive disk walk of the multi-GB media tree. `DownloadManager.totalDiskBytes` is a cached `@Observable Int64` recomputed off-main (`Task.detached`) only on init/enqueue/finish/remove/wipe. **RULE — progress writes go through `DownloadStore.updateProgress`** (≤1 disk write / 5s, compact JSON); status transitions (`upsert`/`update`/`remove`) still persist immediately. Per-tick full-catalog re-encode was the old write-amplification bug.
- **Playback dual path**: `VideoPlayerView.startIOSPlayback` checks `downloads.item(for:)` BEFORE `getPlaybackInfo`. AVKit-friendly (`isOfflinePlayable`: mp4/m4v/m4a/mov/ts/m2ts/3gp/3g2) → AVPlayer/`NativeVideoPresenter` (full feature set). Else (mkv/avi/webm…) → `VLCStreamPresenter` in offline mode (`presentOffline()`) — same HUD as online, network features auto-gated off (see Playback engine RULE above).
- **Network awareness** (`NetworkMonitor`, `@MainActor @Observable` around `NWPathMonitor`): seeds `isOnline` synchronously from `monitor.currentPath`. **RULE — Fast-fail timeouts**: every `JellyfinClient` takes `Self.fastFailSessionConfiguration` (request 8s, resource 20s, `waitsForConnectivity=false`); raw PlaybackInfo POST adds `request.timeoutInterval = 8`. `AppState.restoreSession` hydrates from keychain immediately, dispatches server calls in detached Task (non-blocking offline launch).
- **Offline UI**: `OfflineLibraryView` replaces tab content when `!network.isOnline`. `MediaDetailScreen` short-circuits to `OfflineMediaDetailView` (renders from cached `DownloadItem`, no API call) when offline + completed entry. **RULE — All offline image consumers check `downloads.localPosterURL`/`localBackdropURL` first** (Nuke disk cache keys per-URL — a poster cached at `maxWidth=180` is a different entry from `360`).
- **Detail-screen surfaces**: `DownloadButton` (state machine over `DownloadStatus`). Series detail: `Menu` ("Download season" / "Download whole series" loops `getEpisodes`). Per-episode inline `DownloadButton` in `MediaDetailEpisodeCard`.

## Admin (iOS-only — product decision)

`SettingsCategory.visibleCases(isAdmin:isTVOS:)` short-circuits when `isTVOS`; every `Shared/Screens/Admin/` file `#if os(iOS)`.

- **Gating**: `AppState.isAdministrator` (cached; refreshed on login/reconnect/user switch via `AppState.refreshCurrentUser()`). Server authoritative; client gating is UX. `AppState.currentUser: UserDto?` populated alongside.
- **API surface**: `AdminAPI` slice. Device listing/revocation stays on `AuthAPI` (server returns full fleet to admins by caller identity).
- **Settings routing**: `.administration` (Dashboard + Metadata Manager) and `.advancedAdmin` (Users/Devices/Activity/Playback/Plugins/Catalog/Tasks/Network/Logs/API Keys). Hidden when `!isAdministrator`.
- **Scaffolds** (`Admin/Components/`): `AdminLoadStateContainer`; **RULE — `AdminFormScreen` every admin editor uses explicit save (never auto-save)** — admin changes have blast radius (policy revocations, password resets); sticky footer + `interactiveDismissDisabled(isDirty)` + discard confirmation. `AdminTabBar`, `AdminSectionGroup`. `AdminItemMenu` — shared `Menu` for one `BaseItemDto` (Identifier/Edit/Refresh/Delete); **does NOT host its own `.navigationDestination`** (silently ignored — lazy-container rule), fires `onSelectDestination(_:)`. `DestructiveConfirmSheet` (type-to-confirm) reserved for irreversible ops; reversible destructives use `.confirmationDialog` `.destructive`.
- **Self-protection** (client-side; server enforces too): can't delete/demote/disable yourself; can't revoke current device (`KeychainService.getOrCreateDeviceID()` vs `DeviceInfoDto.id`, "THIS DEVICE" pill).
- **Performance**: Dashboard `async let` fan-out (partial render on single failure). Activity log infinite-scroll (50/page). Tasks live-poll 2s while running, self-cancels.
- **Identify flow** (`Admin/Identify/`): `IdentifyFlowModel` (`@Observable`) — standalone `IdentifyScreen` (form → grid → confirm) + composed in `MetadataEditorViewModel.identify`. Kind-aware (movies: IMDb/TMDb Film/TMDb Coffret; series: IMDb/TMDb/TVDb). Provider IDs under `"Imdb"`/`"Tmdb"`/`"TmdbCollection"`/`"Tvdb"`.
- **Metadata Manager**: five-tab editor (General/Images/Cast/Identify/Actions). Images use `downloadRemoteImage` (server fetches URL, no phone proxy). Delete via `DestructiveConfirmSheet` (title as confirm phrase).
- **ImageType quirk**: CinemaxKit's `ImageType` narrower than `JellyfinAPI.ImageType`. Admin code uses `JellyfinAPI.ImageType` explicitly-qualified; `ImageURLBuilder.imageURLRaw(itemId:imageTypeRaw:)` string-keyed overload renders the wider set without widening `CinemaxKit.ImageType`.
- **RULE — API key security** (`Admin/ApiKeys/`, keys = passwords): masked by default (first 4 + last 4); `.privacySensitive()`; per-row Copy is the only export path (no share sheet); `appState.accessToken` match → `CURRENT SESSION`, revoke hidden; `revokedKeyIds`/`revealedKeyIds` dropped on disappear. **Never log key values or send to analytics.** `revokeApiKey` takes the token itself as identifier (Jellyfin quirk); forget value on return.
- **Poster-card admin overlay**: `LibraryPosterCard` paints ellipsis `AdminItemMenu` bottom-right when `isAdministrator`. Menu and detail-push `NavigationLink` are `ZStack` siblings (not nested).

## MediaDetailScreen

`MediaDetailViewModel` auto-resolves Episode/Season → parent Series (by `seriesID`, loads seasons + episodes) + `getNextUp()`. `selectSeason()` uses a generation counter for stale results. Use `resolvedType` (not initial `itemType`) for layout. tvOS detail refresh: `VideoPlayerCoordinator.lastDismissedAt` (via `TVDismissDelegate` `onDismiss`); screen `.onChange` reloads after dismiss (iOS reloads via `.task` on pop).

- **Resume / next-up** (`actionButtons` → `PlayActionButtonsSection: View, Equatable`): custom `nonisolated static func ==` compares resume + prev/next identity, ignores closure → `.equatable()` short-circuits re-renders. Same pattern on extracted `MediaDetail{Cast,Similar}Section`/`Episode{Card,Row}` (wrap non-Sendable DTO reads in `MainActor.assumeIsolated` — escape hatch #4). tvOS episode list uses `LazyVStack`.
- Movie `playbackPositionTicks > 0` not `isPlayed`: progress bar + remaining + "Lecture" via `PlayLink(startTime:)`. Series: `nextUpEpisode`. **Play from beginning**: when `showResume`, secondary ghost `PlayLink` with `startTime: nil`. `userData.playbackPositionTicks`/`runTimeTicks` are `Int?`; `isPlayed` is `Bool?`.
- **Quality badges** (`MediaQualityBadges.swift`): gated on `@AppStorage("detail.showQualityBadges")`. From `item.mediaSources?.first`. Resolution by height (4K/1080p/720p/SD), HDR (`VideoRangeType` → Dolby Vision/HDR10+/HDR10/HDR), codec, audio format (first-hit: Atmos/TrueHD/DD+/DD/DTS/AAC/FLAC/Opus/MP3), channels. `EmptyView()` when none.
- **Episode nav**: `episodeNavigation(for:)` O(1) from `episodeNavigationMap` (current season) or `nextUpNavigationMap` (cross-season next-up).
- **Episode metadata line** (`MediaDetailEpisodeMetadataLine`, own file): shared tvOS/iOS, joined ` • ` — in-progress "Xm remaining" / else runtime / + `premiereDate`.

## HomeScreen

`HomeViewModel` loads `resumeItems` + `latestItems` in parallel (`TaskGroup`). `heroItem = resumeItems.first ?? latestItems.first`. Resume nav: per resume episode season's list fetched (grouped by `seasonID`), `precomputeEpisodeRefs` once/season, O(1) `buildEpisodeNavigation` → `resumeNavigation: [String:(prev,next,navigator)]`. Genre rows: `getGenres`, shuffle, pick 4, items in parallel; **failures become `.failed`** (renders retry — transient errors don't silently hide content). Watching Now: `getActiveSessions(activeWithinSeconds:60)`, drop current user + require `nowPlayingItem`. Configurable layout (`home.show*`, default true; hero never gated). Empty state in `ScrollView` (pull-to-refresh works). **tvOS scroll-to-top on reappearance**: `ScrollViewReader` + `.id("home.top")` attached *directly to `heroSection`* (fallback `Color.clear.frame(height: 0)` only when no hero) + `.onAppear` `scrollTo`. MovieLibraryScreen/SearchScreen/Settings tvOS landing keep the separate zero-height sentinel because their first visible row already sits flush against the safe-area top — see tab-bar pill RULE below.

- **RULE — tvOS 26 tab bar pill alignment heuristic**: Liquid Glass reserves a constant 157pt `safeAreaInsets.top` container above the scroll content (verified by `GeometryReader` — identical on every tab), but the active pill aligns to either the **bottom** of that container ("expanded", default) or the **top** ("compact", ~30pt higher visually) based on whether the first scrollable row touches the safe-area top edge. Any leading gap — including the implicit `LazyVStack` `spacing:` between a zero-height sentinel and the first visible row — flips the pill into compact mode, making the menu look like it shifted upward on that tab (and that tab only). Fix pattern: `LazyVStack(spacing: 0)` + explicit `.padding(.bottom, spacing6)` between rows + attach the scroll-anchor `.id(scrollTopID)` directly to the first visible row instead of a separate sentinel. Reference: `HomeScreen.content` (the hero carries `.id(scrollTopID)` and the LazyVStack uses `spacing: 0`). Films/Recherche/Réglages don't need the workaround because their first row (`tvTopBar` / `searchField` / `tvLandingPage`) already sits flush — they have `LazyVStack(spacing: 0)` or use eager VStacks. Diagnosis is non-trivial because content-level padding, focusable proximity, `toolbarBackgroundVisibility`, and body-level modal modifiers all have **no effect** on the pill alignment — only the gap above the first scroll row matters.

## SearchScreen

`SearchViewModel.search(using:)` debounces 400ms → `searchItems(... limit:30)`. Decomposition: shell + file-private `VoiceSearchButton` (iOS), `SearchResultsGrid`, `SearchResultCard`. iOS mic → `SpeechRecognitionHelper`. **Surprise Me**: `fetchRandomMovie`/`fetchRandomSeries` are separate methods (Swift 6 flags `[BaseItemKind]` built from a parameter as non-Sendable crossing the API actor; literal arrays work).

## Localization

- `LocalizationManager` (`@Observable`, injected from `AppNavigation`). Default `fr`, also `en`.
- **RULE — All strings via `loc.localized("key")` / `loc.localized("key", args...)` — never hardcoded.** Strings at `Resources/{lang}.lproj/Localizable.strings`. Reactivity: `@ObservationIgnored` + `@AppStorage` + `_revision`. Use plural helpers (e.g. `remainingTime(minutes:)`), not inline branching.
- **RULE — never surface raw `error.localizedDescription` to users** (leaks cryptic SDK strings like `unacceptableStatusCode(401)`). Map via `LocalizationManager.userFacingMessage(for:)` (→ network / session-expired / generic localized text); log the raw error instead. VMs that show errors take `loc:` and `logger`.

## Toasts & Empty states

- `ToastCenter` (`@Observable`, injected at `AppNavigation` root) — single-toast queue, auto-dismiss. `ToastOverlay` top-anchored glass pill. API `.success/.error/.info(_:message:duration:)`. **Use for action feedback and recoverable errors. NOT for critical errors needing a decision — use `UIAlertController`.**
- `EmptyStateView` (icon + title + optional subtitle + action). Used by Home (all empty), filtered library grid ("Clear filters" resets `LibrarySortFilterState()`), `UserSwitchSheet`.

## Dynamic Type (iOS)

`.dynamicTypeSize(.xSmall ... .accessibility2)` at `AppNavigation` root (caps below accessibility sizes that break hero/tab-bar). `CinemaFont.dynamicBody/dynamicBodyLarge/dynamicLabel(_:)` use `UIFontMetrics`. **Apply dynamic variants only to reading-heavy surfaces** — hero/display/headline titles keep fixed fonts to protect layout.

## Image Patterns (all RULE)

- `ImageURLBuilder` → `/Items/{id}/Images/{type}`. **Backdrop sizing**: use `ImageURLBuilder.screenPixelWidth` — never hardcode `1920`.
- **Image cache**: `AppNavigation.init()` configures `ImagePipeline.shared` with 500 MB disk + explicit `ImageCache` `costLimit = 256 MB` (Nuke's ~100 MB default evicts mid-render on tvOS — 4K backdrops decode to 4–8 MB each).
- **Backdrop fallback**: `item.backdropItemID` (→ `parentBackdropItemID ?? seriesID ?? id`). **No-backdrop placeholder**: gate on `item.hasBackdropImage` (NOT `backdropItemID` — always non-nil) → `BackdropFallbackView` (centered `film` symbol over `surfaceContainerLow` + accent radial, under `CinemaGradient.heroOverlay`). Wired in `MediaDetailScreen.backdropSection`/`HomeScreen.heroSection`/`LibraryHeroSection`.
- **Always `CinemaLazyImage`** — never `LazyImage` directly. Card containers: `Color.clear` + `.aspectRatio()` + `.frame(maxWidth: .infinity)` + `.overlay { CinemaLazyImage }` + `.clipped()`. **Backdrop (full-bleed ZStack)**: `CinemaLazyImage` must have `.frame(maxWidth:.infinity, maxHeight:.infinity)` — else ZStack sizes from natural 1920px pushing title off-screen. Outer container `LazyVStack(alignment: .leading)`.
- **PosterCard title alignment**: hidden `Text("M\nM").hidden()` placeholder + actual title overlaid top-aligned → uniform row height.

## App Icons

- iOS: `Resources/Assets.xcassets/AppIcon.appiconset/` (1024² light/dark/tinted). tvOS: `App Icon & Top Shelf Image.brandassets/` (3-layer parallax + Top Shelf 1920×720 + Wide 2320×720). In-app logo: `AppLogo.imageset/`. Standalone source: `appIcon.png` at project root.

## Build

```bash
# iOS
xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
# tvOS
xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
# Regenerate Xcode project
cd Cinemax && xcodegen generate
```

**Build verification gotchas (RULE)**:
- Always pair pipes with `set -o pipefail` (`set -o pipefail; xcodebuild ... | grep ...`) — without it `tail`/`grep` swallow xcodebuild's exit code and a failed build returns 0. Confirm by reading output for `** BUILD SUCCEEDED **` / `** BUILD FAILED **`, not just shell exit.
- Don't run iOS + tvOS builds in parallel against the same DerivedData — they race on `build.db` ("database is locked"). Run serially.

**Versioning**: `iOS/Info.plist` + `tvOS/Info.plist` use `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)` — `project.yml` `settings.base` is SSOT. Bump `MARKETING_VERSION` per user-visible release; `CURRENT_PROJECT_VERSION` per archive/upload.

## Claude Code automations (`.claude/`)

Project-shared, checked into git. Per-developer overrides in `.claude/settings.local.json` (gitignored).

- **Hooks** (`.claude/settings.json`): `PreToolUse` blocks edits to `Cinemax.xcodeproj/project.pbxproj` (XcodeGen output — edit `project.yml`). `PostToolUse` auto-runs `xcodegen generate` after `project.yml` edits.
- **Skills**: `localize-check` (FR/EN `Localizable.strings` key parity + hardcoded-string grep), `design-system-review` (`conventions.md` checklist grep sweep on staged files).
- **Subagents**: `tvos-focus-reviewer`, `swift6-concurrency-reviewer`.
- **MCP servers** (`~/.claude.json` project scope): `context7` (live docs), `github` (token from `gh auth token`).
