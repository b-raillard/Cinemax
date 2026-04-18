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
| ~~Weak ATS configuration~~ | `project.yml`, both `Info.plist` | 38-40, 80-82 | **MITIGATED (2026-04-17, audit 1.5)** — ATS flags intentionally scoped: `NSAllowsArbitraryLoadsForMedia: true` (stream-only, required for self-hosted HTTP) + `NSAllowsLocalNetworking: true` (for `192.168.*.*` / Bonjour). No `NSAllowsArbitraryLoads: true` — API calls to arbitrary HTTP hosts are still blocked by ATS. `ServerSetupScreen` now shows an inline orange warning banner (`server.httpWarning.*`) when the typed URL starts with `http://`, explaining that credentials/tokens flow in plaintext and recommending HTTPS. Non-blocking — local self-hosters can still connect. |
| ~~No TLS certificate pinning~~ | Networking layer | — | **N/A BY DESIGN (2026-04-17, audit 1.5)** — Cinemax is a BYO-server client: users connect to their own Jellyfin instances on arbitrary domains (self-hosted, reverse-proxied, Cloudflare-tunneled, Tailscale, etc.). There is no known leaf certificate or issuer to pin against. Pinning against the system CA store adds no defense-in-depth and would break users with self-signed/Let's Encrypt rotation. Documented as design decision; revisit only if a hosted "Cinemax Cloud" tier is ever offered. |

### Medium

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| ~~Token in error messages~~ | `JellyfinAPIClient.swift` | 561-568 | **DONE (2026-04-17)** — user-facing `JellyfinError.playbackFailed` now only embeds the status code; raw response body is only printed behind `#if DEBUG`. |
| ~~Password stays in memory~~ | `LoginViewModel.swift` | 33 | **DONE (2026-04-17, audit 1.3)** — `authenticate` already sets `password = ""` right after Keychain persistence succeeds (before the 1 s success dwell). Verified no other caller retains the string. On auth failure the password is intentionally kept so the user can retry. |
| ~~No search input validation~~ | `SearchViewModel.swift` | 155-173 | **N/A (2026-04-17, audit 1.5)** — `searchTerm` is handed to `Paths.GetItemsParameters(searchTerm:)` from jellyfin-sdk-swift, which emits it as a strongly-typed query parameter. The SDK performs proper URL encoding; no string interpolation into the URL is done anywhere in `searchItems`. Search results are rendered via `Text(item.name ?? "")` (no HTML/markdown/WebView), so there's no XSS surface. No server-side injection risk — Jellyfin sanitizes search input. Additional escaping would be redundant. |

### Low

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| ~~HTTP localhost fallback~~ | `AppNavigation.swift` + `UserSwitchSheet.swift` + `ImageURLBuilder.swift` + `JellyfinAPIClient.swift` | — | **DONE (2026-04-17)** — single `AppState.placeholderServerURL` built from `URLComponents` (infallible). All `URL(string:)!` call sites in production code now reference it; `ImageURLBuilder` + `JellyfinAPIClient` `URLComponents`/`components.url!` force unwraps replaced with `guard` / `?? serverURL` fallbacks. Tests still use literal force unwraps (acceptable). |
| ~~`nonisolated(unsafe)`~~ | `JellyfinAPIClient.swift` | 16-21 | **MITIGATED + DOCUMENTED (2026-04-17, audit 1.5)** — added explicit invariant comment at the declaration: every read/write of `_jellyfinClient` / `_serverURL` goes through `getClient()` / `getServerURL()` / `setClient(_:url:)`, all of which acquire the `NSLock`. The static profile arrays (`_directPlayProfiles`, `_transcodingProfiles`, `_subtitleProfiles`) are `let` constants — immutable, inherently safe — the `nonisolated(unsafe)` marker is only required because the SDK's profile types aren't marked `Sendable`. Escape hatch is contained and correct; upgrading beyond this requires the SDK itself to conform. |
| ~~No API response validation~~ | Networking layer | — | **ACCEPTED TRADEOFF (2026-04-17, audit 1.5)** — `jellyfin-sdk-swift` handles HTTP/JSON decoding with typed parameters and codable models; invalid types are rejected at the SDK boundary. Additional app-side validation would duplicate the SDK's guarantees and add maintenance cost without a concrete threat model (the attacker is the user's own server). Revisit if Cinemax ever talks to third-party APIs. |

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
| ~~`.onAppear` pagination trigger~~ | `MovieLibraryScreen.swift` | 96-100, 202-206 | **DONE (2026-04-17, audit 1.3)** — Both `ForEach` call sites delegate to a new `maybeLoadMore(triggerId:)` helper that guards on `isLoadingMore` / `hasLoadedAll` *synchronously* before spawning a `Task`. Redundant `.onAppear` callbacks (view recycling, re-renders) no longer queue dead tasks behind `PaginatedLoader`'s actor guard. |

