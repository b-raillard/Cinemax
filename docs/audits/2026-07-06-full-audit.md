# Cinemax — Full Codebase Audit (2026-07-06)

Scope: security, performance, bugs/correctness, code duplication, best practices — plus UX feature and UI recommendations. ~193 Swift files / ~37k lines audited (Shared, Packages/CinemaxKit, iOS, tvOS, Widgets, TopShelf, CI config). CLAUDE.md was used as ground truth: documented deliberate decisions are not re-flagged; deviations from documented contracts are.

**Overall verdict:** the codebase is in good shape — perfect FR/EN localization parity (725/725 keys), zero `print()` in production code, only 2 TODOs, 135 existing tests, and the hardest subsystems (seek coalescing, stream-proxy backpressure, session-expiry debounce, lock discipline) match their documented designs exactly. The audit found **3 high-severity correctness issues** (all in the API/URL layer and app-root lifecycle), a handful of medium security/bug items, and ~700–800 lines of removable duplication.

---

## 1. Priority 0 — fix first (High severity)

### 1.1 Sub-path–hosted Jellyfin servers break on all non-SDK URLs
- **Where:** `Packages/CinemaxKit/.../JellyfinAPIClient+Playback.swift:194, 358` · `JellyfinAPIClient+Downloads.swift:86, 104` · `ImageURLBuilder.swift:37, 83, 107, 118`
- **What:** every URL built via `components.path = "/Videos/…"` **replaces** the server URL's path instead of appending to it. A server configured as `https://host/jellyfin` (very common reverse-proxy layout, accepted by `ServerSetupViewModel`) silently loses `/jellyfin` → 404 on direct-stream playback, downloads, and **every image**. SDK-routed calls and the transcoding path (string concat) work, so the app appears half-broken.
- **Fix:** prepend the base path: `components.path = serverURL.path == "/" ? newPath : serverURL.path + newPath` (mirror the `baseURL + transcodingPath` concat already used at `+Playback.swift:162`). One shared helper on `ImageURLBuilder`/client to avoid re-fixing it 8 times.

### 1.2 401 on the raw PlaybackInfo POST is swallowed — session-expiry flow never fires from playback
- **Where:** `JellyfinAPIClient+Playback.swift:85–92` (and `+Downloads.swift:63` never calls `notifyIfUnauthorized`)
- **What:** `rawPostPlaybackInfo` deliberately throws structured `JellyfinError.unauthorized` on 401 — but the only streaming caller catches **all** errors and returns a direct-stream fallback URL. A revoked token therefore never reaches `notifyIfUnauthorized`; the user gets an opaque player error instead of the documented silent re-validate/logout flow.
- **Fix:** in the catch: `if Self.isUnauthorized(error) { notifyIfUnauthorized(error); throw error }` before falling back. Same instrumentation on `buildDownloadRequest`.

