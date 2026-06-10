# Cinemax - Jellyfin Client for Apple Platforms

Native Jellyfin client for iOS 26+ and tvOS 26+. "Cinema Glass" design system (dark glassmorphism, editorial layouts, no borders). SwiftUI multi-platform, single Xcode project (iOS + tvOS targets). Swift 6 strict concurrency.

> This file = rules, gotchas, and non-derivable context. Feature *behavior* is derivable from the code — read the owning file. Lines tagged **RULE** override default behavior.

## Architecture

- **CinemaxKit** local Swift Package at `Packages/CinemaxKit` — networking, models, persistence.
- `@Observable` + `@MainActor` for all state; `JellyfinClient` wrapped with `NSLock` + `nonisolated(unsafe)` for Sendable.
- **RULE — iOS `NavigationStack`**: `navigationDestination(item:)` destinations render in a separate context — `@Observable` changes won't re-render unless the destination is a standalone `View` struct with its own `@Environment`, not an extension method returning `some View`.
- **RULE — Lazy-container navigation**: SwiftUI silently ignores `navigationDestination(item:)` inside `LazyVGrid/LazyVStack/LazyHStack/List`. Hoist the modifier to a non-lazy ancestor; bubble the action up via a callback mutating a screen-level `@State`. Reference: `AdminItemMenu.onSelectDestination` → `@State AdminMenuPushIntent?`. Used by `MovieLibraryScreen`, `MediaDetailScreen`.

### iOS 26 / tvOS 26 API rules (all RULE)

- **`UIButton`**: use `UIButton.Configuration`; never `UIButton(type:)` + `setTitle/titleLabel?.font/…`. Pattern in `NativeVideoPresenter`. Frosted bg via `config.background.customView = UIVisualEffectView(...)`.
- Free SwiftUI helpers returning `some View` that touch `PrimitiveButtonStyle.plain`/`Font`/etc. must be `@MainActor`.
- **iPad**: `UIRequiresFullScreen` removed (deprecated); split view / Stage Manager allowed but hero/backdrop layouts not yet hardened for resize.
- **Toolbar + Liquid Glass**: iOS 26 auto-renders `ToolbarItem` buttons with Liquid Glass. **Never** add `.buttonStyle(.glass)`/`.glassProminent` on toolbar items (nests double capsules). Active state via `.tint(themeManager.accent)` + `.fill` icon variant.

### Dependencies

