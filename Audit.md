# Cinemax Code Audit

**Date**: 2026-04-14
**Scope**: Full codebase — security, performance, dead code, refactoring opportunities

---

## 1. Security

### Critical

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| Auth token in release logs | `VideoPlayerView.swift` | 797 | `logger.info("iOS play: ... url=\(info.url.absoluteString)")` — transcoding URLs embed auth tokens. Not guarded by `#if DEBUG`, logs in production. OS logs are accessible via diagnostics/analytics. |

**Fix**: Wrap in `#if DEBUG` or redact the URL.

### High

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| Weak ATS configuration | `project.yml`, both `Info.plist` | 38-40, 80-82 | `NSAllowsArbitraryLoadsForMedia: true` allows HTTP for media streams. Auth tokens in transcoding URLs can be captured in plaintext. |
| No TLS certificate pinning | Networking layer | — | Standard URLSession with system CA store only. Vulnerable to MITM if device CA is compromised or corporate proxy intercepts. |

### Medium

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| Token in error messages | `JellyfinAPIClient.swift` | 553 | Error body logged unsanitized: `"PlaybackInfo returned \(statusCode): \(bodyStr.prefix(200))"`. May expose sensitive data in error strings shown to users. |
| Password stays in memory | `LoginViewModel.swift` | 8, 25 | `password: String = ""` — not cleared after successful authentication. Vulnerable to memory dumps. |
| No search input validation | `SearchViewModel.swift` | 155-173 | Search terms passed to API with only whitespace trimming. No defense-in-depth escaping. |

### Low

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| HTTP localhost fallback | `AppNavigation.swift` | 9, 27, 29 | `URL(string: "http://localhost")!` used as fallback when no server is configured. |
| `nonisolated(unsafe)` | `JellyfinAPIClient.swift` | 27-28 | Suppresses Swift 6 concurrency warnings. Mitigated by `NSLock`, but ideally `JellyfinClient` would be `Sendable`. |
| No API response validation | Networking layer | — | Decoded Jellyfin responses used without additional range/safety checks. Malicious server could return crafted data. |

### Positive Findings

- Keychain uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- Auth tokens passed via `Authorization` header (not URL) for direct streams
- Device ID properly stored in Keychain with migration from UserDefaults
- Compiled with `SWIFT_STRICT_CONCURRENCY: complete`
- `APICache` uses `NSLock` for thread safety
- Server URL validation enforces `http`/`https` scheme; defaults to HTTPS on user input

---

## 2. Performance

### High

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| O(n^2) episode navigation in view body | `MediaDetailScreen.swift` | 177-188, 246, 393, 478 | `episodeNavigation(for:)` does `O(n)` array search per episode, called inside `ForEach` loops. For a 20-episode season this is 400+ lookups per render. Should precompute a `[String: EpisodeNav]` map in the ViewModel. |
| Expensive `actionButtons()` recomputation | `MediaDetailScreen.swift` | 192-283 | Recalculates episode navigation on every re-render, even when only unrelated state changes. |
| No Nuke/NukeUI cache configuration | `CinemaLazyImage.swift` | 11-41 | No explicit cache size limits, no memory pressure handling. Can grow unbounded when browsing large libraries, risking OOM on tvOS. |
| Image size mismatch | `HomeScreen.swift` + others | 64, 279 | Always requests `maxWidth: 1920` for backdrops even on iPhone SE (390px viewport). Wastes bandwidth and memory. Use `GeometryReader` or environment-based sizing. |
| `.onAppear` pagination trigger | `MovieLibraryScreen.swift` | 89-92, 181-184 | Every card checks `item.id == items.last?.id` on appear. Can fire multiple times on re-render, triggering duplicate loads. Consider `ScrollViewReader` or threshold-based approach. |

