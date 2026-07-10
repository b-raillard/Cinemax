# Reliability & failure handling

Audit what happens when the network is slow/offline, the server returns garbage or nil, or an operation fails halfway. The bar: no infinite spinners, no silent failures, no half-written state, no crash on a nil the server was "supposed" to send.

## 1. Error handling — no swallowing, no silent failure

- **Swallowed errors**: `try?` that discards a failure the user needed to know about, `catch {}` empty blocks, `catch { }` that neither logs nor surfaces. Distinguish deliberate best-effort (prefetch, analytics) from a user-blocking op that failed silently.
  ```bash
  grep -rn --include='*.swift' 'try?\|catch\s*{\s*}\|catch\s*{\s*$' Shared Packages | grep -viE '//|prefetch|best.effort'
  ```
- **User-facing errors go through `LocalizationManager.userFacingMessage(for:)`** (RULE) — raw errors are logged, not shown. (Also a security item — cross-ref `security.md §1`.)
- **Genre rows fail loudly** (RULE — `HomeViewModel` genre fetch failures become `.failed` state with retry, never silently hidden). Verify no other "load a row, hide it if it fails" anti-pattern crept in elsewhere (it hides real outages from the user).

## 2. State coverage — loading / empty / error / offline / partial

For every async-loaded screen, confirm all five states render something intentional:

- **Loading** — `LoadingStateView` or a spinner, not a blank frame.
- **Empty** — `EmptyStateView` (icon + title + optional action), not "0 results" ambiguity. Filtered library empty → "Clear filters" reset.
- **Error** — `ErrorStateView` with **retry**, not a dead end.
- **Offline** — `OfflineLibraryView` swap when `!network.isOnline`; `MediaDetailScreen` → `OfflineMediaDetailView` short-circuit. Verify every tab that swaps offline actually does (Home/Search/MovieLibrary documented).
- **Partial success** — Dashboard `async let` fan-out renders partial on single-section failure (RULE). Verify a TaskGroup that loses one child doesn't fail the whole screen.
  ```bash
  grep -rn --include='*.swift' 'LoadingStateView\|EmptyStateView\|ErrorStateView\|isLoading\|OfflineLibraryView' Shared/Screens | head -40
  ```
- **Infinite-loading trap**: any `isLoading = true` set before an `await` — is there a path (thrown error, early return, cancellation) where it's never reset to `false`? Verify `defer { isLoading = false }` or equivalent on every exit.

## 3. Nullability, ordering & timing assumptions

The Jellyfin server response is the untrusted input for reliability too — DTOs are heavily optional.

- `userData.playbackPositionTicks` / `runTimeTicks` / `isPlayed` are `Int?`/`Bool?` (documented). Verify no force-unwrap and sensible defaults. Resolving Series/Season → Episode is mandatory before playback (Series/Season have no media sources — RULE); verify the guard.
- **Ordering**: don't assume server returns items sorted; `fetchRanked` ranks locally, but other lists that assume order? Flag `.first` used as "the right one" where the server doesn't guarantee order.
- **Empty collections**: `.first` / subscript on a possibly-empty server array (episodes, mediaSources, seasons). Crash surface.
  ```bash
  grep -rn --include='*.swift' 'mediaSources\?\?\.first\|\.first!\|episodes\.first\|\.first\.' Shared | head -30
  ```

## 4. Retry, rollback & timeouts

- **Bounded timeouts** (RULE): `fastFailSessionConfiguration` (request 30s / resource 60s / `waitsForConnectivity=false`); raw PlaybackInfo POST adds `timeoutInterval = 20`. Verify no unbounded request can hang a screen forever, and that these weren't tightened back to the old 8s values that tore whole screens down on a slow server.
- **Retry loops must terminate**: proxy `reconnectsLeft` + `progressRenewBytes` budget (a trickle-then-RST stream must give up, not loop forever); quick-connect poll; segment/manifest retries. Flag any `while true` / recursive retry without a bound.
  ```bash
  grep -rn --include='*.swift' 'while true\|retry\|reconnect\|timeoutInterval\|waitsForConnectivity' Shared Packages | head -40
  ```
- **Rollback / half-written state**: a download that fails mid-write — is the partial file cleaned up or does it show as playable? `DownloadManager.didFinish` container detection, file-size `stat` fixup (RULE — don't reintroduce the "Zéro ko" bug). `index.json` atomic write. A failed enqueue must not leave an orphan entry (`reconcileOrphans` on init wipes files whose itemId isn't in catalog — verify it runs).

## 5. Performance that materially hurts UX

Not micro-optimization — only user-visible cost.

- **`DownloadStorage.totalDiskUsage()` must NEVER be called from a SwiftUI `body`** (RULE — blocking multi-GB disk walk; use cached `totalDiskBytes`). Flag any call site inside a `body`/computed view property.
  ```bash
  grep -rn --include='*.swift' 'totalDiskUsage\|totalDiskBytes' Shared
  ```
- **Progress writes throttled** to `DownloadStore.updateProgress` (≤1 write/5s) — verify no per-tick full-catalog re-encode (the old write-amplification bug).
- **Unnecessary re-renders**: `@Observable` mutated in a hot loop (per-frame playback tick) driving a `body` that does heavy work. The `PlayActionButtonsSection: View, Equatable` `.equatable()` short-circuit is the pattern — verify hot sections use it.
- **Image decode**: `ImageCache costLimit = 256 MB` (Nuke default evicts 4K backdrops mid-render on tvOS — RULE). Verify it's still configured at `AppNavigation.init`.

## Severity guidance

- **High**: infinite loading state a user can't escape; a crash on a nil/empty server response in a common flow; half-written download shown as playable; unbounded retry stalling the app.
- **Medium**: missing error-retry or offline state on a real screen; a silently-hidden failed row; a screen torn down to "Serveur injoignable" on a transient stall.
- **Low/Info**: missing empty state on a rarely-empty list; best-effort path with no user impact.