`jellyfin-sdk-swift` v0.6.0, `Nuke`/`NukeUI` v12.9.0, `AVKit`/`AVPlayer`, `SwiftVLC` (libVLC 4.0, Swift 6 — [harflabs/SwiftVLC](https://github.com/harflabs/SwiftVLC), pinned **exactVersion 0.3.0**; ≥0.4.0 needs swift-tools 6.3 / Xcode 26.3+, toolchain is Swift 6.2.3 / Xcode 26.2; 0.3.0 is newest tag both 6.2-compatible AND shipping the PiP API — bump on Xcode 26.3+).

- `import SwiftVLC` works iOS + tvOS (`Player` is `@Observable @MainActor`; `VideoView`/iOS-only `PiPVideoView` are SwiftUI representables hosted in UIKit presenters via a child `UIHostingController`). Both targets link it — VLC is the default online playback engine on both.
- **RULE — Never re-add `VLCKitSPM`** — libVLC 3.x + 4.0 in one binary collide on `libvlc_*` C symbols. SwiftVLC replaced it (native PiP, object-based `Track` API fixing the audio-switch silence bug, Swift-6-native).
- **RULE — Adding a new file under `Shared/` requires re-running `xcodegen generate`** before it builds (the PostToolUse hook auto-regens only on `project.yml` edits, not new files; symptom: "cannot find type X in scope" for a type that exists).
- **RULE — `@Observable` properties must NOT carry `didSet`/`willSet`**: the macro instruments setters via `withMutation`; a property-observer body runs *after* the observation commits, and on collection-of-`Codable`-value-types props (e.g. `[MenuEntry]`) the combo intermittently fails to deliver re-renders (symptom: tab bar doesn't update after a reorder until the user taps anywhere). Pattern: keep stored props plain `var T`, expose explicit `set*(_:)` mutators (mutate + persist), use custom `Binding(get:set:)` in Pickers/Toggles. Ref: `MenuConfigStore.setMode`/`setCustomKind`.

### API protocol split (`Packages/CinemaxKit/.../APIClientProtocol.swift`)

`APIClientProtocol = ServerAPI & AuthAPI & LibraryAPI & PlaybackAPI & AdminAPI & DownloadAPI`. VMs needing multiple domains take `APIClientProtocol`; leaf controllers narrow to a slice (`PlaybackReporter`/`SkipSegmentController` → `any PlaybackAPI`; `NowPlayingInfoController` → `any LibraryAPI`; `DownloadManager` → `any DownloadAPI`). `AdminAPI` is a privilege boundary — gated on `AppState.isAdministrator`; server enforces authoritatively.

### Swift 6 `nonisolated` escape hatches (safe when body only reads parameters)

1. `View, Equatable` sub-type inside a `@MainActor` screen needs `nonisolated static func ==` (`Equatable` isn't main-actor-isolated). See `PlayActionButtonsSection`.
2. A `@MainActor` class's `static func` returning non-Sendable into a `TaskGroup @Sendable` closure needs `nonisolated private static func`. See `HomeViewModel.fetchGenreItems`.
3. A `nonisolated static func` reading a `static let` needs the constant `nonisolated` too (Sendable types only). See `SearchViewModel.sanitize`.
4. When `nonisolated static func ==` reads a non-Sendable DTO stored property, wrap the body in `MainActor.assumeIsolated { ... }` (safe — SwiftUI diffs on main actor). See `MediaDetail*Section`.
5. **`@retroactive @unchecked Sendable` for SDK value enums**: the SDK doesn't annotate `BaseItemKind` (a `String`-raw enum); Swift 6.1 region isolation rejects `[BaseItemKind]?` crossing async/actor boundaries even with `@preconcurrency import`. Bridge in `Models/JellyfinSendable.swift`. Strictly scope to safe value types (String-raw enum, no associated values).

## Project Structure

```
Shared/
  DesignSystem/             CinemaGlassTheme, ThemeManager, AccentOption (+AccentEasterEgg), LocalizationManager, ToastCenter, GlassModifiers, FocusScaleModifier, AdaptiveLayout, TVButtonStyles, SettingsKeys, SleepTimerOption
  DesignSystem/Components/   CinemaButton, CinemaLazyImage, PosterCard, WideCard, CastCircle, ContentRow, ProgressBarView, RatingBadge, GlassTextField, FlowLayout, ToastOverlay, EmptyStateView, ErrorStateView, LoadingStateView, AlphabeticalJumpBar, CinemaToggleIndicator, RainbowAccentSwatch, MediaQualityBadges, UserAvatar
  Navigation/               AppNavigation (auth routing), MainTabView, MenuConfig (MenuConfigStore + ResolvedTab)
  Screens/                  Home/Login/ServerSetup/Search/MovieLibrary/TVSeries/PrivacySecurity, MediaDetailScreen + MediaDetail* siblings, VideoPlayerView, NativeVideoPresenter, HLSManifestLoader, PlayLink
    VideoPlayer/            PlaybackReporter, SkipSegmentController, SleepTimerController, ChapterController, EndOfSeriesOverlayController, RemoteCommandController, NowPlayingInfoController, VLCStreamPresenter (online iOS+tvOS via stream init AND offline iOS via second init — same HUD class), CinemaxStreamProxy (StreamTransportPolicy IPv6 probe + loopback HTTP→URLSession proxy); shared extractions: PlayerTimeFormat, PlayerEngineSurface (SwiftVLC host), PlayerTransportViews (TVScrubBar/ChapterChip/PassthroughView)
    Settings/               SettingsScreen + iOS/tvOS extensions, SettingsAppearanceView+iOS, SettingsRowHelpers, SettingsTV{AccentPicker,LanguagePicker,ProfileSection,ActionRow}, SettingsNavCoordinator (hoisted sub-nav state), MenuSettingsScreen + iOS/tvOS extensions
    Downloads/              (iOS-only) DownloadButton, DownloadsScreen, OfflineLibraryView, OfflineMediaDetailView, DownloadItem+BaseItemDto
    Admin/                  (iOS-only) Dashboard/Users/Devices/Activity/Tasks/Plugins/Catalog/Playback/Network/Logs/ApiKeys/Metadata/Identify
    Admin/Components/       AdminLoadStateContainer, AdminFormScreen, AdminTabBar, AdminSectionGroup, AdminItemMenu, DestructiveConfirmSheet
  ViewModels/               per-screen VMs + VideoPlayerCoordinator + DownloadManager (iOS) + NetworkMonitor
iOS/ tvOS/                  app entry points
Resources/{fr,en}.lproj/    Localization (fr default)
Packages/CinemaxKit/        Models (incl. JellyfinSendable), Networking (JellyfinAPIClient, ImageURLBuilder, +Downloads), Persistence (KeychainService, DownloadStore, DownloadStorage)
docs/design-system/         Canonical design system reference
```

`Shared/Screens/` is mostly flat. Exceptions: `Settings/` and `Admin/` feature folders. `PlayLink.swift` + `MediaDetail*.swift` siblings stay at root (tightly coupled to parents).

## Design System (all RULE — `docs/design-system/conventions.md` rejection checklist is authoritative; read `docs/design-system/README.md` before editing UI)

- Tokens in `CinemaGlassTheme.swift`. All `CinemaColor` use `Color.dynamic(light:dark:)`. **Never `Color(hex:)` for new tokens.**
- **Shared toggle**: `CinemaToggleIndicator` (Capsule+Circle pill), parent-driven. Never system `Toggle` in settings.
- **No 1px borders** — use color shifts; glass panels via `.glassPanel()`.
- **Accent**: `themeManager.accent`/`.accentContainer`/`.accentDim`/`.onAccent` — never `CinemaColor.tertiary*`. All dual-mode.
- **Dark/Light**: always route through `themeManager.darkModeEnabled =` / `accentColorKey =` — direct `@AppStorage` writes bypass `_accentRevision` and break reactivity. `.preferredColorScheme()` applied at root in `AppNavigation` only.
- **Hardcoded `.white`/`.black`**: only inside the video player (always dark) and on saturated `accentContainer`. Else `CinemaColor.onSurface`/`onSurfaceVariant`.
- **Font scaling**: `CinemaScale.factor` = 1.4× base on tvOS × user `uiScale` (80–130%). **RULE — no bare `.font(.system(size: N))` numeric literals** — wrap `N` in `CinemaScale.pt(...)` or a `CinemaFont.*` token, else it ignores `uiScale`/tvOS 1.4×.
- **tvOS focus**: `@FocusState` + `.focusEffectDisabled()` + `.hoverEffectDisabled()`. 2px accent `strokeBorder`, no scale/white bg. Cards: `CinemaTVCardButtonStyle`. Settings rows: `.tvSettingsFocusable()`. **Trait caveat**: a focused `Button` flips `UITraitCollection` to light-mode inside its label; `tvSettingsFocusable` takes `colorScheme` and injects on content + background shape — always pass `themeManager.darkModeEnabled ? .dark : .light`. **Hero `.focusSection()` rule**: any hero with Play/More Info in `.overlay(alignment: .bottomLeading)` of a tall `Color.clear` block (Home + Library) needs `.focusSection()` on the buttons row AND the row above (`tvTopBar`) — else up-presses get absorbed in the hero bounds.
- **iOS focus**: `.cinemaFocus()` (accent border + shadow).
- **CinemaButton styles**: `.accent` = primary CTAs (saturated `accentContainer` + `.white`); `.primary` = neutral gradient (only `DestructiveConfirmSheet`); `.ghost` = secondary (Retry, Clear Filters).
- **Motion Effects**: `motionEffectsEnabled` env key (from `@AppStorage("motionEffects")`); when off, all `.animation()` → nil.
- Platform-adaptive via `#if os(tvOS)` or `horizontalSizeClass`.

## Navigation

- `AppNavigation` → Keychain session check → `apiClient.reconnect()` + `fetchServerInfo()`. Injects `ThemeManager`/`LocalizationManager`/`ToastCenter`/`MenuConfigStore`; applies `.preferredColorScheme()` at root.
- Flow: no server → `ServerSetupScreen` → `LoginScreen` → `MainTabView` (top tabs tvOS, sidebar iPad, bottom tabs iPhone).
- **RULE — All play buttons use `PlayLink<Label>`** (Button+coordinator on tvOS, `NavigationLink` on iOS) — never direct `NavigationLink` to `VideoPlayerView`.
- **Session expiry / 401**: `JellyfinAPIClient.setOnUnauthorized` (`@Sendable () -> Void`) → posts `.cinemaxSessionExpired`; `AppNavigation` runs `appState.logout()` + toast. Lazy recovery (no eager validation); 6 hot paths instrumented. Detection = string-match on `(401)`/`NSURLErrorUserAuthenticationRequired`.

### Custom menu / dynamic tabs (`MenuConfigStore`)

`MainTabView` consumes `menuConfig.resolvedTabs` (computed from `mode` / `customKind` / persisted entry arrays / `availableViews` cache). Three modes:

- **`.default`** — canonical 5 tabs (Home, Movies, TV Shows, Search, Settings).
- **`.custom + .contentType`** — user picks which of the canonical 5 are enabled and in what order.
- **`.custom + .library`** — surfaces individual Jellyfin libraries (`getUserViews`) as tabs, filtered to video kinds (`movies`/`tvshows`/`homevideos`/nil — `LibraryView.nonVideoCollectionTypes` blacklist excludes `boxsets`/`music`/`photos`).

- **RULE — `MenuConfigStore.maxEnabledTabs = 5` (hard cap)**: `TabView` on iPhone compact width instantiates a `UIMoreNavigationController` when >5 tabs; any mutation crossing the 5↔6 boundary tears it down and dumps the user back to the first tab (UIKit lifecycle quirk). Toggling-on a 6th entry is refused via `ToggleResult.refusedCapReached` → toast.
- **RULE — Library-mode tabs accept `parentId: String?` + `overrideTitle: String?` on `MediaLibraryScreen`** so each tab scopes queries to that view id. `BaseItemKind?` is nilable: `nil` = "no `includeItemTypes` filter" — needed for `Mixed`/`Other` libraries where items aren't reliably typed.
- **RULE — Don't tag a tab with `role: .search`** on iPhone: per Apple WWDC 2024, a search-role tab is force-placed at the trailing edge regardless of declaration order, conflicting with reorderable menus (was the source of "redirected to Search" after a drag). Search is a regular `Tab`.
- **RULE — Use `Tab(value:)` over `.tabItem + .tag` on both platforms**: `.tabItem + .tag` doesn't preserve child-view `@State` across a `ForEach` collection diff on tvOS — every `MenuConfigStore` mutation remounted `SettingsScreen` and dropped its sub-nav. `Tab(value:)` builds identity off `value` and survives collection mutations.
- **RULE — Settings sub-nav state lives on `SettingsNavCoordinator`, not `SettingsScreen.@State`**: tvOS's `TabView` is bridged to `UITabBarController` which indexes child VCs by **position**; any tab-bar layout shift — even with `Tab(value:)` — recreates the moved tab's `UIHostingController`, dumping its `@State`. `selectedCategory`/`selectedInterfaceSub` live on `SettingsNavCoordinator` (`@MainActor @Observable`) instantiated on `AppNavigation` (never remounts), injected via `.environment`. `SettingsScreen` exposes thin computed pass-throughs; `$`-projection cases use `@Bindable var nav = settingsNav`. iOS uses it too for symmetry.
- **RULE — `MainTabView` renders the bar from a `@State displayedTabs` snapshot, not live `menuConfig.resolvedTabs`**: rendering off the live `@Observable` reconfigures the UIKit-backed bar on every fine-grained edit, which on tvOS pulls focus off the touched row onto the top-bar pill ("page reload"). The snapshot is **frozen while `settingsNav.selectedInterfaceSub == .menu`**. **Structural** mutations bypass the freeze: `onChange(of: menuConfig.mode)` (covers Reset) and `onChange(of: menuConfig.customKind)`. The bar catches up when the user backs out of the editor.
- Persistence is explicit (`SettingsKey.menu*`) via mutators, **never** property `didSet`. `refreshAvailableViews()` is idempotent (`if views != availableViews`) to avoid spurious Observation cycles. Mandatory IDs: `[settingsID]` only (Home/Search default-on but non-mandatory).
- **MenuSettingsScreen tvOS Mode/Kind rows use a single `CinemaToggleIndicator`** (not two pills) — same shape as `tvGlassToggle` in Apparence, icon+label flip with state. Each flip fires a `menu.refresh.confirm` toast (the bar rebuilds and the pill is the only signal explaining the re-layout). **Do NOT** toast on the "Refresh libraries" row (already shows status via spinner + `lastFetchError` subtitle).

## Server Setup & Login

Two-step pre-auth flow, shared mobile design. Discovery (`JellyfinServerDiscovery` + `ServerDiscoverySheet`): UDP broadcast port 7359; probes `255.255.255.255` **and** each interface's directed broadcast via `getifaddrs`. `scan()` auto-retries once after 800ms on empty (iOS local-network permission race). `NSLocalNetworkUsageDescription` in `iOS/Info.plist`.

- **RULE — LoginScreen mobile caveat**: ServerSetupScreen's `.padding(.horizontal, spacing4)` outside `.glassPanel` is silently dropped in `LoginScreen.mobileLayout` under iOS 26. Workaround: `.frame(maxWidth: formMaxWidth)` (350pt) on form panel + actions VStack. Don't "fix" without pixel-sampling.
- **Rainbow easter egg**: top icon block is a `Button` → `AccentEasterEgg.tap(…)` (resolver in `SettingsScreen.swift`). Cycles `AccentOption.cyclingCases`; unlock flips `rainbowUnlocked`. `ThemeManager` checks `isRainbow` first → HSB from `_rainbowHue`.

## Media Library (`MediaLibraryScreen`)

Unified, parameterized by `BaseItemKind`. State: `LibrarySortFilterState` (default `dateCreated` desc).

- **Browse vs filtered**: browse layout (hero + genre rows + browse-genres grid) when `!isFiltered`; any filter → flat grid. `isFiltered` = genre chips OR `showUnwatchedOnly` OR `selectedDecades`. tvOS also honors `library.tvBrowseLayout` (`grid` forces flat grid even unfiltered).
- Title count uses `isFiltered`. `loadInitial` guarded by `hasLoaded` (prevents re-randomization on tab switch); `reload(using:)` bypasses (pull-to-refresh, `.cinemaxShouldRefreshCatalogue`).
- Filters: Unwatched → `filters:[.isUnplayed]`; Decade `selectedDecades: Set<Int>` → `expandedYears` for `getItems(years:)`.
- **RULE — tvOS Filters button opens `LibrarySortFilterSheet` via `.fullScreenCover`, not `.sheet`** (`.sheet` on tvOS 26 renders a narrow modal whose toolbar items show as broken white pills).
- `LibrarySortFilterSheet` split bodies: iOS `NavigationStack` + toolbar Apply/Reset; tvOS title + scrollable sections + sticky footer (Reset `.ghost`, Apply `.accent`), sort hidden (top-bar `confirmationDialog`), per-section Clear inline as trailing FlowLayout chip.
- **tvOS button styles** (`TVButtonStyles.swift`): `TVFilterChipButtonStyle` (capsule, press scale 0.95); `TVFilterRowButtonStyle` (full-width rows, **no press scale** — visibly shifts label on wide rows).
- **iOS jump bar**: `AlphabeticalJumpBar` only when `sortBy == .sortName && sortAscending && count > 20`.

## Video Playback

> **Full detail: [`docs/architecture/playback.md`](docs/architecture/playback.md).** Engine internals, the native/AVPlayer flow, tvOS custom transport, and the IPv6 proxy live there. The override-rules below are the in-context summary — read the doc before touching the player.

**Engine**: VLC is the default online engine on iOS + tvOS (fixes the MKV/DV freeze — `AVPlayer` can't open MKV, forcing a 4K HEVC + DV→SDR re-encode the server can't do real-time). `SettingsKey.forceNativeAVPlayer` (default `false`) falls back to `AVPlayer`/`NativeVideoPresenter`. `VLCStreamPresenter` (iOS+tvOS, stream + iOS-only offline init) hosts VLC; `NativeVideoPresenter` hosts AVPlayer (UIKit modal, `@MainActor` sub-controllers + one 1s `addPeriodicTimeObserver`). `NowPlayingInfoController` (metadata) + `RemoteCommandController` (buttons) shared by both — never merge them. tvOS transport is fully custom (no `AVPlayerViewController`).

These are the load-bearing override-rules; the doc has the rest plus full causal context.

- **RULE — Device profile split** (`JellyfinAPIClient+Playback.swift`): `getPlaybackInfo(... engine:)`. `.vlc` → `buildVLCDeviceProfile` (broad DirectPlay, no container restriction, no transcode); `.native` → `buildAppleDeviceProfile`. **API default `.native`**; engine chosen at `VideoPlayerCoordinator` (tvOS) / `VideoPlayerView` (iOS). Native profile: **never include `mpeg4`** in HLS transcode (Jellyfin injects `mpeg4-*` params AVFoundation rejects); `maxBitrate` 120/20 Mbps via `render4K`.
- **RULE — broken-IPv6 servers route through a loopback proxy** (`CinemaxStreamProxy.swift`): libVLC has no Happy-Eyeballs and ignores `ipv4`/`ipv6`, so a black-holed AAAA stalls it ~75s. `StreamTransportPolicy.shared` probes once, sets `preferProxy` only if the IPv6 route *hangs* (not fast-fails); healthy servers keep the byte-identical direct path. **The proxy's `URLSession` MUST use a CONCURRENT delegate queue** (`maxConcurrentOperationCount=8`) — MKV demux fires simultaneous `Range` requests and a serial queue head-of-line-blocks the seek → `cannot seek`.
- **RULE — MUST present native player via UIKit modal** (SwiftUI presentation corrupts `TabView`/`NavigationSplitView` focus). **Do NOT embed `AVPlayerViewController` as a child VC on tvOS** (constraint conflicts + `-12881`). Dismiss: iOS `viewWillDisappear`, tvOS `TVDismissDelegate`. tvOS Skip Intro/Credits uses `AVPlayerViewController.contextualActions` (only focusable-button mechanism that coexists with the transport bar).
- **RULE — AirPlay (iOS)**: `UIBackgroundModes = [audio]` in `project.yml`. **Do not add `airplay`** (invalid key, App Store rejects upload).
- **RULE — `MPMediaItemArtwork` request handler MUST be `@Sendable`** (MediaPlayer invokes on a background queue; tvOS 26 traps with `dispatch_assert_queue` otherwise): `MPMediaItemArtwork(boundsSize:) { @Sendable [image] _ in image }`.

## Settings Screen

Three-level navigation. Landing — tvOS: split (brand + nav pills + accent bloom); iOS: scroll + `NavigationStack`. Detail pages (Appearance/Account/Server/Interface) — tvOS `ScrollView` + back (`onExitCommand`), iOS pushed. **Interface is itself a hub** of sub-pages (Main Menu / Home page / Detail page / Playback / Debug — `InterfaceSubcategory`); iOS routes via a second `.navigationDestination(item: $selectedInterfaceSub)`; tvOS uses the category-level state-machine pattern. Hub reuses the landing pill chrome (`iOSInterfaceSubButton` mirrors `iOSCategoryButton`).

- **RULE — `MenuSettingsScreen+iOS` uses native `List` + `Picker(.segmented)` + `Stepper` + forced `editMode .active`**: deliberate exceptions to the "never system `Toggle`" rule — user explicitly requested native iOS chrome for Mode/Kind, font-size, and always-visible drag handles. Per-row enable/disable still uses `CinemaToggleIndicator` Button with `.buttonStyle(.borderless)`. Add new system controls in Settings only with the same explicit mandate.
- **RULE — Settings detail screens (`SettingsScreen.iOSLayout`) must NOT wrap their body in a nested `NavigationStack`**: `MainTabView`'s `Tab` block + the `MoreTabScreen` overflow path each already provide one; a third nested stack silently breaks `.navigationDestination(item:)` sub-page pushes (Interface → Main Menu was unreachable through More until fixed).
- **RULE — `SettingsScreen.tvOSLayout` lifecycle gotchas** (SwiftUI re-presents on every `TabView` reorder): `.task { loadServerUsers() }` must guard re-fires with `@State serverUsersLoadAttempted` (else every menu edit re-hits `getUsers`/`getPublicUsers` + toasts; failure falls through silently). **Never** `.onAppear { proxy.scrollTo("settings.top") }` on the outer `ScrollViewReader` — fires on every re-presentation, yanks to top, drops focus to the tab pill. The `.onChange(of: selectedCategory/Sub)` handlers cover the legitimate scroll-to-top case.

- **RULE — tvOS focus**: each row is a single focusable unit (never individual sub-items). Accent/Language rows: left/right or select cycles (`onMoveCommand`).
- **Settings row SSOT** (`Settings/SettingsRowHelpers.swift` + platform extensions): every boolean toggle declared once as `SettingsToggleRow`, rendered both platforms from the same catalogues (`interfaceToggleRows`/`homePageToggleRows`/`detailPageToggleRows`/`debugToggleRows`). Adding/renaming a toggle = one-line edit. Expanders: `iOSToggleRowsJoined`, `tvToggleList` (`tint:` is iOS-only debug-orange), `tvActionRow`, `tvGlassToggle`.
- **Assets**: `AppLogo.imageset` — iOS `app_logo.png` (full); tvOS `app_logo_tv.png` (front parallax layer, transparent, no `clipShape`).
- **Quick user switch**: `UserSwitchSheet` — grid → password → re-auth via `apiClient.reconnect(url:accessToken:)` (keeps server URL). **RULE — user list has three fetch outcomes**: `getUsers()` is admin-only (401 for regular accounts); `getPublicUsers()` returns `[]` on hardened servers (welcome screen disabled — Jellyfin's secure default). When both yield nothing, fall through to an empty state with a "Connexion manuelle" CTA → `manualEntryStep` (same `authenticate(username:password:)` path); also surfaced as "Utiliser un autre compte" under a populated grid. Removing the manual path silently regresses the App Store reviewer scenario.
- **Refresh Catalogue (single trigger)**: Settings → Server `apiClient.clearCache()` + posts `.cinemaxShouldRefreshCatalogue` (Home + MediaLibrary observe). **No per-page refresh buttons** — Settings is SSOT.
- **Debug section** always visible (not `#if DEBUG`-gated) so QA doesn't need a custom build; icons orange.

### `@AppStorage` keys (`SettingsKey` / `SettingsKey.Default` — `Shared/DesignSystem/SettingsKeys.swift`)

| Key | Default | Effect |
|-----|---------|--------|
| `motionEffects` | `true` | `motionEffectsEnabled` env — disables animations when off |
| `render4K` | `true` | `maxBitrate` 120/20 Mbps |
| `autoPlayNextEpisode` | `true` | Auto-nav via `didPlayToEndTime` |
| `forceNativeAVPlayer` | `false` | `false` ⇒ VLC engine; `true` ⇒ native `AVPlayer` |
| `sleepTimerDefaultMinutes` | `0` | 0/15/30/45/60/90 via `SleepTimerOption` |
| `uiScale` | `1.0` | Font scale 80–130%; bumps `_accentRevision` |
| `darkMode` | `true` | **Via `themeManager.darkModeEnabled`**, not directly |
| `accentColor` | `"green"` | **Via `themeManager.accentColorKey`** |
| `home.showContinueWatching` | `true` | Continue Watching row |
| `home.showRecentlyAdded` | `true` | Recently Added row |
| `home.showGenreRows` | `true` | All 4 genre rows |
| `home.showWatchingNow` | `true` | Watching Now row (admin-only) |
| `detail.showQualityBadges` | `true` | Quality pill row on detail screen |
| `library.tvBrowseLayout` | `"browse"` | tvOS-only. `browse` = hero + genre rows; `grid` = flat grid (filters force grid) |
| `privacy.maxContentAge` | `0` | Rating ceiling (0=unrestricted; 10/12/14/16/18) via `applyContentRatingLimit` |
| `menu.mode` | `"default"` | `"default"` ⇒ canonical 5 tabs; `"custom"` ⇒ user-driven |
| `menu.customKind` | `"contentType"` | Custom source: `"contentType"` or `"library"` |
| `menu.contentTypeEntries` | — | JSON `[MenuEntry]` — order + enabled, content-type mode |
| `menu.libraryEntries` | — | JSON `[MenuEntry]` — order + enabled, library mode |
| `menu.cachedViews` | — | JSON `[LibraryView]` — last `getUserViews` snapshot (server-scoped) |
| `debug.fastSleepTimer` | `false` | Overrides sleep to 15s |
| `debug.showSkipToEnd` | `false` | "End" button seeking to `duration−15s` |
| `easterEgg.rainbowUnlocked` | `false` | Rainbow accent visibility — flipped by logo-tap egg |

## Offline Downloads (iOS / iPadOS only — product decision)

> **Full detail: [`docs/architecture/downloads.md`](docs/architecture/downloads.md).** URL negotiation, `DownloadManager`, storage layout, and offline UI live there.

Every download file `#if os(iOS)`; `SettingsCategory.downloads.isIOSOnly = true` filters it out on tvOS. `DownloadManager` (`@MainActor @Observable`) owns a background `URLSession` (`com.cinemax.downloads`); `DownloadStorage` writes `Application Support/Cinemax/Downloads/`.

- **RULE — Never use `?static=true` straight off** for download URLs (got MKV files AVPlayer can't decode); **never use `/Videos/{id}/stream.mp4` without a PlaySessionId** (Jellyfin can return audio-only mux). Negotiate via `buildDownloadRequest` (download-specific DeviceProfile, `protocol=.http` single MP4, NOT HLS).
- **RULE — File size on completion**: chunked responses have no `Content-Length` (`totalBytesExpectedToWrite = -1`); after move, `stat` the destination and overwrite BOTH `totalBytes` and `bytesReceived`. **Don't `bytesReceived = totalBytes`** (caused "Zéro ko" regression).
- **RULE — never call `DownloadStorage.totalDiskUsage()` from a SwiftUI `body`** (blocking recursive multi-GB disk walk) — use the cached `DownloadManager.totalDiskBytes`. **Progress writes go through `DownloadStore.updateProgress`** (≤1 disk write / 5s); status transitions persist immediately.
- **RULE — Fast-fail timeouts**: every `JellyfinClient` takes `Self.fastFailSessionConfiguration` (request 8s, resource 20s, `waitsForConnectivity=false`); raw PlaybackInfo POST adds `request.timeoutInterval = 8`. Enables non-blocking offline launch (`NetworkMonitor` seeds `isOnline` synchronously).
- **RULE — All offline image consumers check `downloads.localPosterURL`/`localBackdropURL` first** (Nuke disk cache keys per-URL — a poster cached at `maxWidth=180` is a different entry from `360`).
- **Playback dual path**: `VideoPlayerView.startIOSPlayback` checks `downloads.item(for:)` BEFORE `getPlaybackInfo`. AVKit-friendly (`isOfflinePlayable`) → AVPlayer; else (mkv/avi/webm…) → `VLCStreamPresenter` offline. `OfflineLibraryView` replaces tab content when offline; `MediaDetailScreen` short-circuits to `OfflineMediaDetailView`.

## Admin (iOS-only — product decision)

> **Full detail: [`docs/architecture/admin.md`](docs/architecture/admin.md).** Gating, scaffolds, Identify flow, Metadata Manager, and the ImageType quirk live there.

`SettingsCategory.visibleCases(isAdmin:isTVOS:)` short-circuits when `isTVOS`; every `Shared/Screens/Admin/` file `#if os(iOS)`. Gated on `AppState.isAdministrator` (server authoritative; client gating is UX). `AdminAPI` is the privilege slice (device listing/revocation stays on `AuthAPI`).

- **RULE — `AdminFormScreen` every admin editor uses explicit save (never auto-save)** — admin changes have blast radius (policy revocations, password resets); sticky footer + `interactiveDismissDisabled(isDirty)` + discard confirmation. `AdminItemMenu` **does NOT host its own `.navigationDestination`** (lazy-container rule), fires `onSelectDestination(_:)`. `DestructiveConfirmSheet` (type-to-confirm) for irreversible ops; reversible use `.confirmationDialog` `.destructive`.
- **RULE — Self-protection** (client-side; server enforces too): can't delete/demote/disable yourself; can't revoke current device (`KeychainService.getOrCreateDeviceID()` vs `DeviceInfoDto.id`, "THIS DEVICE" pill).
- **RULE — API key security** (`Admin/ApiKeys/`, keys = passwords): masked by default (first 4 + last 4); `.privacySensitive()`; per-row Copy is the only export path (no share sheet); `appState.accessToken` match → `CURRENT SESSION`, revoke hidden. **Never log key values or send to analytics.** `revokeApiKey` takes the token itself as identifier (Jellyfin quirk); forget value on return.

## MediaDetailScreen

`MediaDetailViewModel` auto-resolves Episode/Season → parent Series (by `seriesID`, loads seasons + episodes) + `getNextUp()`. `selectSeason()` uses a generation counter for stale results. Use `resolvedType` (not initial `itemType`) for layout. tvOS detail refresh: `VideoPlayerCoordinator.lastDismissedAt` (via `TVDismissDelegate`); `.onChange` reloads after dismiss (iOS reloads via `.task` on pop).

- **Resume / next-up** (`actionButtons` → `PlayActionButtonsSection: View, Equatable`): custom `nonisolated static func ==` compares resume + prev/next identity, ignores closure → `.equatable()` short-circuits re-renders. Same pattern on `MediaDetail{Cast,Similar}Section`/`Episode{Card,Row}` (wrap non-Sendable DTO reads in `MainActor.assumeIsolated` — escape hatch #4).
- Movie `playbackPositionTicks > 0` not `isPlayed`: progress bar + remaining + "Lecture" via `PlayLink(startTime:)`. Series: `nextUpEpisode`. **Play from beginning**: when `showResume`, secondary ghost `PlayLink` with `startTime: nil`. `userData.playbackPositionTicks`/`runTimeTicks` are `Int?`; `isPlayed` is `Bool?`.
- **Quality badges** (`MediaQualityBadges.swift`): gated on `detail.showQualityBadges`, from `item.mediaSources?.first`. Resolution by height, HDR (`VideoRangeType`), codec, audio (first-hit Atmos/TrueHD/DD+/DD/DTS/…), channels. `EmptyView()` when none.
- **Episode nav**: `episodeNavigation(for:)` O(1) from `episodeNavigationMap` (current season) or `nextUpNavigationMap` (cross-season next-up).
- **Episode metadata line** (`MediaDetailEpisodeMetadataLine`): shared tvOS/iOS, joined ` • ` — in-progress "Xm remaining" / else runtime / + `premiereDate`.

## HomeScreen

`HomeViewModel` loads `resumeItems` + `latestItems` in parallel (`TaskGroup`). `heroItem = resumeItems.first ?? latestItems.first`. Resume nav: per resume episode season's list fetched (grouped by `seasonID`), `precomputeEpisodeRefs` once/season, O(1) `buildEpisodeNavigation` → `resumeNavigation`. Genre rows: `getGenres`, shuffle, pick 4, parallel; **failures become `.failed`** (renders retry — transient errors don't silently hide content). Watching Now: `getActiveSessions(activeWithinSeconds:60)`, drop current user + require `nowPlayingItem`. **RULE — admin-only**: the row, its Settings toggle, and the `/Sessions` fetch are all gated on `appState.isAdministrator` — `/Sessions` is meant to be elevated and leaks every user's session to non-admins on some servers (jellyfin#5210). Configurable layout (`home.show*`, default true; hero never gated). **tvOS scroll-to-top**: `ScrollViewReader` + `.id("home.top")` attached *directly to `heroSection`* (fallback zero-height `Color.clear` only when no hero).

- **RULE — tvOS 26 tab bar pill alignment heuristic**: Liquid Glass reserves a constant 157pt `safeAreaInsets.top`, but the active pill sits at its **bottom** ("expanded") or **top** ("compact", ~30pt higher) depending on whether the first scrollable row touches the safe-area top edge. Any leading gap — including the implicit `LazyVStack` `spacing:` between a zero-height sentinel and the first visible row — flips it to compact (menu looks shifted up on that tab only). Fix: `LazyVStack(spacing: 0)` + explicit `.padding(.bottom, spacing6)` between rows + attach `.id(scrollTopID)` directly to the first visible row, not a sentinel (ref: `HomeScreen.content`). Films/Recherche/Réglages don't need it (first row already flush). Only the gap above the first scroll row matters — content padding, focusable proximity, `toolbarBackgroundVisibility`, modal modifiers have no effect.

## SearchScreen

`SearchViewModel.search(using:)` debounces 400ms → `searchItems(... limit:30)`. Decomposition: shell + file-private `VoiceSearchButton` (iOS), `SearchResultsGrid`, `SearchResultCard`. iOS mic → `SpeechRecognitionHelper`. **Surprise Me**: `fetchRandomMovie`/`fetchRandomSeries` are separate methods (Swift 6 flags `[BaseItemKind]` built from a parameter as non-Sendable crossing the API actor; literal arrays are fine).

## Localization

- `LocalizationManager` (`@Observable`, injected from `AppNavigation`). Default `fr`, also `en`. Reactivity: `@ObservationIgnored` + `@AppStorage` + `_revision`.
- **RULE — All strings via `loc.localized("key")` / `loc.localized("key", args...)` — never hardcoded.** Strings at `Resources/{lang}.lproj/Localizable.strings`. Use plural helpers (e.g. `remainingTime(minutes:)`), not inline branching.
- **RULE — never surface raw `error.localizedDescription` to users** (leaks cryptic SDK strings like `unacceptableStatusCode(401)`). Map via `LocalizationManager.userFacingMessage(for:)` (→ network / session-expired / generic); log the raw error. VMs that show errors take `loc:` and `logger`.

## Toasts & Empty states

- `ToastCenter` (`@Observable`, root-injected) — single-toast queue, auto-dismiss; `ToastOverlay` top glass pill. **Use for action feedback and recoverable errors. NOT for critical errors needing a decision — use `UIAlertController`.**
- `EmptyStateView` (icon + title + optional subtitle + action). Used by Home, filtered library grid ("Clear filters" resets `LibrarySortFilterState()`), `UserSwitchSheet`.

## Dynamic Type (iOS)

`.dynamicTypeSize(.xSmall ... .accessibility2)` at root (caps the accessibility sizes that break hero/tab-bar). `CinemaFont.dynamicBody/dynamicBodyLarge/dynamicLabel(_:)` use `UIFontMetrics`. **Apply dynamic variants only to reading-heavy surfaces** — hero/display/headline titles keep fixed fonts to protect layout.

## Image Patterns (all RULE)

- `ImageURLBuilder` → `/Items/{id}/Images/{type}`. **Backdrop sizing**: use `ImageURLBuilder.screenPixelWidth` — never hardcode `1920`.
- **RULE — always pass the `tag:` cache-buster to `imageURL(...)`/`imageURLRaw(...)`**: without it the URL is byte-identical across server-side poster/backdrop edits, so Nuke (keyed by URL) serves the stale image forever — invisible until reinstall, and `clearCache()`/"Refresh Catalogue" don't help (they clear the JSON cache, not Nuke's). Pass `item.primaryImageTagValue` (`.primary`), `item.backdropImageTagValue` (`.backdrop`; helpers in `BaseItemDto+Metadata.swift`), `person.primaryImageTag` (cast). Every new live image call site threads the tag. Deliberately omitted on download-prefetch/offline paths and `NowPlayingInfoController` (separate `URLSession` cache).
- **Image cache**: `AppNavigation.init()` sets `ImagePipeline.shared` 500 MB disk + explicit `ImageCache` `costLimit = 256 MB` (Nuke's ~100 MB default evicts mid-render on tvOS — 4K backdrops decode to 4–8 MB each).
- **Backdrop fallback**: `item.backdropItemID` (→ `parentBackdropItemID ?? seriesID ?? id`). **No-backdrop placeholder**: gate on `item.hasBackdropImage` (NOT `backdropItemID` — always non-nil) → `BackdropFallbackView`. Wired in `MediaDetailScreen.backdropSection`/`HomeScreen.heroSection`/`LibraryHeroSection`.
- **Always `CinemaLazyImage`** — never `LazyImage` directly. Card containers: `Color.clear` + `.aspectRatio()` + `.frame(maxWidth: .infinity)` + `.overlay { CinemaLazyImage }` + `.clipped()`. **Backdrop (full-bleed ZStack)**: `CinemaLazyImage` must have `.frame(maxWidth:.infinity, maxHeight:.infinity)` — else ZStack sizes from natural 1920px and pushes the title off-screen.
- **PosterCard title alignment**: hidden `Text("M\nM").hidden()` placeholder + title overlaid top-aligned → uniform row height.

## App Icons

- iOS: `Assets.xcassets/AppIcon.appiconset/` (1024² light/dark/tinted). tvOS: `App Icon & Top Shelf Image.brandassets/` (3-layer parallax + Top Shelf 1920×720 + Wide 2320×720). In-app logo: `AppLogo.imageset/`. Standalone source: `appIcon.png` at project root.

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

**Versioning**: `iOS/tvOS Info.plist` use `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)` — `project.yml` `settings.base` is SSOT. Bump `MARKETING_VERSION` per user-visible release; `CURRENT_PROJECT_VERSION` per archive/upload.

## Claude Code automations (`.claude/`)

Project-shared, checked into git. Per-developer overrides in `.claude/settings.local.json` (gitignored).

- **Hooks** (`.claude/settings.json`): `PreToolUse` blocks edits to `Cinemax.xcodeproj/project.pbxproj` (XcodeGen output — edit `project.yml`); `PostToolUse` auto-runs `xcodegen generate` after `project.yml` edits.
- **Skills**: `localize-check` (FR/EN key parity + hardcoded-string grep), `design-system-review` (`conventions.md` checklist grep on staged files).
- **Subagents**: `tvos-focus-reviewer`, `swift6-concurrency-reviewer`.
- **MCP servers** (`~/.claude.json` project scope): `context7` (live docs), `github`, `xcodebuildmcp` (`npx -y xcodebuildmcp@latest mcp` — note the `mcp` subcommand).