### Medium

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| Sequential API calls in load | `MediaDetailViewModel.swift` | 35-79 | Series item fetch, seasons, episodes, nextUp, nextUp episodes are sequential. Several could be parallelized with `async let`. |
| `ContentRow` `@ViewBuilder` creates all items | `ContentRow.swift` | 41-53 | `LazyHStack` defers rendering but not view creation. A row with 20 items builds all 20 view hierarchies upfront. |
| Race condition on rapid season selection | `MediaDetailViewModel.swift` | 87-95 | `selectedSeasonId` set immediately, `episodes` populated async. Rapid tapping can show episodes from wrong season. Add a generation counter. |
| `VideoPlayerCoordinator` missing task cancellation | `VideoPlayerCoordinator.swift` | 44-69 | `play()` creates a new Task without cancelling the previous one. Double-tapping can start two concurrent playback sessions. |
| Search state management | `SearchViewModel.swift` | 155-184 | Cancelling the search task can leave `isSearching = true` if cancelled between set and reset. |
| 6+ ProgressViews in grids | `PosterCard.swift`, `WideCard.swift` | 14, 15 | Loading indicators render in every grid cell simultaneously. Disable for dense grids, keep for hero/featured items. |

### Low

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| Adaptive sizing recomputed per access | `HomeScreen.swift` | 305-376 | `heroHeight`, `heroTitleSize` etc. are computed properties called multiple times per layout. Minimal impact but could be constants. |
| `Bindable(viewModel)` per evaluation | `SearchScreen.swift` | 38, 65 | Creates a new Binding each view evaluation. Minor overhead. |
| Localization lookup per render | All screens | — | `loc.localized(...)` called on every render. Acceptable but worth noting. |

### Memory Leak Risks

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| SpeechRecognitionHelper callbacks | `SearchViewModel.swift` | 139-150 | `setupSpeechCallbacks()` called on each listen toggle. Old callbacks never cleared. Helper outlives ViewModel. |
| TVPlayerHostViewController observations | `TVPlayerHostViewController.swift` | 44-49 | No `deinit` to clean up `NSKeyValueObservation`/`NSObjectProtocol` observers. *(Dead code — delete priority.)* |
| VideoPlayerCoordinator presenter lifecycle | `VideoPlayerCoordinator.swift` | 28, 52-65 | If `onDismiss` never fires (crash, hardware back), old `NativeVideoPresenter` leaks. |

---

## 3. Dead Code

### Legacy Custom tvOS Player — 1,027 lines (delete)

These files are completely unreachable. `VideoPlayerCoordinator` creates `NativeVideoPresenter`, not `TVVideoPresenter`. Verified by grep: no references outside these files and CLAUDE.md.

| File | Lines |
|------|-------|
| `Shared/Screens/TVPlayerHostViewController.swift` | 586 |
| `Shared/Screens/TVControlsOverlay.swift` | 241 |
| `Shared/Screens/TVTrackMenus.swift` | 99 |
| `Shared/Screens/TVPlayerScrubber.swift` | 46 |
| `Shared/Screens/TVPlayerState.swift` | 42 |
| `Shared/Screens/TVCustomPlayerView.swift` | 6 |

### Unused Localization Keys — 33 keys

Present in both `fr.lproj` and `en.lproj` but never referenced in Swift code:

```
accessibility.removeGenreFilter    detail.moreInfo
accessibility.trackOptions         detail.runtime.hours
action.connect                     login.authFailed
action.login                       login.emptyUsername
movies.count                       movies.playNow
player.method                      player.notAuthenticated
player.playbackFailed              server.connectFailed
server.connecting                  server.emptyAddress
server.invalidURL                  settings.admin
settings.darkMode                  settings.systemInformation
settings.title                     sort.random
tab.movies                         tab.search
tab.settings                       tab.tvShows
tvShows.count                      tvShows.genre
tvShows.myList                     tvShows.season
tvShows.seasons                    tvShows.seasonsPlural
tvShows.title
```

### No other dead code found

- No unused imports
- No commented-out code blocks
- No TODO/FIXME/HACK comments
- No unused types or protocols (outside the custom player files)

---

## 4. Refactoring Opportunities

### Large Files

