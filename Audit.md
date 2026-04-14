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

| # | Action | Category | Effort |
|---|--------|----------|--------|
| 1 | Guard playback URL log with `#if DEBUG` | Security | 5 min |
| 2 | Delete 6 dead custom player files | Dead code | 5 min |
| 3 | Clear password after login | Security | 5 min |
| 4 | Precompute episode navigation map in ViewModel | Performance | 1 hr |
| 5 | Configure NukeUI cache limits | Performance | 30 min |
| 6 | Use responsive image sizing (GeometryReader) | Performance | 2 hr |
| 7 | Fix season selection race condition | Performance | 30 min |
| 8 | Cancel previous task in `VideoPlayerCoordinator.play()` | Performance | 15 min |
| 9 | Remove 33 unused localization keys | Dead code | 15 min |
| 10 | Extract large files into focused components | Refactoring | 4-6 hr |