### Medium

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| ~~Sequential API calls in load~~ | `MediaDetailViewModel.swift` | 35-109 | **DONE (2026-04-17)** — `loadSeriesDetail` fans out `getSimilarItems` / `getSeasons` / `getNextUp` in parallel via `async let`. When the next-up episode lives in a different season, the current season's and next-up season's episode lists are also fetched concurrently. Shared between the Episode/Season → Series resolution path and the direct Series path. |
| ~~`ContentRow` `@ViewBuilder` creates all items~~ | `ContentRow.swift` | 41-53 | **DONE (2026-04-17, audit 1.4)** — `ContentRow` is now a data-driven generic (`Data: RandomAccessCollection, ItemID: Hashable, ItemView: View`). The internal `ForEach(data, id: id, content: itemView)` is guaranteed by the type signature, so callers can't accidentally pass a tuple that `LazyHStack` would build eagerly. All 7 existing call sites migrated; both iOS and tvOS schemes build clean. |
| Race condition on rapid season selection | `MediaDetailViewModel.swift` | 87-95 | `selectedSeasonId` set immediately, `episodes` populated async. Rapid tapping can show episodes from wrong season. Add a generation counter. |
| `VideoPlayerCoordinator` missing task cancellation | `VideoPlayerCoordinator.swift` | 44-69 | `play()` creates a new Task without cancelling the previous one. Double-tapping can start two concurrent playback sessions. |
| ~~Search state management~~ | `SearchViewModel.swift` | 191-221 | **DONE (2026-04-17)** — `defer { self?.isSearching = false }` placed right after `isSearching = true` so cancellation paths (guard returns mid-await, thrown `CancellationError`) always flip the flag back. Task now captures `[weak self]` for consistency. |
| ~~6+ ProgressViews in grids~~ | `PosterCard.swift`, `WideCard.swift` | 14, 15 | **DONE (2026-04-17, audit 1.4)** — `PosterCard` no longer passes `showLoadingIndicator: true`. Dense poster grids (Home genre rows, library, similar) rely on the fallback background during the brief load window instead of spinning 6+ `ProgressView`s simultaneously. `WideCard` (used for continue-watching / watching-now, where cards are larger and fewer per row) keeps its indicator. |

### Low

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| Adaptive sizing recomputed per access | `HomeScreen.swift` | 305-376 | `heroHeight`, `heroTitleSize` etc. are computed properties called multiple times per layout. Minimal impact but could be constants. |
| `Bindable(viewModel)` per evaluation | `SearchScreen.swift` | 38, 65 | Creates a new Binding each view evaluation. Minor overhead. |
| Localization lookup per render | All screens | — | `loc.localized(...)` called on every render. Acceptable but worth noting. |

### Memory Leak Risks

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| ~~SpeechRecognitionHelper callbacks~~ | `SearchViewModel.swift` | 138-161 | **DONE (2026-04-17)** — `hasBoundSpeechCallbacks` gate in `setupSpeechCallbacks` binds the `onTranscript` / `onStopped` / `onPermissionError` closures exactly once per view-model lifetime instead of rebuilding them on every `toggleListening`. Closures still capture `[weak self]`; `stop()` continues to cancel tasks + tear down audio so late-firing SFSpeech events can't hit a deallocated VM. |
| TVPlayerHostViewController observations | `TVPlayerHostViewController.swift` | 44-49 | No `deinit` to clean up `NSKeyValueObservation`/`NSObjectProtocol` observers. *(Dead code — delete priority.)* |
| ~~VideoPlayerCoordinator presenter lifecycle~~ | `VideoPlayerCoordinator.swift` | 28-87 | **DONE (2026-04-17, audit 1.3)** — `play()` now nils `presenter` eagerly before starting a new session and bumps a `currentGeneration` counter. The `onDismiss` closure and the post-fetch `self.presenter = p` assignment both compare `currentGeneration == generation`, so a late-firing `onDismiss` from an abandoned session can't nil out the fresh presenter and an abandoned presenter can't linger on the coordinator. |

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
| 5 | ~~Replace force unwraps with safe unwrapping in URL construction~~ | **DONE (2026-04-17)** — see audit 1.2 below. |

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

---

## 9. Audit 1.2 — Quick-win pass (2026-04-17)

### Completed this batch

| # | Action | Category | Effort | Notes |
|---|--------|----------|--------|-------|
| 1 | Sanitize PlaybackInfo error body | Security (Medium) | 5 min | `JellyfinError.playbackFailed` user-facing string is now just the HTTP status code; raw body is only `debugLog`-printed behind `#if DEBUG`. |
| 2 | Replace force unwraps on URL construction | Correctness / App Store | 30 min | `AppState.placeholderServerURL` constructed from `URLComponents` (infallible) replaces the 3 `URL(string: "http://localhost")!` sites in `AppNavigation.swift` + 1 in `UserSwitchSheet.swift`. `ImageURLBuilder` + `JellyfinAPIClient` `URLComponents!` / `components.url!` sites fall back to `serverURL` via `guard` / `??`. Tests untouched. |
| 3 | Parallelize `MediaDetailViewModel.load` | Performance (Medium) | 30 min | New private `loadSeriesDetail` fans out `getSimilarItems` / `getSeasons` / `getNextUp` with `async let`; episode lists for the current vs next-up season fetch in parallel when they differ. Shared between the Episode/Season → Series path and the direct Series path. |
| 4 | SpeechRecognitionHelper callback accumulation | Memory / Correctness | 15 min | `setupSpeechCallbacks` gated on `hasBoundSpeechCallbacks` so closures are bound once per VM lifetime; prevents rebuilding `[weak self]` closures every `toggleListening`. |
| 5 | Fix `isSearching` cancel race | Performance (Medium) | 15 min | `defer { self?.isSearching = false }` placed right after the flag flips true, so cancellation paths (guard returns, `CancellationError`) no longer leave the spinner stuck on. Task captures `[weak self]`. |

Build verification: iOS (`Cinemax` scheme, iPhone 17 Pro sim) and tvOS (`CinemaxTV` scheme, Apple TV 4K sim) both `** BUILD SUCCEEDED **`.

### Remaining after this batch