| File | Lines | Suggestion |
|------|-------|------------|
| `MovieLibraryScreen.swift` | 1,111 | Extract `LibraryFilterSheet`, `GenreRow`, `SortOption`, `FlowLayout` into separate files |
| `VideoPlayerView.swift` | 836 | Extract `HLSManifestLoader` and `NativeVideoPresenter` into their own files |
| `MediaDetailScreen.swift` | 829 | Extract season tabs and episode row views |
| `SettingsScreen+tvOS.swift` | 737 | Extract shared settings row components with iOS variant |
| `SettingsScreen+iOS.swift` | 644 | Same — shared rows total ~1,579 lines across 3 files |
| `JellyfinAPIClient.swift` | 767 | Split into domain-specific extensions (Server, Auth, Media, Playback, Reporting) |

### Settings Code Duplication

`SettingsScreen.swift` (198 lines) + `SettingsScreen+iOS.swift` (644) + `SettingsScreen+tvOS.swift` (737) = **1,579 lines**. Many settings rows (dark mode toggle, language picker, 4K, motion effects, subtitle toggle) share identical logic with only layout differences. Extract shared `SettingsRowModel` components and keep only platform-specific layout wrappers.

### API Client

`APIClientProtocol` has 40+ method signatures. Consider grouping into sub-protocols (`ServerAPI`, `MediaAPI`, `PlaybackAPI`, `ReportingAPI`) for better testability and separation of concerns.

---

## 5. Summary

| Category | Critical | High | Medium | Low |
|----------|----------|------|--------|-----|
| Security | 1 | 2 | 3 | 3 |
| Performance | 5 | 6 | 3 | — |
| Memory leaks | — | 1 | 2 | — |
| Dead code | 1,027 lines + 33 localization keys | | | |

### Top 10 Actions by Impact

| # | Action | Category | Effort | Status |
|---|--------|----------|--------|--------|
| 1 | Guard playback URL log with `#if DEBUG` | Security | 5 min | **DONE** (audit 1.1) |
| 2 | Delete 6 dead custom player files | Dead code | 5 min | **DONE** (audit 1.1) |
| 3 | Clear password after login | Security | 5 min | **DONE** (audit 1.1) |
| 4 | Precompute episode navigation map in ViewModel | Performance | 1 hr | **DONE** (audit 1.1) |
| 5 | Configure NukeUI cache limits | Performance | 30 min | **DONE** (audit 1.1) |
| 6 | Use responsive image sizing (GeometryReader) | Performance | 2 hr | **DONE** (audit 1.1) |
| 7 | Fix season selection race condition | Performance | 30 min | **DONE** (audit 1.1) |
| 8 | Cancel previous task in `VideoPlayerCoordinator.play()` | Performance | 15 min | **DONE** (audit 1.1.1) |
| 9 | Remove 33 unused localization keys | Dead code | 15 min | **DONE** (audit 1.1) |
| 10 | Extract large files into focused components | Refactoring | 4-6 hr | **PARTIAL** (2026-04-17) — conservative first pass: `JellyfinError` + `MediaTrackInfo` lifted to their own files; `IOSAppearanceDetailView` moved from `SettingsScreen+iOS.swift` (now 489 lines) into `SettingsAppearanceView+iOS.swift`. `NativeVideoPresenter` (~1,300 lines) and `MovieLibraryScreen` (~1,000 lines) not yet split — deferred since a robust extraction needs promoting many `private` members to `internal` and introducing delegate protocols; higher regression risk than this first-pass warranted |
| 11 | Skip Intro / Credits overlay (Intro Skipper plugin) | Feature | 2 hr | **DONE** — needs testing with Intro Skipper plugin |

---

## 6. App Store Readiness (audit 1.1.1 — 2026-04-14)

### Completed

| # | Action | Status |
|---|--------|--------|
| 1 | Create `PrivacyInfo.xcprivacy` for both targets | **DONE** — `Resources/PrivacyInfo.xcprivacy` declares UserDefaults API usage, no tracking |
| 2 | Add OSS license attribution | **DONE** — `LicensesView.swift` accessible from Settings > Server on both iOS and tvOS |
| 3 | Guard auth token log with `#if DEBUG` | **DONE** (already fixed in audit 1.1) |
| 4 | Delete dead tvOS player files | **DONE** (already fixed in audit 1.1) |
| 5 | Clear password after login | **DONE** (already fixed in audit 1.1) |
| 6 | Remove unused localization keys | **DONE** (already fixed in audit 1.1) |