### 1.3 Root `@State` stores rebuilt on `AppNavigation` re-init — including a duplicate background `URLSession`
- **Where:** `Shared/Navigation/AppNavigation.swift:285–294` · `Shared/ViewModels/DownloadManager.swift:53–76`
- **What:** the code documents that SwiftUI may recreate the root struct on scene events (that's why the image pipeline is a guarded `static let`), but every recreation still evaluates all `@State` initializers and discards the results: new `JellyfinAPIClient`, 3 JSON decodes, a started-then-cancelled `NWPathMonitor`, and — the dangerous one — a full `DownloadManager()` init: synchronous main-thread read+decode of `index.json`, `reconcileOrphans` directory walk, **and a second background `URLSession` with the same identifier `com.cinemax.downloads`**. Two live sessions with one background identifier is unsupported; delegate callbacks can route to the discarded adapter and silently break download completion.
- **Fix:** make the heavy stores process singletons (`static let shared`) or guard their creation behind the same static-once pattern as `configurePipeline`. At minimum, the background `URLSession` must be created once per process.

---

## 2. Security

### Verified healthy (no action)
- **Loopback stream proxy** (`CinemaxStreamProxy`): listener bound with `requiredInterfaceType = .loopback`; per-stream **UUID-based unguessable** `/s/<id>` paths (a co-resident app port-scanning loopback can't enumerate streams); request-head read capped at 64 KB; target map bounded.
- **ATS:** only `NSAllowsLocalNetworking` + `NSAllowsArbitraryLoadsForMedia` — appropriate posture for a self-hosted media client; no `NSAllowsArbitraryLoads`.
- **Token hygiene:** URL log sanitizer strips `api_key`/`apikey`/`*token*` query items (`JellyfinAPIClient.swift:14–29`); no token ever logged (0 `print()`, all `Logger` interpolations audited); download-URL query items filtered before persistence (`DownloadItem+BaseItemDto.swift:62`).
- **API-keys screen:** masked by default, `.privacySensitive()`, copy via `setItems(_:options:)`, revoke of current session hidden — matches its documented rules.
- **Extensions:** widget + Top Shelf both read the session **Keychain-first** with the plaintext App Group copy as documented transitional fallback; contract literals (service/account/group/suite/key/JSON shape) match across all three copies.
- **Deep links:** `cinemax://item/{id}` validated (scheme + non-empty id), id only ever used as a server-validated item id — no injection surface.
- **QuickConnect:** secret never rendered or logged; lives only in the task capture.

### Findings
| # | Sev | Finding | Where | Fix |
|---|-----|---------|-------|-----|
| S1 | **Medium** | **Parental-rating ceiling off by one category.** `privacy.maxContentAge = 12` maps to `maxOfficialRating = "PG-13"` (age 13) and 16 → `"TV-MA"` (age 17) on server-filtered paths (`getItems`, `searchItems`), so over-ceiling titles appear in Library/Search while Home (client-filtered) hides them. | `ContentRatingClassifier.swift:58–67` | Map each ceiling to a rating whose age is ≤ the ceiling, and/or run `applyRatingFilter` on `getItems`/`searchItems` results (as `getPersonItems` already does). |
| S2 | **Medium** | **Keychain migration is delete-then-add** — if the add fails after the delete, the credential is permanently gone and the user is silently logged out next launch (the doc comment's "lossless" claim only holds in memory). | `KeychainService.swift:287–302` via `migrateAccessibilityIfNeeded` (`:164–180`) | Use `SecItemUpdate` to change `kSecAttrAccessible` in place (it's updatable), or write-then-swap. |
| S3 | **Medium** | **Plaintext UserDefaults token fallback is overdue for removal.** Documented "DROP next release"; `MARKETING_VERSION` is already 1.0.4. Until dropped, the token sits readable-at-rest in the App Group. | `ExtensionSessionBridge.swift:56` | Schedule the drop as a versioned task for the next release: remove the `defaults.set`, keep the readers' fallback for one more cycle, then delete those too. |
| S4 | Low | `ExtensionSessionBridge.read()` is dead code that reads **only** the plaintext copy — a future caller would silently bypass the Keychain. | `ExtensionSessionBridge.swift:78–82` | Delete it (or make it Keychain-first like the extensions). |
| S5 | Low | `device_id` migration is best-effort and excluded from the migration's `allSucceeded` — the one-shot flag can latch with the device id still unreadable pre-first-unlock on tvOS → fresh UUID per boot → device-list pollution and the admin "can't revoke THIS DEVICE" guard comparing the wrong id. | `KeychainService.swift:176` | Fold the device-id rewrite into `allSucceeded`, or migrate via `SecItemUpdate`. |
| S6 | Low | `http://` server URLs are accepted with no warning — the access token then travels cleartext on the LAN. Acceptable for self-hosting, but silent. | `ServerSetupViewModel.swift:22–30` | One-time warning toast/sheet when connecting over plain http. |
| S7 | Low | Rating ceiling not applied on id-addressed paths (`getItem`, `getSeasons`, `getPlaybackInfo`, `buildDownloadRequest`) — a restricted profile holding an item id (e.g. deep link) can view/play/download above-ceiling content. Real enforcement is server-side parental controls; this is a documented-scope gap worth an explicit decision. | `JellyfinAPIClient+Library.swift:145, 183` | Either document as out of scope or add the client-side check on `getItem`. |

---

## 3. Bugs & correctness

### Verified healthy (no action)
- Session-expiry coordinator: debounce set before first suspension, `defer` resets on every exit path, offline ⇒ never logout, only confirmed `.invalid` logs out — exactly as documented, with regression tests (`SessionResilienceTests`).
- `isUnauthorized` SSOT is structural (no `"(401)"` substring in the logout flow).
- QuickConnect lifecycle: poll cancelled on sheet dismiss on both platforms; reopen state reset correct.
- `VideoPlayerCoordinator` generation counter covers stale-dismiss and double-present windows.
- Seek coalescing, scrub `pendingScrubTargetMs`, teardown cancellation of events/timers/tasks in both presenters — all verified against the documented designs.

### Findings
| # | Sev | Finding | Where | Fix |
|---|-----|---------|-------|-----|
| B1 | **Medium** | **`.cinemaxSessionExpired` consumed off-main.** The notification is posted synchronously from a cooperative-pool thread; `.onReceive` runs its closure on the posting thread, and the closure reads `appState.isAuthenticated` (MainActor state) before hopping into the safe `Task { @MainActor }` — a data race / potential dynamic-isolation trap. | Post: `AppNavigation.swift:95–97`; observe: `:439–448` | Add `.receive(on: DispatchQueue.main)` to the publisher, or post from within `Task { @MainActor }`. |
| B2 | **Medium** | **QuickConnect poll dies permanently on one transient error** while the code stays on screen — user approves a code the app is no longer polling; only recovery is dismiss/reopen (which mints a different code). Flagship tvOS flow. | `LoginViewModel.swift:49–61` | Tolerate transient poll failures with a bounded consecutive-failure budget; clear `quickConnectCode` when surfacing a fatal error. |
| B3 | **Medium** | **`connectToServer`/`authenticate` never clear `APICache`** → after "Change server", `fetchServerInfo` (constant key, TTL 600 s) serves the previous server's name/version for up to 10 min. `reconnect()` clears; these don't. | `JellyfinAPIClient.swift:148–171, 224` | `cache.clear()` at the top of both. |
| B4 | Medium | **`getLatestMedia` cache key omits `parentId`** — latent today (only caller passes nil) but the first library-scoped call ships a wrong-library cache collision silently. | `JellyfinAPIClient+Library.swift:53–54` | Include `parentId ?? "root"` in the key. |
| B5 | Low | Stale search task's `defer { isSearching = false }` can kill the spinner of a newer in-flight search if cancellation propagates slowly (>400 ms). | `SearchViewModel.swift:334–356` | Generation counter; only current generation writes `isSearching`/`results`. |
| B6 | Low | QuickConnect: no `Task.isCancelled` check between `initiateQuickConnect()` returning and writing `quickConnectCode` — rapid dismiss→reopen can display the old code while polling the new secret. | `LoginViewModel.swift:41–42` | `guard !Task.isCancelled` after the await; treat `URLError(.cancelled)` like `CancellationError`. |
| B7 | Low | A second, banned-pattern 401 detector survives in `LocalizationManager` (`desc.contains("(401)")`) — message-mapping only, can't cause false logout, but can mislabel errors. | `LocalizationManager.swift:70` | Pass the `Error` through and use `JellyfinAPIClient.isUnauthorized`. |
| B8 | Low | Dead branch in `isUnauthorized`: `NSURLErrorFailingURLErrorKey` carries an `NSURL`, never an `HTTPURLResponse` — the cast always fails, implying coverage that doesn't exist. | `JellyfinAPIClient.swift:114–117` | Remove. |
| B9 | Low | `markItemUnplayed` lacks the `notifyIfUnauthorized` its mirror `markItemPlayed` has; `getCollections` direct-lookup swallows 401 via `try?` while its fallback notifies — asymmetry invites drift. | `JellyfinAPIClient+Library.swift:230, 304` | Align the siblings. |
| B10 | Low | Torn client/serverURL snapshot: readers call `getClient()` then `getServerURL()` under separate lock acquisitions — a reconnect between the two yields server A's auth against server B's URLs. Tiny window. | `+Playback.swift:22–23` etc. | Locked `getClientAndURL()` pair accessor. |
| B11 | Low | `completeSession` swallows keychain save failure — next launch silently lands on login with no explanation. | `LoginViewModel.swift:74–79` | Log + toast. |
| B12 | Low | `AdminDashboardViewModel` sets `errorMessage = "—"` when both calls fail — the em-dash renders as the entire error banner. | `AdminDashboardViewModel.swift:31` | Localized generic-failure key. |

---

## 4. Performance

### Verified healthy (no action)
Startup path (keychain-only before first render), `MenuConfigStore` (decode in init only), TaskGroup parallelism in Home/Detail/Library VMs, `fetchRanked` fan-out cap + dedup, single 1 s player tick fanning to sub-controllers, seek coalescing, proxy backpressure (concurrent delegate queue, bounded reconnect budget), image pipeline config + byte-identical prefetch URLs, `APICache` sweep, cached `totalDiskBytes`.

### Findings
| # | Sev | Finding | Where | Fix |
|---|-----|---------|-------|-----|
| P1 | **Medium** | Root `@State` rebuild on scene events — see **1.3** (duplicate background URLSession + main-thread disk work). | `AppNavigation.swift:285–294` | See 1.3. |
| P2 | **Medium** | **`DownloadStorage.downloadsRoot()` does ~10 syscalls (incl. attribute writes) per call** and is called from render paths: `localPosterURL`/`localBackdropURL`/`localURL` are evaluated per visible row per body pass — ~300 syscalls per render with 30 offline rows, re-triggered by every progress tick. | `DownloadStorage.swift:17–30, 116–138` | Resolve the root once (`static let` / lock-guarded lazy); run `ensureDirectory`+protection only at startup and before writes. |
| P3 | **Medium** | **UI-side progress has no throttle:** every `didWriteData` spawns a MainActor task and mutates `items[idx]` (an `@Observable` array write) — tens of invalidations/sec across every downloads-observing view (all `DownloadButton`s, offline library, settings banner). The documented 5 s throttle covers only the disk write. | `DownloadManager.swift:415–427, 571–581` | Coalesce in the Adapter (flush last-values to MainActor at 2–4 Hz), or move per-item progress to a side table only progress rows observe. |
| P4 | **Medium** | **`DownloadStore` persists the whole catalog synchronously on the main thread with `resumeData` blobs inlined** in `index.json` (base64 +33%; tens of KB per paused item). Also contradicts the documented layout — `resume/<id>.resume` files are only ever deleted, never written. | `DownloadStore.swift:42–118` · `DownloadItem.swift:60` | Store blobs as `resume/<id>.resume` files with a flag in the catalog; move `persist` to a serial background queue. |
| P5 | Low | `getItem` is uncached and fetched 2–3× per playback start (presenter + NowPlaying enrich + end-of-series). | `JellyfinAPIClient+Library.swift:145` | 30–60 s `APICache` entry keyed `item:<id>:<userId>`. |
| P6 | Low | All chapter thumbnails download eagerly at stream open (~30 concurrent fetches while libVLC is opening the stream, competing on slow links). | `VLCStreamPresenter.swift:1818–1832` | Defer to first HUD/strip display, or bound concurrency to 2–3. |
| P7 | Low | `didFinish` runs `moveItem` + `stat` on MainActor (multi-GB move can stall a frame); `store.all()` returns dictionary-ordered array → unstable `ForEach` diffs. | `DownloadManager.swift:429–496` | Stage move+stat on the delegate queue before hopping; sort `all()` by `createdAt`. |
| P8 | Low | Every foreground revalidation (`.valid`) runs `refreshCurrentUser` → `ExtensionSessionBridge.publish` → synchronous shared-Keychain writes on the main actor at resume time. | `ExtensionSessionBridge.swift:41` | Skip publish when the session tuple is unchanged; or write off-main. |

---

## 5. Duplication & refactoring (~700–800 removable lines)

Ranked by ROI. Existing SSOTs (`SettingsRowHelpers`, `AdminLoadStateContainer`, `AdminFormScreen`, `PaginatedLoader`, `PlayerTimeFormat`) are good — most findings are surfaces that predate or bypass them.

| # | Refactor | Evidence | Est. saved | Risk |
|---|----------|----------|-----------|------|
| D1 | **`withLoad` helper (`AsyncLoadable` protocol)** for the `isLoading=true; errorMessage=nil; defer…; do/catch userFacingMessage` scaffold | **~40 near-identical blocks** across 20 VM files (all Admin VMs + Metadata + Identify); also fixes the inconsistency that Admin VMs never `logger.error` on failure (non-Admin VMs do) | 180–220 | Low–Med |
| D2 | **`AdminListRow` + `AdminStatusPill`** | 9 bespoke icon+title+subtitle+trailing rows (Dashboard/Devices/Plugins/ApiKeys/Tasks/Catalog/Logs/Metadata/Offline) + 6 copy-pasted capsule badges | 100–120 | Low–Med |
| D3 | **Hoist `iOSRowIcon`/`iOSSettingsDivider`/`iOSSettingsSectionHeader` out of `#if os(iOS)`** — `PrivacySecurityScreen` (cross-platform) re-implements all three verbatim because it can't call them; then migrate its hand-rolled rows | `PrivacySecurityScreen.swift:274–300` vs `SettingsRowHelpers.swift:73–102` | ~35 | Low |
| D4 | **`.destructiveConfirm(item:…)` modifier** folding the optional→Binding adapter + destructive button + toast + reset | 3 near-verbatim dialogs (Devices/Plugins/ApiKeys) + 3 partial (MetadataImages/Network/UserDetail) | ~70 | Low–Med |
| D5 | **`settingsHubButton` + `tvPickerRow` builders** | `iOSCategoryButton` ≈ `iOSInterfaceSubButton` (~50-line copies); 3 identical tvOS picker rows (font-size/library-layout/sleep-timer, ~40 lines each) | ~125 | Low |
| D6 | **Shared toggle-row + `.adminRefreshable` + add-button modifiers** | local `toggleRow` re-defined in 5 admin files; `.refreshable`+`.task{if empty{load}}` pair verbatim in ~10 screens; identical `+` toolbar button ×2 | ~90 | Low–Med |
| D7 | **Adopt `PaginatedLoader` in `AdminActivityViewModel`** — it hand-rolls the identical offset/append/hasMore machine the shared type already implements (needs a thin error hook) | `AdminActivityViewModel.swift:9–56` vs `PaginatedLoader.swift:19–31` | ~25 | Low |
| D8 | **Unify stale-result guards** — the "only the latest wins" semantics exist as 4 different implementations (Int generation ×2, owned-Task cancel ×3, debounce ×1) | MediaDetailVM, NowPlayingInfoController, SearchVM, MediaLibraryVM, LoginVM, ScheduledTasksVM | ~30 | Med |
| D9 | Rename `AdminSectionGroup` → shared `SettingsSectionGroup` (it's not Admin-specific; iOS settings hand-roll the same combo ~6×); extract `StickyActionFooter` (IdentifyScreen copies `AdminFormScreen.saveFooter`) | `SettingsScreen+iOS.swift:207–332` · `IdentifyScreen.swift:119–135` | ~35 | Low |
| D10 | Promote `FolderBrowseViewModel`'s `State` enum to a shared generic `LoadState` — it's the only principled load-state model in the codebase; converge the ad-hoc `isLoading`+`errorMessage` pairs and the `loadFailed: Bool` one-off (`FavoritesViewModel`) onto it over time | `LibraryFolderBrowseScreen.swift:129–155` | consistency | Med |

Also: `MetadataBrowserScreen`/`MetadataLibraryItemsScreen`/`UserSwitchSheet` hold network `load()` logic inline in View `@State` — the only screens that do; extract VMs for symmetry.

---

## 6. Best practices, testing, CI, accessibility

### Findings
| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| Q1 | **High** | **SwiftLint CI gate is decorative** — the lint job ends `continue-on-error: true`, so `--strict` can never fail a PR. A gate that always passes is worse than none. | One-time violation cleanup, then remove `continue-on-error`. |
| Q2 | **Medium** | **All ~15 Admin VMs take `any APIClientProtocol` instead of the `AdminAPI` slice** — CLAUDE.md defines `AdminAPI` as *the privilege boundary*; the compiler currently can't catch capability creep into admin code. `MenuConfigStore.attach` likewise needs only `LibraryAPI`. | Narrow to `AdminAPI` (compose `AdminAPI & AuthAPI` where devices are needed). |
| Q3 | Medium | **Untested load-bearing pure logic:** `StreamTransportPolicy.shouldPreferProxy` (hang-vs-fast-fail classification), `parseRange`, `UpstreamHandler` reconnect-budget renewal, `DownloadManager` container detection + the "Zéro ko" file-size finalization (a shipped past regression), tvOS `hiddenHUDIntent` press whitelist (a documented regression trap). No tests execute against tvOS at all (`CinemaxTV.scheme.testTargets: []`). | Extract these as pure functions and pin them; wire a tvOS test bundle. |
| Q4 | Medium | Localization parity (currently perfect) and `project.pbxproj` drift are unguarded in CI — the parity check is a 5-line shell step; the drift check is `git diff --exit-code` after `xcodegen generate`. | Add both to `ci.yml`. |
| Q5 | Medium | **VoiceOver:** `CinemaToggleIndicator` (the mandated system-Toggle replacement) announces no state/trait — every settings toggle in the app is label-only to VoiceOver. `AlphabeticalJumpBar` has no accessibility support at all. | Add `.accessibilityValue`/`.isToggle` once in the row helpers; `.adjustable` trait (or `accessibilityHidden`) on the jump bar. |
| Q6 | Low | Four stale audit reports at repo root (`APP_STORE_AUDIT.md`, `AUDIT.md`, `AUDIT_2026-06-09.md`, `Audit_post_vlc.md`). | Move to `docs/audits/` or delete once actioned. |
| Q7 | Low | No root `README.md` (setup: Xcode 26.2, `brew install xcodegen`, `xcodegen generate`, schemes) — CLAUDE.md is agent-facing. | 40-line README. |
| Q8 | Low | `docs/design-system/` untouched since 2026-06-09 while 12 commits touched `Shared/DesignSystem/`; CLAUDE.md references a non-existent `appIcon.png`. | Drift pass + one-line doc fix. |
| Q9 | Low | No code-coverage measurement in CI; placeholder package test target passes green while testing nothing. | `-enableCodeCoverage YES` + xcresult summary; delete/annotate the stub. |
| Q10 | Low | No contrast validation for accent variants (hardcoded `.white` on `accentContainer`, esp. the rainbow hue sweep). | Unit test computing WCAG ratio per `AccentOption`. |

### Verified healthy
Logging (single subsystem, coherent categories, privacy annotations correct), localization (725/725 key parity, no hardcoded user-facing strings), error UX (all user-facing errors route through `userFacingMessage(for:)`), dependency pinning (documented + `Package.resolved` tracked), TODO count (2), CI serializes iOS/tvOS builds and uses `set -o pipefail` correctly.

---

## 7. Suggested fix roadmap

**P0 — this week (correctness/security, small diffs):**
1.1 base-path URLs · 1.2 swallowed 401 · 1.3 singleton stores/background session · S1 rating off-by-one · B1 notification main-hop · B3 cache clear on server switch · Q1 make SwiftLint real

**P1 — next release:**
S2 keychain `SecItemUpdate` migration · S3 drop plaintext token write (+S4 dead `read()`, S5 device-id) · B2 QuickConnect poll resilience · P2 `downloadsRoot` caching · P3 progress-tick coalescing · P4 resume-blob extraction · Q2 AdminAPI slices · Q4 CI parity+drift gates · Q5 VoiceOver toggles

**P2 — opportunistic (quality):**
D1–D10 refactors (start with D1, D2, D3) · Q3 test extraction targets · B4–B12 low bugs · P5–P8 low perf · Q6–Q10 hygiene

---

## 8. UX feature recommendations (end-user)

Ranked by impact-for-effort for a Jellyfin client:

1. **SyncPlay / Watch Together** — Jellyfin has a first-class SyncPlay API; very few Apple clients support it. Big differentiator, natural fit for the tvOS living-room context.
2. **Auto-skip intro/credits option** — the Skip button exists; add a per-user setting "skip automatically" (with a small "skipped intro" toast). Cheap: the segment controller already knows the windows.
3. **"Remove from Continue Watching" / "Mark watched" context menu** on Home cards (long-press iOS, play/pause-hold tvOS). Users can't currently clean their resume row — a top complaint in every Jellyfin client.
4. **Smart episode downloads (iOS)** — "keep next 3 unwatched episodes of this series downloaded, delete watched ones" + a Wi-Fi-only toggle and a storage cap. The DownloadManager plumbing is already there.
5. **Offline progress sync-back** — record playback position while offline and report it on reconnect (PlaybackReporter is auto-gated off offline today, so offline viewing loses resume state across devices).
6. **Siri Shortcuts / App Intents + Spotlight** (iOS) — "Continue watching X", index the library so titles surface in system search / Siri. Also enables the Action button.
7. **Subtitle appearance settings** for the VLC path (size / background opacity) — libVLC exposes this; the native path inherits system caption settings but VLC users have no control.
8. **Search filters + person pages** — filter search results by Movies/Series/People; tapping an actor already works via cast circles, but search can't find people-first.
9. **New-episode notifications** — background refresh checking Next Up for favorited series; local notification "S02E05 of X is available".
10. **Per-user PIN lock** (parental) — the `maxContentAge` ceiling exists; a PIN gate on switching to unrestricted profiles completes the story.
11. **Playback queue for playlists/collections** — Play-all + shuffle on boxsets/playlists (folder browse exists; playing through a folder doesn't).
12. **Trailers on tvOS** — the iOS-only trailer button opens Safari; on tvOS, play `remoteTrailers` URLs through the existing player instead (YouTube links excluded; many servers host local trailers).

## 9. UI recommendations

1. **Skeleton/shimmer placeholders** on Home rows and Library grids instead of spinner-then-pop — the editorial Cinema Glass look benefits enormously from stable layout during load (respect `motionEffects`).
2. **Rotating hero** on Home — cycle 3–5 featured items with a subtle crossfade + page dots; today the hero is static per load.
3. **Haptics (iOS)** on toggle flips, download completion, and skip actions — glassmorphism UIs feel flat without tactile confirmation.
4. **Watched checkmarks + progress ticks in episode lists** — at a glance "where am I in this season" without reading the metadata line.
5. **iPad two-column detail layout** — backdrop/poster+actions left, episodes/cast right; the current stacked phone layout underuses landscape iPad (split view work is already done).
6. **Empty-state art** — the `EmptyStateView` icon+text is functional; a few branded illustrations (empty downloads, empty search, offline) would lift perceived quality a lot.
7. **Settings search field** (iOS) — Settings is now 3 levels deep with many toggles; a simple filter over the row catalogues (they're already data-driven — cheap win).
8. **tvOS poster focus parallax** — subtle tilt/specular on focused `PosterCard` (system `hoverEffect` is disabled by design; a custom 2–3° rotation gated on `motionEffects` keeps the design language while adding depth).
9. **Download progress in the tab bar / Live Activity** — a small progress ring on the Downloads row (and an iOS Live Activity for active downloads) so users don't sit on the screen.
10. **Accent-aware contrast guard** — pair with Q10: if a custom accent fails contrast for `.white`, auto-switch label to `onSurface` — protects the rainbow easter egg.

---

## Coverage note

Five audit dimensions were fully covered (security, performance, API layer, auth/session state machines, duplication in view models + Settings/Admin, best practices). Two sub-analyses (screen-level view duplication beyond Settings/Admin, and a dedicated playback sub-controller pass) were cut short by an external budget limit; the player and API layers were nonetheless covered by the performance and API audits. If desired, a follow-up pass can sweep `MediaDetail*`/`HomeScreen`/`MovieLibraryScreen` view-layer duplication specifically.