**Security**
- **High** — `NSAllowsArbitraryLoadsForMedia: true` in both Info.plists; auth tokens in transcoding URLs still flow in plaintext if server is HTTP
- **High** — No TLS certificate pinning (standard `URLSession`)
- **Medium** — `password: String = ""` in `LoginViewModel` not cleared after successful auth
- **Medium** — No defense-in-depth escaping on search input
- **Low** — `nonisolated(unsafe)` on `JellyfinClient` (mitigated by `NSLock`)
- **Low** — No post-decode validation on Jellyfin responses

**Performance**
- **High** — `.onAppear` pagination trigger in `MovieLibraryScreen` can double-fire
- **Medium** — `ContentRow` `@ViewBuilder` builds all items upfront despite `LazyHStack`
- **Medium** — `ProgressView` renders in every grid cell simultaneously
- **Medium** — `actionButtons()` in `MediaDetailScreen` recomputes on unrelated state changes

**Memory leaks**
- `VideoPlayerCoordinator` presenter leaks if `onDismiss` never fires (crash / hardware back)

**Refactoring** (from Top-10 #10 partial)
- `NativeVideoPresenter` (~1,300 lines) not yet split
- `MovieLibraryScreen` (~1,000 lines) not yet split
- Settings row duplication (~1,579 lines across 3 files)
- `APIClientProtocol` split into `ServerAPI` / `MediaAPI` / `PlaybackAPI` / `ReportingAPI`

**App Store submission (user-task)**
- Distribution signing, demo Jellyfin server, metadata + screenshots

---

## 10. Audit 1.3 — Second quick-win pass (2026-04-17)

### Completed this batch

| # | Action | Category | Effort | Notes |
|---|--------|----------|--------|-------|
| 1 | Clear password after login | Security (Medium) | audit bookkeeping | Verified `LoginViewModel.authenticate` already zeros `password` (line 33) right after Keychain persist — predates audit 1.3. On failure the string is intentionally kept for retry UX. Row in §1 updated to DONE. |
| 2 | Fix pagination double-fire | Performance (High) | 20 min | New `maybeLoadMore(triggerId:)` in `MovieLibraryScreen` short-circuits on `isLoadingMore` / `hasLoadedAll` *before* spawning the load task. Applied to both the tvOS and iOS filtered-grid `ForEach` sites. `PaginatedLoader`'s actor guard still there as a belt-and-braces. |
| 3 | Fix `VideoPlayerCoordinator` presenter leak | Memory | 30 min | Added `currentGeneration: UInt` counter. `play()` eagerly nils the old presenter and bumps the generation; `onDismiss` and the post-fetch `self.presenter = p` both guard on matching generation so a stale dismiss (late delegate callback, edge-case where `onDismiss` would have fired into the new session) can't nil the replacement. |

Build verification: iOS (`Cinemax` scheme, iPhone 17 Pro sim) and tvOS (`CinemaxTV` scheme, Apple TV 4K sim) both `** BUILD SUCCEEDED **`.

### Remaining after this batch

**Security**
- **High** — `NSAllowsArbitraryLoadsForMedia: true` in both Info.plists; auth tokens in transcoding URLs still flow in plaintext if server is HTTP
- **High** — No TLS certificate pinning (standard `URLSession`)
- **Medium** — No defense-in-depth escaping on search input
- **Low** — `nonisolated(unsafe)` on `JellyfinClient` (mitigated by `NSLock`)
- **Low** — No post-decode validation on Jellyfin responses

**Performance**
- **Medium** — `ContentRow` `@ViewBuilder` builds all items upfront despite `LazyHStack`
- **Medium** — `ProgressView` renders in every grid cell simultaneously
- **Medium** — `actionButtons()` in `MediaDetailScreen` recomputes on unrelated state changes

**Refactoring** (from Top-10 #10 partial)
- `NativeVideoPresenter` (~1,300 lines) not yet split
- `MovieLibraryScreen` (~1,000 lines) not yet split
- Settings row duplication (~1,579 lines across 3 files)
- `APIClientProtocol` split into `ServerAPI` / `MediaAPI` / `PlaybackAPI` / `ReportingAPI`

**App Store submission (user-task)**
- Distribution signing, demo Jellyfin server, metadata + screenshots

---

## 11. Audit 1.4 — Perf-wins pass (2026-04-17)

### Completed this batch

| # | Action | Category | Effort | Notes |
|---|--------|----------|--------|-------|
| 1 | Drop `ProgressView` from dense grid cards | Performance (Medium) | 5 min | `PosterCard` no longer passes `showLoadingIndicator: true` to `CinemaLazyImage`. Removes 6–20 simultaneous `ProgressView` spinners on Home genre rows, library grids, and similar-items rows. `WideCard` (continue-watching / watching-now — larger and fewer per row) keeps its spinner. |
| 2 | Make `ContentRow` structurally lazy | Performance (Medium) | 40 min | `ContentRow` is now `ContentRow<Data: RandomAccessCollection, ItemID: Hashable, ItemView: View>`. The internal `LazyHStack { ForEach(data, id: id, content: itemView) }` guarantees the `ForEach` — callers can no longer pass a tuple of N views that SwiftUI would build eagerly. All 7 call sites migrated (Home: genre row / watching-now / continue-watching / recently-added; MovieLibrary: genre row; MediaDetail: cast / similar). Every caller already used `ForEach` under the old API, so behavior is unchanged — this tightens the contract at the type level to prevent future regressions. |

Build verification: iOS (`Cinemax` scheme, iPhone 17 Pro sim) and tvOS (`CinemaxTV` scheme, Apple TV 4K sim) both `** BUILD SUCCEEDED **`.

### Remaining after this batch

**Security**
- **High** — `NSAllowsArbitraryLoadsForMedia: true` in both Info.plists; auth tokens in transcoding URLs still flow in plaintext if server is HTTP
- **High** — No TLS certificate pinning (standard `URLSession`)
- **Medium** — No defense-in-depth escaping on search input
- **Low** — `nonisolated(unsafe)` on `JellyfinClient` (mitigated by `NSLock`)
- **Low** — No post-decode validation on Jellyfin responses

**Performance**
- **Medium** — `actionButtons()` in `MediaDetailScreen` recomputes on unrelated state changes

**Refactoring** (from Top-10 #10 partial)
- `NativeVideoPresenter` (~1,300 lines) not yet split
- `MovieLibraryScreen` (~1,000 lines) not yet split
- Settings row duplication (~1,579 lines across 3 files)
- `APIClientProtocol` split into `ServerAPI` / `MediaAPI` / `PlaybackAPI` / `ReportingAPI`

**App Store submission (user-task)**
- Distribution signing, demo Jellyfin server, metadata + screenshots

---

## 12. Audit 1.5 — Security pass (2026-04-17)

### Completed this batch

| # | Action | Category | Effort | Notes |
|---|--------|----------|--------|-------|
| 1 | HTTP server warning banner | Security (High) | 20 min | `ServerSetupScreen` detects `http://`-prefixed input via a `isHTTPURL` helper and renders an inline orange-tinted banner above the Connect button (both tvOS/iPad and iPhone layouts). Explains in plain language that credentials and tokens flow in plaintext. Non-blocking — local self-hosters keep working. Localized `server.httpWarning.title` / `server.httpWarning.message` in fr + en. ATS kept as-is (`NSAllowsArbitraryLoadsForMedia` + `NSAllowsLocalNetworking`, no blanket `NSAllowsArbitraryLoads`) — the warning addresses user awareness without locking out the common home-lab deployment. |
| 2 | TLS cert pinning decision | Security (High) | docs | Resolved as N/A-by-design: Cinemax is BYO-server, so there is no known certificate chain to pin. Decision documented in §1 Security. |
| 3 | Search input escaping | Security (Medium) | docs | Verified SDK handles URL encoding via `Paths.GetItemsParameters(searchTerm:)`; response rendered as `Text`, no XSS surface. Resolved as N/A. |
| 4 | `nonisolated(unsafe)` invariant | Security (Low) | 5 min | Added explicit invariant comment at the declaration in `JellyfinAPIClient.swift` documenting that every read/write of `_jellyfinClient` / `_serverURL` MUST go through the lock-protected helpers. The escape-hatch is contained and correct. |
| 5 | API response validation | Security (Low) | docs | Accepted tradeoff: SDK-level codable decoding is the boundary; additional validation would duplicate SDK guarantees without a concrete threat model. Documented in §1 Security. |

Build verification: iOS (`Cinemax` scheme, iPhone 17 Pro sim) and tvOS (`CinemaxTV` scheme, Apple TV 4K sim) both `** BUILD SUCCEEDED **`.

### Remaining after this batch

**Security** — all items resolved. §1 is now either `DONE` or `N/A BY DESIGN` / `ACCEPTED TRADEOFF` with inline justification.

**Performance**
- **Medium** — `actionButtons()` in `MediaDetailScreen` recomputes on unrelated state changes

**Refactoring** (from Top-10 #10 partial)
- `NativeVideoPresenter` (~1,300 lines) not yet split
- `MovieLibraryScreen` (~1,000 lines) not yet split
- Settings row duplication (~1,579 lines across 3 files)
- `APIClientProtocol` split into `ServerAPI` / `MediaAPI` / `PlaybackAPI` / `ReportingAPI`

**App Store submission (user-task)**
- Distribution signing, demo Jellyfin server, metadata + screenshots

**Next**: user-requested full platform re-audit — performance, code quality, iOS 26/tvOS 26 best practices, security, UX/UI, other pertinent topics. Captured in §13 below.

---

## 13. Full platform re-audit (batch 2.0 — 2026-04-17)

### TL;DR

Cinemax is in **strong shape for App Store submission**. No critical blockers. Swift 6 strict concurrency, `@MainActor` isolation, responsive image sizing, comprehensive accessibility labels, sound tvOS focus strategy, and no token leaks or force-unwraps in production code. Remaining items are **code-quality debt** (large files, duplication) and **UX polish** (pagination spinner placement, test coverage). Nothing blocks a submission.

### Critical

*None.*

### High

| Category | File(s) | Lines | Finding | Suggested fix |
|----------|---------|-------|---------|---------------|
| Code Quality | `SettingsScreen.swift` + iOS/tvOS variants | ~1,659 total | Three-file duplication of settings rows; iOS and tvOS differ only in layout, not logic. Largest concrete LOC reduction available in the repo. | Extract a `SettingsRowModel` protocol + platform `SettingsRowView(iOS/tvOS)` wrappers. Expected: −300 to −400 LOC, single edit per new row. |
| Code Quality | `NativeVideoPresenter.swift` | 1,678 | Cohesive but spans playback init, HLS loader, sleep timer, end-of-series overlay, track selection, error recovery, skip segments. Cognitive load is high. | Extract companions: `SleepTimerController.swift`, `SkipSegmentController.swift`, `PlaybackReportingController.swift`. Keep the presenter at ~1,200 lines. Deferred from 1.4 due to regression risk — do when there's time to test playback thoroughly. |
| UX | `MovieLibraryScreen.swift` | ~89, ~190 | Initial-load `ProgressView()` on the filtered grid shows a centered spinner with no context — visually indistinguishable from an error pause. | Wrap the centered spinner with explanatory text ("Loading movies…") OR move it to a content-unavailable style empty state with a spinner. |

### Medium

| Category | File(s) | Lines | Finding | Suggested fix |
|----------|---------|-------|---------|---------------|
| Performance | `MediaDetailScreen.swift` | 255-377 (`actionButtons`) | Re-runs whenever anything on `viewModel` / `item` changes, even for unrelated state like `selectedSeasonId`. Cost is small but avoidable. | Extract a focused sub-view that only depends on `(item.id, nextEpisode?.id, showResume)`. Already flagged in §2. |
| Code Quality | `MovieLibraryScreen.swift` | 977 | Largest Shared screen file. Browse + filtered + genre rows + hero + filter-sheet wiring + pagination + grid layout all in one. | Extract `LibraryHeroSection`, `LibraryGenreRow`. Moderate effort, good readability win. |
| Code Quality | `SearchScreen.swift` | 420 | Search input, voice recognition wiring, result grids, empty state, surprise-me, tvOS scroll-to-top all in one file. | Extract `VoiceSearchButton`, `SearchResultsGrid`. Lower priority than MovieLibraryScreen. |
| UX | `MovieLibraryScreen.swift` | 189-195 | Pagination spinner renders centered in-grid instead of as a footer row below loaded items. Breaks visual continuity during scroll. | Move the pagination spinner to a footer `VStack` row under the grid. Keep centered spinner only for *initial* load. Low effort, real UX win. |
| Code Quality | `HomeViewModel.swift` | ~60-100 | Genre row fetches silently skip on failure — no error indication, no retry. | Make the helper return `(genre, items)` or `(genre, .failed)` and render a minimal retry chip in-row. Acceptable to defer — discover surface is non-critical. |
| A11y | Various `NavigationLink` sites | — | Item-type is sometimes inferred post-load rather than passed at push time; detail screen has to refetch/classify. | When pushing to `MediaDetailScreen`, always pass `itemType: item.type ?? .movie` at the call site. Most paths already do. |

### Low

| Category | File(s) | Lines | Finding | Suggested fix |
|----------|---------|-------|---------|---------------|
| Performance | `CinemaGlassTheme.swift` | 239 | Color tokens are computed properties returning `Color.dynamic`; accessed on every render. | Convert to `static let`. <1% perf gain; nice-to-have. |
| Performance | `HomeViewModel.swift` | 60-100 | `resumeNavigation` rebuild is O(n²) in resume-item count. Fine for 5-20 items; 100+ noticeable. | Batch by season in a `buildResumeNavigation` helper. Monitor; not urgent. |
| Code Quality | `NativeVideoPresenter.swift` | 40-41 | `manifestLoader` / `backgroundObserver` are retained with brief comments — could use one-liner explaining AVAssetResourceLoader's weak-reference behavior. | Done already; no action. |
| Localization | Time formatting | — | `home.remainingTime.*` uses hardcoded hours/minutes branching instead of plural rules. | Add plural-aware helper. Acceptable for fr/en first; defer until a third language arrives. |
| Testing | `Packages/CinemaxKit/` | ~500 LOC tests | No coverage for `MediaDetailViewModel.selectSeason` race, `SearchViewModel` cancellation, `JellyfinAPIClient` cache TTL. | Add 3-4 focused tests. ~2-3 hr effort. Worth doing pre-submission. |

### Positive findings

- Strict Swift 6 concurrency throughout — no unsafe patterns detected.
- Zero `try!` in production; URL construction uses `guard` or `??` fallbacks.
- Responsive image sizing via `ImageURLBuilder.screenPixelWidth` (no hardcoded 1920 anywhere).
- 30+ `accessibilityLabel` calls + `accessibilityHidden` on decorative views. VoiceOver coverage is good.
- tvOS focus strategy is sound: consistent `@FocusState`, `.focusEffectDisabled()` + `.hoverEffectDisabled()`, `tvSettingsFocusable(colorScheme:)` guards against the trait-collection flip.
- Navigation patterns clean — `NavigationStack` + `navigationDestination(item:)` on iOS, tvOS coordinator with proper `onDismiss`. No stale presenter bugs.
- Playback reporting is thorough — start / 10 s progress / stopped all wired. Resume state stays fresh.
- Dark/light mode reactivity routes through `_accentRevision` setter — no direct `@AppStorage` writes bypass reactivity.
- Previous O(n²) lookups, excessive `ProgressView`s, pagination double-fires all fixed and remain fixed.

### Suggested next batch (ordered by ROI)

| # | Action | Category | Effort | Impact |
|---|--------|----------|--------|--------|
| 1 | ~~Extract shared `SettingsToggleRow` + platform wrappers~~ | Code Quality | 4-6 hr | **DONE** (audit 2.3, 2026-04-17) — single source of truth for toggle rows |
| 2 | ~~Pagination spinner → footer row (centered only for initial)~~ | UX | 30-60 min | **DONE** (audit 2.1, 2026-04-17) |
| 3 | ~~Unit tests: `MediaDetailViewModel.selectSeason` race, `SearchViewModel` cancel, cache TTL~~ | Testing | 2-3 hr | **DONE** (audit 2.1, 2026-04-17) |
| 4 | ~~Extract `LibraryHeroSection` + `LibraryGenreRow` from `MovieLibraryScreen`~~ | Code Quality | 2-3 hr | **DONE** (audit 2.2, 2026-04-17) |
| 5 | Extract playback sub-controllers (sleep / skip / reporting) | Code Quality | 3-4 hr | Medium — deferred from 1.4 |
| 6 | ~~Filter grid: centered spinner → `ContentUnavailableView` with spinner~~ | UX | 30 min | **DONE** (audit 2.1, 2026-04-17) |
| 7 | Split `APIClientProtocol` by domain | Code Quality | 4-6 hr | Low-Medium — nice-to-have; defer |

---

## 14. Audit 2.1 — UX spinners + test coverage (2026-04-17)

### Completed this batch

| # | Action | Category | Effort | Notes |
|---|--------|----------|--------|-------|
| 1 | Filter grid: initial-load spinner gains explanatory label | UX (#6) | 20 min | `MovieLibraryScreen.filteredLoadingState` centers a spinner + localized "Loading movies…" / "Loading series…" label below. Replaces the bare `ProgressView()` that was visually indistinguishable from a hung fetch. Both tvOS (line 88) and iOS (line 189) sites now reference the helper. New keys `library.loading.movies` / `library.loading.series` in fr + en. |
| 2 | Filter grid: pagination spinner becomes a footer row | UX (#2) | 15 min | `filteredPaginationFooter` renders a low-profile centered spinner *below* the grid when `isLoadingMore` fires with existing items, preserving visual continuity during scroll. Keeps the full-card `filteredLoadingState` only for `items.isEmpty && isLoadingMore` (initial page). Applied to both tvOS and iOS. |
| 3 | Test coverage: `MediaDetailViewModel.selectSeason` race | Testing (#3) | 45 min | New `MediaDetailViewModelTests` suite with a race test — Season A handler sleeps 200 ms, Season B sleeps 20 ms; `selectSeason` invoked concurrently via `async let`. Asserts the generation counter discards the late-arriving Season A result and keeps Season B's episodes. Plus two scaffold tests (happy path, nil userId short-circuit). `MockAPIClient.getEpisodesHandler` added so tests can inject per-season delays. |
| 4 | Test coverage: `SearchViewModel` cancellation | Testing (#3) | 40 min | New `SearchViewModelTests` suite: empty-query no-op, success path, cancellation-does-not-stick (replaces in-flight query mid-await, verifies `isSearching` flips back to false via `defer`), API-failure path, `fetchRandomMovie` happy + error. `MockAPIClient.searchItemsHandler` added for injecting delays/errors. Cancellation test completes in ~1.4 s. |
| 5 | Test coverage: `APICache` TTL | Testing (#3) | 20 min | New `APICacheTests` suite (seven tests): pre-expiry hit, post-expiry miss (50 ms TTL + 120 ms sleep), type-mismatched read, `invalidate(prefix:)` scoping, `clear()`, overwrite-with-newer-TTL. Lives in the Xcode `CinemaxTests` target (not the SPM package tests) because SPM would need a macOS platform declaration; reaching `APICache` requires `@testable import CinemaxKit` which works fine from the app-linked test target. |

**Build & test verification**: iOS — `xcodebuild test -scheme Cinemax -only-testing:CinemaxTests` → `36 tests in 8 suites passed after 4.876 seconds` (`** TEST SUCCEEDED **`). tvOS — `xcodebuild build -scheme CinemaxTV` → `** BUILD SUCCEEDED **`.

### Remaining after this batch

**Refactoring** (from §13 suggested batch)
- `SettingsRowModel` extraction (~350 LOC reduction) — largest remaining code-quality win
- `LibraryHeroSection` / `LibraryGenreRow` extraction from `MovieLibraryScreen` (977 lines)
- `NativeVideoPresenter` sub-controller extraction (sleep / skip / reporting)
- `APIClientProtocol` domain split

**App Store submission (user-task)**
- Distribution signing, demo Jellyfin server, metadata + screenshots

---

## 15. Audit 2.2 — Library view decomposition (2026-04-17)

### Completed this batch

| # | Action | Category | Effort | Notes |
|---|--------|----------|--------|-------|
| 1 | Extract `LibraryPosterCard` | Code Quality (#4) | 20 min | `Shared/Screens/LibraryPosterCard.swift`. Self-contained `NavigationLink → MediaDetailScreen` with subtitle composition (year · seasons for series, year · rating for movies). Consumed by `LibraryGenreRow` and by both filtered grids (iOS + tvOS) in `MediaLibraryScreen`. `.onAppear { maybeLoadMore }` modifiers stay on the call site. |
| 2 | Extract `LibraryGenreRow` | Code Quality (#4) | 10 min | `Shared/Screens/LibraryGenreRow.swift`. Thin wrapper over `ContentRow` that embeds `LibraryPosterCard`. Caller owns the "See all" callback (set genre filter), keeping the row itself viewmodel-agnostic. |
| 3 | Extract `LibraryHeroSection` | Code Quality (#4) | 40 min | `Shared/Screens/LibraryHeroSection.swift`. Full-bleed backdrop + rating badge + metadata line + title + (tvOS overview) + Play / More info buttons. Owns all hero-specific adaptive sizing (11 private sizing vars). iOS-only in practice — tvOS library leads with the inline filter bar. |
| 4 | Slim `MediaLibraryScreen` | Code Quality (#4) | 30 min | Deleted `heroSection`, `heroActionButtons`, `heroMetadataText`, `genreRow`, `posterCard`, and 11 hero-only sizing helpers from `MovieLibraryScreen.swift`. File went from 1005 → 726 lines (−279, −28%). Remaining helpers (`gridPadding`, `gridSpacing`, `filterIconSize`, `filterLabelSize`, `genreCardHeight`, `browseGenresPadding`, `browseGenresColumns`) are still referenced by the surviving filter bar + browse-genres + filter-button code. |

**Build & test verification**: iOS build → `** BUILD SUCCEEDED **`; tvOS build → `** BUILD SUCCEEDED **`; `xcodebuild test -scheme Cinemax -only-testing:CinemaxTests` → `36 tests in 8 suites passed after 4.853 seconds` (`** TEST SUCCEEDED **`). Refactor is behavior-preserving — no visual, behavioral, or test changes.

### Remaining after this batch

**Refactoring** (from §13 suggested batch)
- `SettingsRowModel` extraction (~350 LOC reduction) — largest remaining code-quality win
- `NativeVideoPresenter` sub-controller extraction (sleep / skip / reporting)
- `APIClientProtocol` domain split

**App Store submission (user-task)**
- Distribution signing, demo Jellyfin server, metadata + screenshots

---

## 16. Audit 2.3 — Settings single source of truth (2026-04-17)

### Completed this batch

| # | Action | Category | Effort | Notes |
|---|--------|----------|--------|-------|
| 1 | `SettingsToggleRow` shared data model | Code Quality (#1) | 30 min | New `Identifiable` struct in `SettingsRowHelpers.swift` carrying `id`, `icon`, `label`, `value: Binding<Bool>`, optional `tint`. Platform-agnostic — lives outside `#if os(iOS)` so both renderers consume it. |
| 2 | `iOSToggleRowsJoined` renderer | Code Quality (#1) | 20 min | `@MainActor @ViewBuilder` helper that expands a `[SettingsToggleRow]` into `iOSToggleRow` + `iOSSettingsDivider` pairs. One call per section in `SettingsScreen+iOS.swift` replaces 10 toggle rows + 7 dividers. |
| 3 | `tvToggleList` renderer | Code Quality (#1) | 15 min | `@ViewBuilder` method on the tvOS extension that expands a `[SettingsToggleRow]` into `tvGlassToggle` rows. Four calls in `SettingsScreen+tvOS.swift` replace 10 inline toggles. Intentionally ignores `row.tint` — tvOS uses `themeManager.accent` uniformly (preserves pre-refactor visual; documented on the method). |
| 4 | Toggle row catalogues on `SettingsScreen` | Code Quality (#1) | 20 min | Four computed properties — `interfaceToggleRows`, `homePageToggleRows`, `detailPageToggleRows`, `debugToggleRows` — define every boolean toggle in the app in one place. Adding a new toggle is now a one-line `.init(...)` addition visible to both platforms. |
| 5 | `tvActionRow` consolidates 3 bespoke buttons | Code Quality (#1) | 25 min | New helper in `SettingsScreen+tvOS.swift` (two overloads: one for `.toggle(id)` focus, one for any `SettingsFocus` case). Replaces `tvRefreshCatalogueButton`, `tvRefreshConnectionButton`, `tvLicensesButton` — three near-duplicate Button blocks (~30 lines each) collapse to ~5-line call sites. Future action rows are one-liners. |
| 6 | iOS Licenses reuses `navigationRow` | Code Quality (#1) | 5 min | Replaced bespoke 17-line inline button with `navigationRow(icon:label:action:)` call. Identical layout (neutral icon + label + chevron), identical visual, ~13 fewer lines. |

### What "single source of truth" means here

The measurable outcome isn't line count — it's **where the facts about a settings row live**.

Before this batch, the definition of a toggle row (its id, icon, localization key, storage binding) was scattered:
- The `@AppStorage` key and its default in `SettingsScreen.swift`
- The row's icon + label + binding repeated verbatim in `SettingsScreen+iOS.swift`
- The same icon + label + binding (with a different focus id) repeated in `SettingsScreen+tvOS.swift`

Adding a toggle meant touching three files and keeping three string literals in sync. Renaming required a careful cross-file search. Accidental drift (wrong icon on one platform, slightly different label text, mis-matched focus id) was a real failure mode.

After: every toggle is declared once as a `SettingsToggleRow` entry on `SettingsScreen`. Both platform renderers consume the same list. The `@AppStorage` binding is threaded through `value:`. Adding or renaming a toggle is a single-file, single-line operation. The two renderers can only differ in *presentation*, never in *what rows exist*.

Same principle applies to `tvActionRow` — three action buttons (Refresh Catalogue, Refresh Connection, Licenses) that shared a visual pattern are now rendered by one helper. The pattern itself — icon + label + optional subtitle + optional chevron + `tvSettingsFocusable` framing — lives in one place.

### Build & test verification

- iOS build → `** BUILD SUCCEEDED **`
- tvOS build → `** BUILD SUCCEEDED **`
- `xcodebuild test -scheme Cinemax -only-testing:CinemaxTests` → `** TEST SUCCEEDED **` (36 tests across 8 suites)
- Refactor is behavior-preserving. No visual, behavioral, focus, or localization changes.

### Remaining after this batch

**Refactoring** (from §13 suggested batch)
- `NativeVideoPresenter` sub-controller extraction (sleep / skip / reporting)
- `APIClientProtocol` domain split

**App Store submission (user-task)**
- Distribution signing, demo Jellyfin server, metadata + screenshots

---

## 17. Audit §13 #5 — NativeVideoPresenter sub-controllers (2026-04-18)

### Goal

Break up the 1,678-line `NativeVideoPresenter.swift` — a single `@MainActor` class that mixed playback-reporting, skip-intro/credits UI, sleep timer, chapters, end-of-series overlay, error alerts, track menus, and episode navigation. Extract the three seams flagged in §13 (reporting / skip / sleep) while preserving behavior.

### Changes

New `Shared/Screens/VideoPlayer/` folder with three `@MainActor` sub-controllers:

| File | Lines | Owns |
|------|-------|------|
| `PlaybackReporter.swift` | 118 | `reportStart` / `reportStop` / `reportBackgroundProgress`, the 10-tick throttle for periodic progress reports, and the `onTick()` fan-out from the shared time observer |
| `SkipSegmentController.swift` | 205 | `load(for:)` fetch (with cancellation), time-based `onTick(currentTime:)` driving the skip button, and the platform-split UI (iOS floating `UIButton` / tvOS `contextualActions`) |
| `SleepTimerController.swift` | 440 | `startIfNeeded`, the 1 s countdown `Task`, the moon-pill indicator, the "Still watching?" prompt (tvOS `UIAlertController` / iOS custom blur card), and "Keep watching" vs "Stop playback" handling |

The presenter drops from **1,678 → 1,099 lines** (−579, ≈35%). Net file count +3; net LOC +184 (most of which is reintroduced `// MARK:` headers, controller docblocks, and sizing properties duplicated for `finishedSeriesOverlay`). LOC is not the win — responsibility separation is. The presenter's remaining job is narrow: AVPlayerViewController lifecycle, track menus, episode navigation, chapters, error alerts, end-of-series overlay, dismiss delegates.

### Seam design

- **Time observer stays on the presenter.** A single `addPeriodicTimeObserver` at 1 s fans out to `skipSegments.onTick(currentTime:)` and `playbackReporter.onTick()`. Keeping the observer where the player lifecycle is owned preserves the CLAUDE.md invariant ("A single periodic observer handles both segment detection and progress reporting") and avoids fragile `removeTimeObserver` ordering across sub-controllers.
- **`playerVCProvider: @MainActor () -> AVPlayerViewController?` closure.** Captures `[weak self] in self?.playerVC` at the presenter. The `playerVC` is replaced on episode navigation; a closure always returns the current one, whereas a stored reference would go stale. Same pattern for `PlaybackReporter.Context`, where `player: AVPlayer?` is looked up fresh per call.
- **`onStopPlayback` callback for `SleepTimerController`.** The "Stop playback" action in the Still Watching prompt dismisses the player. That's the presenter's concern; the controller calls back via `onStopPlayback: @MainActor () -> Void`.
- **Fetch cancellation added in `SkipSegmentController`.** The original `fetchSegments` was fire-and-forget. The controller now stores `fetchTask: Task<Void, Never>?` and cancels it in `teardown()`, so episode navigation can't race a stale segment list into the new episode.

### What stayed on the presenter

- **End-of-series overlay** — shares the overlay sizing properties (`overlayTitleSize`, etc.) with the sleep prompt. Those props were duplicated into `SleepTimerController` and restored on the presenter rather than extracting a fourth controller for a tiny pair of overlays.
- **Debug `showSkipToEnd` button** — iOS floating pill / tvOS contextual action for QA; lives with other debug tooling.
- **Shared button sizing** (`buttonFontSize`, `buttonCornerRadius`, `buttonPaddingH`) — used by the debug pill and could be reused by future affordances; kept on the presenter.
- **`PlayerHostingVC` (iOS)** and **`TVDismissDelegate` (tvOS)** — tightly coupled to how the presenter models dismissal.

### Preserved behavior

- **Reporting identity on episode nav**: the extraction preserves the presenter's existing behavior where `self.itemId` and `self.startTime` are `let` (never reassigned during episode nav). `playbackReporter.reportStart(startTime: self.startTime)` and `playbackReporter.reportStop()` pull `itemId` via the context closure, which reads `self.itemId` at call time. This is intentionally bug-for-bug with the original: on episode-to-episode autoplay, a pre-existing behavior causes the new episode to be reported under the initial episode's id + startTime. Flagged here as a follow-up rather than folded into the refactor to keep the commit review-able.
- No visual, focus-context, localization, or timing changes. The same HLSManifestLoader path, same tvOS `contextualActions` semantics, same tvOS `UIAlertController` vs iOS blur-card focus reasoning.

### Build & test

- `xcodebuild build` — iOS Simulator (iPhone 17 Pro): `** BUILD SUCCEEDED **`
- `xcodebuild build` — tvOS Simulator (Apple TV 4K 3rd gen): `** BUILD SUCCEEDED **`
- `xcodebuild test -only-testing:CinemaxTests`: 36 / 36 tests pass
- Manual smoke (to do on first real device session): (1) play movie, verify Jellyfin progress updates every 10 s, resume position survives dismiss; (2) play episode with intro segments, confirm button appears/disappears on segment entry/exit and re-appears on rewind; (3) enable `debug.fastSleepTimer`, confirm moon pill countdown, "Still watching?" prompt, Keep watching restarts, Stop playback dismisses the player.

### Remaining after this batch

**Refactoring** (from §13 suggested batch)
- `APIClientProtocol` domain split (deferred — mostly organizational)

**Known follow-ups surfaced during this refactor**
- Episode-nav `reportPlaybackStart` uses `self.itemId` / `self.startTime` (both `let`), so the new episode is reported under the old identity. Small, isolated fix: update `itemId` / `startTime` on episode navigation (or have the reporter take them per-call from the playbackInfo).

**App Store submission (user-task)**
- Distribution signing, demo Jellyfin server, metadata + screenshots