| 7 | Accessibility pass — decorative images hidden, cards labeled | **DONE** |
| 8 | Handle `scenePhase` — report playback progress on background | **DONE** |
| 9 | Fix tvOS deployment target mismatch (Package.swift → tvOS v26, swift-tools-version 6.2) | **DONE** |

### Remaining for App Store Submission

| # | Action | Priority |
|---|--------|----------|
| 1 | Respect iOS Dynamic Type settings | Medium — **DONE** (2026-04-17) — `.dynamicTypeSize(.xSmall...accessibility2)` cap at `AppNavigation` root; new `CinemaFont.dynamicBody / dynamicBodyLarge / dynamicLabel(_:)` variants use `UIFontMetrics` so final size = `baseSize × appScale × dynamicTypeMultiplier`; applied to reading-heavy surfaces (MediaDetail overview, episode-card overviews, iOS toggle row labels). Hero/display fonts stay fixed to protect layouts |
| 2 | Configure App Store distribution signing | Required |
| 3 | Prepare demo Jellyfin server for App Review | Required |
| 4 | App Store metadata + screenshots | Required |
| 5 | Replace force unwraps with safe unwrapping in URL construction | Low |

See `APP_STORE_AUDIT.md` for full audit and future roadmap.

---

## 7. Feature & UX Improvements (2026-04-16)

### UX Friction & Polish

| # | Feature | Description | Effort | Status |
|---|---------|-------------|--------|--------|
| 1 | Empty states everywhere | Library with no results, Home with no resume items, series with 0 episodes — show illustration + message instead of silent empty sections | 2 hr | **DONE** (2026-04-17) — `EmptyStateView` component (icon + title + subtitle + optional action); filtered library shows "No matches" with Clear filters action; Home shows "Library is empty" with Refresh |
| 2 | Toast / snackbar feedback | Visual confirmation on actions (playback started, error, episode navigated). Silent failures confuse users | 3 hr | **DONE** (2026-04-17) — `ToastCenter` + `ToastOverlay` with success/error/info levels; wired to "Surprise Me" failure; injected at `AppNavigation` root |
| 3 | Pull-to-refresh (iOS) / refresh button (tvOS) | No way to refresh content without killing the app. New items added to Jellyfin don't appear until relaunch | 1 hr | **DONE** (2026-04-16) |
| 4 | "You finished the series" end screen | When last episode ends and auto-play has nowhere to go, show a completion screen instead of just stopping | 1 hr | **DONE** (2026-04-17) — `showFinishedSeriesOverlay` blur card with green checkmark + series name; `currentSeriesName` captured during chapter fetch; triggered by `itemEndObserver` when autoplay is on and no next episode exists |
| 5 | Remaining time on episode rows | Episode cards show runtime but not "12 min left" for partially-watched episodes — the thin progress bar isn't enough context | 30 min | **DONE** (2026-04-17) |

### Discovery & Browsing

| # | Feature | Description | Effort | Status |
|---|---------|-------------|--------|--------|
| 6 | Genre-based Home rows | Home only has 2 rows (resume + recently added). Add dynamic rows like "Action Movies", "Recent Comedies" using `getItems(genreIds:sortBy:limit:)` | 3 hr | **DONE** (2026-04-16) |
| 7 | "Surprise me" / Random pick | One tap → play something random. Jellyfin supports `sortBy: Random, limit: 1`. Solves decision paralysis on large libraries | 1 hr | **DONE** (2026-04-17) |
| 8 | Alphabetical jump bar (iOS library) | Scrolling through 500+ movies with no way to jump to a letter is painful. Side index like Contacts.app | 2 hr | **DONE** (2026-04-17) — `AlphabeticalJumpBar` (iOS-only, Contacts-style capsule index with drag-slide + haptics); only rendered when sort = name ascending and >20 items loaded; uses `ScrollViewReader` to jump to first matching id |
| 9 | Filter by unwatched only | Most common practical filter — "show me what I haven't seen." Simple toggle next to existing sort/genre controls | 1 hr | **DONE** (2026-04-16) |
| 10 | Year / decade filter in library | Genre is the only filter axis. "Show me 80s movies" is a real use case for movie collectors | 1 hr | **DONE** (2026-04-17) — decade chips (1950s–2020s) in iOS sort/filter sheet and tvOS inline filter bar; `LibrarySortFilterState.selectedDecades` expanded to `years` parameter on `getItems` |

