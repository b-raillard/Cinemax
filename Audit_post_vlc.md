# Cinemax Code Audit — post VLC migration (2026-05-19)

Audit performed after the SwiftVLC (libVLC 4.0) engine migration. Five parallel
specialist passes: security, performance, dead-code/redundancy, Swift 6
concurrency, iOS 26 / tvOS 26 best practices.

## Baseline health

| Check | Result |
|---|---|
| iOS build (`Cinemax`, iPhone 17 Pro sim) | `** BUILD SUCCEEDED **` |
| tvOS build (`CinemaxTV`, Apple TV 4K) | `** BUILD SUCCEEDED **` |
| Test suite (`CinemaxKitTests`) | 40 tests / 9 suites — all pass |
| 165 source files / ~29K LOC | 0 TODO/FIXME · 0 stray `print()` · 0 unsafe force-unwrap |

**Overall verdict: the codebase is in genuinely good shape.** No critical/high
security issues, no deprecated-API or legacy-concurrency debt, excellent hygiene.
The items below are refinement, not rescue.

---

## Findings by severity

### HIGH

**H1. Data race: `MediaLibraryViewModel.fetchGenreItems` reads mutable `@MainActor var sortFilter` inside a `@Sendable` TaskGroup closure**
`Shared/ViewModels/MediaLibraryViewModel.swift:125-126`. Verified: the
`group.addTask` closure reads `self.sortFilter` directly; the sibling
`loadMoreFiltered:156` already snapshots (`let currentSortFilter = sortFilter`)
before the group. `sortFilter` mutates on the main actor from sort/filter UI
while detached tasks read it → torn read of a non-atomic struct. `@unchecked
Sendable` on `GenreResult` masks only the return type, not this capture.
Fix (S): snapshot `sortFilter`, `itemType`, `genreItemLimit` into locals before
`withThrowingTaskGroup`.

**H2. Perf hot path: synchronous recursive disk walk inside SwiftUI `body`, re-run every download progress tick**
`Shared/Screens/Downloads/DownloadsScreen.swift:101` → `DownloadManager.totalDiskBytes`
→ `DownloadStorage.totalDiskUsage()` (blocking `FileManager.enumerator` over the
multi-GB `files/` + `art/` trees on `@MainActor`). `DownloadManager.didWrite`
mutates the `@Observable items` array on every URLSession progress callback
(sub-second), invalidating the view → disk re-walked several times/sec while
downloading.
Fix (M): cache the byte total as a stored `@Observable` property; recompute
off-main (`Task.detached`) only on `didFinish`/`remove`/`removeAll`/`enqueue`.

**H2b. `DownloadStore.persist` does a full pretty-printed JSON encode + atomic write on every progress tick**
`Packages/CinemaxKit/.../DownloadStore.swift:79-88` via `DownloadManager.didWrite`.
Per-tick write amplification.
Fix (S): persist only on status transitions; throttle/coalesce progress saves
(~5s); drop `.prettyPrinted` on disk.

### MEDIUM

**M1. Dead setting: `forceSubtitles` is fully inert.** Verified: declared in
`SettingsKeys.swift`, `VideoPlayerCoordinator.swift:16` (private, never read), and
shown as a toggle in `SettingsScreen.swift:120/194` — but
`appliesMediaSelectionCriteriaAutomatically` / `.legible` (its documented effect)
appear zero times in the codebase. The toggle does nothing.
Fix (S): delete the key + toggle + `settings.forceSubtitles` localization
strings (recommended), or wire it into the engines.

**M2. VLC presenter duplication.** `VLCStreamPresenter.swift` (1792 LOC) and
`VLCOfflinePresenter.swift` (467 LOC) independently reimplement the same SwiftVLC
plumbing: the `for await event in player.events` dispatch, byte-identical
end-of-media disambiguation (`!isTearingDown && timeIntervalSince(lastPlayStart)
> 1.0`), `formatMs`, and the `PiPVideoView`-hosting surface. ~150–200 lines
mergeable.
Fix (M): extract a shared engine host (event loop + end-of-media guard +
formatter + hosting surface). Keep divergent logic separate.

