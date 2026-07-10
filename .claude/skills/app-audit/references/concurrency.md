# Concurrency, race conditions & state integrity

This is a Swift 6 strict-concurrency app; race conditions here are **real bugs, not theory**. Delegate Sendable / `@MainActor` isolation / actor-crossing-closure correctness to the `swift6-concurrency-reviewer` subagent (it reads CLAUDE.md's documented escape hatches as ground truth — don't re-flag those). This file covers the *behavioral* races that survive a type-checked build.

## 1. Duplicate submissions / non-idempotent actions

Trace every button that fires a network mutation or a stateful side effect and ask: *what happens on a double-tap, a retry, or a re-render mid-flight?*

- **Login / Quick Connect**: `LoginViewModel.completeSession`, `startQuickConnect` poll loop. Can a second tap start a second auth? Is the poll loop cancelled on success/dismiss so it can't complete a session after the sheet closed?
- **Download enqueue**: `DownloadManager.enqueue` — does enqueuing the same item twice create two tasks / two files? Is there an in-flight/queued guard keyed by item id?
- **Seek coalescing** (documented RULE): every ±N skip entry point must accumulate into `pendingScrubTargetMs` and commit ONE debounced `engineSeek`, never a per-press `player.seek(by:)`. A regression here is a request storm that stalls self-hosted servers. Verify every skip path (iOS buttons, double-tap, tvOS clickpad, chapter chips) routes through `accumulateSeek` → `commitPendingSeek`.
- **Any CTA that stays tappable while its operation runs** — the UI must disable/replace the control, not just ignore the second call downstream. Grep for buttons whose action is `async` with no `isLoading`/disabled guard on the control itself.
  ```bash
  grep -rn --include='*.swift' 'Button' Shared/Screens | grep -iE 'login|download|submit|save|delete|confirm|refresh' 
  ```

## 2. Out-of-order async responses & stale writes

The canonical bug: a slow response for request A lands after request B and overwrites B's state.

- **Generation-counter guards** are the documented pattern. Verify they're present and re-checked *before every write-back*, not just at entry:
  - `NowPlayingInfoController` bumps `generation` on `attach`/`detach`; the `getItem` enrich + artwork fetch re-check it (RULE — a slow poster must not overwrite the next episode's metadata).
  - `MediaDetailViewModel.selectSeason()` uses a generation counter for stale season results.
  ```bash
  grep -rn --include='*.swift' 'generation' Shared/Screens Shared/ViewModels
  ```
- **Debounced search** (`SearchViewModel.search`, 400ms) — verify a superseded query's results can't overwrite a newer query's (task cancellation or token check).
- **Playback re-resolve** (`reResolveAndResume`, `reReSolve...`) — a background→foreground re-resolve that lands after the user dismissed/swapped episodes must not seek/resume the wrong stream. Cross-check `cancelPendingSeekCommit` fires on episode swap, media reload, teardown (RULE).

## 3. Effects, tasks, timers, observers — cleanup

Every long-lived resource must be torn down on the matching lifecycle event. A leaked timer/task/observer is both a memory leak and a source of writes-after-teardown.

- **`.task {}` / `Task {}`**: does the `.task` cancel on view disappearance (structured) or is it a detached `Task {}` that outlives the view? Detached tasks writing back to `@Observable` state after teardown are the danger.
- **Timers**: `SleepTimerController`, `silenceTimer` (voice search), the single `addPeriodicTimeObserver` (RULE — sub-controllers must NOT add their own; verify none did). Each must invalidate on stop/dismiss. `stop()` idempotency (voice search guards on `audioEngine.isRunning || recognitionRequest != nil`) — verify.
- **AsyncStream consumers**: `VLCStreamPresenter` consumes SwiftVLC `events` in one `@MainActor` Task — verify it's cancelled on teardown so a post-dismiss `PlayerEvent` can't mutate a dead HUD.
- **`NotificationCenter` / `NWPathMonitor` / background-session observers**: matched add/remove; `NetworkMonitor` cancels its monitor.
  ```bash
  grep -rn --include='*.swift' 'addObserver\|removeObserver\|Timer\|invalidate\|Task.detached\|\.cancel()\|onDisappear\|deinit' Shared/Screens/VideoPlayer Shared/ViewModels | head -60
  ```
- **`@Observable` + `didSet`/`willSet` is BANNED** (RULE — intermittently drops SwiftUI re-renders on collection-of-Codable props). Mutations go through explicit `set*()` mutators. Flag any property observer on an `@Observable` stored property.
  ```bash
  grep -rn --include='*.swift' 'didSet\|willSet' Shared | grep -v '//'
  ```

## 4. Cache & multi-surface state consistency

- **Nuke cache-buster tags** (RULE): every live image URL must thread `tag:` (`primaryImageTagValue` / `backdropImageTagValue` / `person.primaryImageTag`) or a server-side poster edit is invisible forever. Prefetched URLs must be *byte-identical* (same `maxWidth` AND `tag`) to the consuming card. Flag `imageURL(`/`imageURLRaw(` calls on live paths missing `tag:`.
  ```bash
  grep -rn --include='*.swift' 'imageURL(\|imageURLRaw(' Shared | grep -v 'tag:' | grep -viE 'prefetch|offline|NowPlaying|download'
  ```
- **Client vs server vs persisted state**: `apiClient.clearCache()` + `.cinemaxShouldRefreshCatalogue` is the single refresh SSOT — verify Home + MediaLibrary both observe it and that `clearCache` doesn't leave stale `@Observable` view state that the notification doesn't refresh.
- **Multi-device / multi-session**: the token is device-scoped; a revoke-from-another-device (401) must flow through the confirm-before-logout re-validation (RULE — never log out on a single 401). Verify `handlePossibleSessionExpiry` is the only logout path from a 401 and it's debounced (`sessionRevalidationInFlight`) + gated on `NetworkMonitor.isOnline`.
- **Menu config 5-tab cap** (RULE — hard cap, UIKit `UIMoreNavigationController` teardown): verify the cap is enforced on the *mutation* (`ToggleResult.refusedCapReached`), not just rendered, so a concurrent edit can't cross 5→6.

## 5. `@MainActor` / lock discipline (delegate, then spot-check)

- `JellyfinClient` is wrapped with `NSLock` + `nonisolated(unsafe)` for Sendable. Spot-check that every access goes through the lock (delegate the thorough pass to `jellyfin-api-reviewer`).
- The background `URLSession` delegate for downloads (`Adapter: NSObject, @unchecked Sendable`) and the proxy's **concurrent** delegate queue (RULE — a serial queue head-of-line-blocks MKV seek requests → `cannot seek`). Verify the proxy's queue is still concurrent with `maxConcurrentOperationCount = 8`.

## Severity guidance

- **High**: a race that corrupts persisted state (double download, wrong metadata stuck on widget, token logged out spuriously), or a request storm that stalls the server.
- **Medium**: leaked timer/task/observer writing after teardown; missing cache-buster tag (stale content until reinstall); missing in-flight guard on a mutating CTA.
- **Low**: theoretical ordering issues on read-only paths with no user-visible effect.