### Playback Quality of Life

| # | Feature | Description | Effort | Status |
|---|---------|-------------|--------|--------|
| 11 | "Resume at X:XX" vs "Play from beginning" | Currently only resume is offered. Sometimes users want to restart. Offer both options | 1 hr | **DONE** (2026-04-16) |
| 12 | Sleep timer | 30/60/90 min timer that pauses playback. Essential for watching in bed | 2 hr | **DONE** (2026-04-17) — `SleepTimerOption` enum (Off/15/30/45/60/90); Settings > Interface row (iOS Menu, tvOS confirmationDialog) backed by `@AppStorage("sleepTimerDefaultMinutes")`; `NativeVideoPresenter` shows a moon-icon blur pill bottom-left counting down `mm:ss`; on fire, pauses + shows centered card "Still watching?" with "Keep watching" (restarts timer) / "Stop playback" (dismisses player); timer restarts on episode navigation |
| 13 | Chapter support in scrubber | Jellyfin exposes chapter markers with thumbnails. Display them in the player scrubber for context when seeking | 3 hr | **DONE — tvOS only** (2026-04-17) — `ImageURLBuilder.chapterImageURL`, parallel image fetch via `URLSession` with auth header, `AVNavigationMarkersGroup` applied to `AVPlayerItem.navigationMarkerGroups`. iOS `AVPlayerViewController` has no native chapter UI so this is a tvOS feature (iOS would need a custom scrubber) |
| 14 | Playback error recovery with guidance | Transcoding failures are silent or cryptic. Show actionable messages like "This file couldn't be played — try enabling transcoding in server settings" | 2 hr | **DONE** (2026-04-17) — `showPlaybackErrorAlert` presents a native `UIAlertController` when all retries are exhausted; error codes mapped to targeted messages (`-12881` transcode, `-12938/-1009/etc.` network, fallback generic); Close button dismisses player |

### Information Density

| # | Feature | Description | Effort | Status |
|---|---------|-------------|--------|--------|
| 15 | Video/audio codec badges on detail screen | "4K HDR · Dolby Atmos · HEVC" badges from `MediaSources[0].MediaStreams`. Self-hosted users care deeply about media quality | 2 hr | **DONE** (2026-04-16) — `MediaQualityBadges` view |
| 16 | Studio / Network label | Jellyfin provides studio info — showing "A24" or "HBO" adds browsable context | 1 hr | **DONE** (2026-04-17) — `studioLine` on `MediaDetailScreen` below overview (shows up to 2 studio names; label reads "Network" for series, "Studio" for movies) |
| 17 | External ratings (audience + critics) | Jellyfin stores `CommunityRating` and `CriticRating`. Showing both helps users decide what to watch | 1 hr | **DONE** (2026-04-17) — `ratingsRow` on backdrop shows yellow-star community rating + Rotten-Tomatoes-style critic rating (green ≥60, red otherwise) |
| 18 | Episode air dates on episode cards | Helps users know if they've missed episodes of an ongoing series | 30 min | **DONE** (2026-04-17) |

### Multi-User & Social

| # | Feature | Description | Effort | Status |
|---|---------|-------------|--------|--------|
| 19 | "Currently watching" indicator | Show when another server user is watching something (Jellyfin Sessions API). Makes the app feel alive | 2 hr | **DONE** (2026-04-17) — new `getActiveSessions` protocol method; `HomeViewModel.activeSessions` filters out the current user + idle sessions; "Watching Now" row on Home with a red LIVE pill overlay on each card; toggleable in Settings > Home Page |
| 20 | Quick user switch | Families share a TV. Tap avatar → pick user → PIN → done, without full server re-entry | 3 hr | **DONE** (2026-04-17) — new `UserSwitchSheet` (grid of user avatars → password prompt → re-auth keeping serverURL); wired into Settings > Account row on both iOS and tvOS; success emits a toast and closes the sheet; errors keep the sheet open for retry |