**M3. Oversized player files.** `VLCStreamPresenter` 1792, `NativeVideoPresenter`
952, `MediaDetailScreen` 855. `NativeVideoPresenter` already demonstrates the
controller-decomposition pattern; `VLCStreamPresenter` doesn't.
Fix (L): extract HUD (glyph/skip/center-flash) and sleep/progress timer into
`@MainActor` controllers. Do after M2.

**M4. No file-level data protection on the offline downloads subtree.**
`DownloadStorage.swift:116-127` sets only `isExcludedFromBackup`. Media,
`index.json` (metadata + viewing history), and resume blobs are forensically
readable on a locked lost/stolen device. No credentials there (token in Keychain).
Fix (S): set `.fileProtectionKey = .completeUntilFirstUserAuthentication`; verify
background-download completion still writes while locked.

**M5. Localization gaps.** Hardcoded English in `SearchViewModel.swift:36,69`
(mic/speech errors); raw un-localized `error.localizedDescription` shown to users
in `MediaDetailViewModel:65`, `MediaLibraryViewModel:107`, `LoginViewModel:46`,
`ServerSetupViewModel:43`, `VideoPlayerView:166`.
Fix (M): route through `loc.localized(...)`; map errors to user-meaningful
localized messages; keep raw text for the logger.

**M6. `.font(.system(size:))` used across ~60 files** — bypasses the `CinemaFont`
typography SSOT (documented rejection-checklist item). Many wrap
`CinemaScale.pt(...)` so they still scale, but it is a systemic inconsistency.
Fix (L): token sweep, prioritizing non-`CinemaScale` raw sizes.

### LOW / polish

- **L1.** `KeychainService.swift:102` — `SecItemAdd` `OSStatus` ignored; on
  keychain-locked first launch a new device UUID is minted each call (device-list
  churn). Check status + in-memory session fallback.
- **L2.** Window-root resolution inconsistent: `NativeVideoPresenter:156,848` uses
  `windows.first`; `VLCStreamPresenter:119` uses `.first(where: \.isKeyWindow)`
  (correct for iPad Stage Manager). Align NVP.
- **L3.** `SearchViewModel` uses `DispatchQueue.main.async` for `SFSpeechRecognizer`
  callback hops (lines 28,33,93,99) — replace with `MainActor.run`.
- **L4.** `HomeViewModel:50,54` — resume+latest (hero source) fail silently via
  `try?` with no telemetry; add `logger.warning`.
- **L5.** `DownloadManager.Adapter.owner` (`:528`) write-once-then-read invariant
  correct but undocumented; add a one-line comment.
- **L6.** `VLCStreamPresenter.refreshTimeUISoon` (`:1644`) enqueues two
  `asyncAfter` repaints per call from ~7 sites; coalesce via one cancellable
  `DispatchWorkItem`.

### Stale docs (CLAUDE.md)
- `forceSubtitles` row in the `@AppStorage` table is fiction (see M1).
- `AdminComingSoonScreen` listed under `Admin/Components/` but the file does not
  exist (already deleted upstream).

---

## Cleanup plan (phased)

- **Phase 1 — Correctness:** H1, H2, H2b, M4, L1.
- **Phase 2 — Dead weight & docs:** M1, CLAUDE.md stale-doc fixes, L5.
- **Phase 3 — Localization & error UX:** M5, L3, L4.
- **Phase 4 — Player decomposition:** M2, then M3, L2, L6. Highest risk; manual
  device testing required (sim has no HW HEVC/DV/PiP).
- **Phase 5 — Typography sweep:** M6 (`.font(.system(size:))` → `CinemaFont`).

Each phase build-verified (iOS + tvOS) + tests; separate commits.