### Prioritized Top 10

| # | Feature | Category | Effort | Impact | Status |
|---|---------|----------|--------|--------|--------|
| 1 | Genre-based Home rows | Discovery | 3 hr | **High** — transforms Home from bare to rich | **DONE** (2026-04-16) — user-configurable via Settings > Interface > Home Page |
| 2 | Pull-to-refresh / refresh | UX Polish | 1 hr | **High** — basic hygiene, absence is immediately noticeable | **DONE** (2026-04-16) |
| 3 | "Resume" vs "Play from beginning" | Playback | 1 hr | **High** — daily friction for every partially-watched item | **DONE** (2026-04-16) |
| 4 | Filter by unwatched | Discovery | 1 hr | **High** — most useful filter for repeat library visits | **DONE** (2026-04-16) |
| 5 | Codec / quality badges | Information | 2 hr | **High** — differentiator for self-hosted audience | **DONE** (2026-04-16) — toggleable via Settings > Interface > Detail Page |
| 6 | Empty states everywhere | UX Polish | 2 hr | **Medium** — builds trust, removes confusion | **DONE** (2026-04-17) |
| 7 | "Surprise me" random pick | Discovery | 1 hr | **Medium** — fun, solves decision paralysis | **DONE → relocated** (2026-04-17) — initially on Home, then moved to **SearchScreen** empty state. Two distinct pills (`Surprise movie` / `Surprise series`) feel more natural where users go when they don't know what to watch. Pushes `MediaDetailScreen` via `navigationDestination(item:)` |
| 8 | Remaining time on episode rows | UX Polish | 30 min | **Medium** — quick win, better resume context | **DONE** (2026-04-17) — partial episodes show "Xm remaining" via shared `episodeMetadataLine` helper on both platforms |
| 9 | Chapter support in scrubber | Playback | 3 hr | **Medium** — valuable for long movies | **DONE — tvOS** (2026-04-17) |
| 10 | Episode air dates | Information | 30 min | **Medium** — quick win for ongoing series | **DONE** (2026-04-17) — `premiereDate` rendered in the shared `episodeMetadataLine` helper, combined with runtime/remaining on one line |

---

## 8. UX Refinements & Debug Tooling (2026-04-17)

### Refresh & Surprise relocation

| # | Change | Description |
|---|--------|-------------|
| 1 | Surprise-me moved from Home → Search | Two pills (Surprise movie / Surprise series) in `SearchScreen`'s "search your library" empty state. Removed iOS toolbar dice + tvOS pill from Home. Search is where users go when they don't know what to watch — better discovery context. |
| 2 | Refresh buttons removed | Removed the tvOS Refresh pill from Home and from the `MediaLibraryScreen` filter bar. iOS pull-to-refresh remains. |
| 3 | "Refresh Catalogue" added to Settings → Server | Single user-driven catalogue refresh. Calls `apiClient.clearCache()` and posts `.cinemaxShouldRefreshCatalogue`; Home and Library `.onReceive` reload. Toast confirms. New `clearCache()` on `APIClientProtocol`. |

### Debug tooling

| # | Feature | Description |
|---|---------|-------------|
| 1 | Debug section in Settings → Interface | Two `@AppStorage`-backed toggles (`debug.fastSleepTimer`, `debug.showSkipToEnd`); always visible (not gated by `#if DEBUG`) so QA / power users can reach them without a special build. Orange icon to signal "developer territory". |
| 2 | Fast sleep timer (15 s override) | New `SleepTimerOption.currentDefaultSeconds` returns 15 seconds when `debug.fastSleepTimer` is on; `NativeVideoPresenter.startSleepTimerIfNeeded` uses this helper instead of reading the option directly. Lets you preview the "Still watching?" prompt after only 15 s of playback. |
| 3 | Skip-to-end button in player HUD | When `debug.showSkipToEnd` is on, `NativeVideoPresenter` paints a small purple `⏭ End` chip top-right of the player. Seeks to `(duration − 15 s)` so you can verify the end-of-series completion overlay without watching a full episode. Hidden by default. |
