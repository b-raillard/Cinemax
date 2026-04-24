# Cinemax — Full Project Audit

_Audit date: 2026-04-24. Scope: ~22.8k LOC of Swift across ~180 files. Five parallel specialized audits (security, performance, code quality, design system, architecture + testability)._

## Executive summary

Swift 6 strict concurrency, solid MVVM + protocol architecture, no singletons resisting tests. The bones are good: DI is protocol-driven, admin gating is defense-in-depth (client + server), Keychain is used correctly, error-recovery patterns exist.

Weak spots, in order of actual impact:
1. One real **performance footgun** (rainbow accent re-renders the app tree at 30 Hz)
2. Two **god-objects** (`NativeVideoPresenter` 1256 LOC, `JellyfinAPIClient` 1098 LOC)
3. **Test coverage**: great *depth* where tests exist, but ~60% of VMs and the entire admin surface are untested
4. **Design-system drift**: font/spacing tokens skipped in ~40 sites; two raw-image-loading leaks
5. **Token handling minor gaps**: pasteboard without expiration, debug logs with `api_key=` in URLs, no optional biometric gate

Nothing is critical. Nothing is broken. Everything below is pay-down-the-debt territory.

---

## Cross-cutting themes

These findings appeared in multiple audits and are the most leveraged fixes:

| Theme | Impact | Audits flagging |
|---|---|---|
| **`JellyfinAPIClient.swift` is a 1098-line god class** | Readability, test boundaries, caching scoped per-user is tangled up with auth and request building | Code quality + Architecture |
| **`NativeVideoPresenter.swift` is 1256 lines** despite already having 3 sub-controllers extracted | Chapter management + end-of-series overlay + track menus are each candidate sub-controllers | Code quality + Architecture (testability) |
| **Image loading bypasses `CinemaLazyImage` in 2 spots** (`CastCircle`, tvOS settings user avatar) | Design inconsistency + no memory cache for `AsyncImage` on tvOS | Performance + Design |
| **Backdrops request full device pixel width** (~3840 on 4K Apple TV, ~2732 on iPad Pro) | Bandwidth + memory — hero is behind a dark scrim, 1920 is enough | Performance |
| **No tests for admin surface (46 files), video-player sub-controllers, library VM** | Biggest coverage gap vs. biggest blast-radius changes | Architecture |
| **APICache not scoped by `userId`** | User-switch leaves cached DTOs from previous user | Architecture + Performance |

---

## Findings by domain

### Security (no critical findings)

- **M1** — `UIPasteboard.general.string = token` for copied API keys. No expiration, syncs to Universal Clipboard. `Shared/Screens/Admin/ApiKeys/AdminApiKeysScreen.swift:376`. Use `setItems(_:options:)` with `.expirationDate` (60s) + `.localOnly: true`.
- **M2** — Debug logs emit `transcodingURL`/`info.url.absoluteString`, which embed `api_key=<token>` as query params. `#if DEBUG`-gated so Release is fine, but Xcode Console sees tokens. `JellyfinAPIClient.swift:767,777,823,923`, `VideoPlayerView.swift:79`. Redact query items.
- **M3** — No optional biometric/passcode gate for admin sessions. Access token grants server-root to anyone with an unlocked device. Consider a "Require Face ID on launch" setting gating `AppNavigation.restoreSession()`.
- **L1** — `NSAllowsArbitraryLoadsForMedia = true` (iOS/tvOS `Info.plist:23`). Document the tradeoff for self-hosted HTTP Jellyfin servers.
- **L2** — HTTP-server warning is visual only; user can still proceed without explicit confirmation. `ServerSetupScreen.swift:102-104,207-209`.

**Verified correct**: Keychain uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, URL construction uses `URLComponents` throughout (no injection), API keys screen matches CLAUDE.md claims, admin gating defense-in-depth is real, dependencies are pinned and current (`jellyfin-sdk-swift` 0.6.0, `Nuke` 12.9.0, `Get` 2.2.1).

### Performance (one High, two Medium)

- **H1 — Rainbow accent re-renders the app tree at 30 Hz.** `ThemeManager.swift:81-88` advances `_rainbowHue` every 33 ms, bumping `_accentRevision` on a global `@Observable`. Every view reading `themeManager.accent` re-evaluates. Fix: isolate hue into a leaf `@Observable` (`RainbowAnimator`) or drop to 100 ms (10 Hz). Also: should respect `motionEffectsEnabled`.
- **H2 — `ImagePipeline.shared` reconfigured in `AppNavigation.init()`.** `Shared/Navigation/AppNavigation.swift:139-144`. SwiftUI can recreate root View structs; each recreation resets the pipeline. Move to app-level `init()` in `CinemaxApp`/`CinemaxTVApp` or guard with a static flag.
- **H3 — Backdrop URLs request unbounded native pixel width.** `MediaDetailScreen.swift:130`, `HomeScreen.swift:195`, `LibraryHeroSection.swift:33`. Cap at `min(screenPixelWidth, 1920)` — hero is behind a dark gradient, higher res is invisible.
- **M** — `RelativeDateTimeFormatter` instantiated per row in 5 admin list screens (`AdminActivityScreen:149`, `AdminUsersScreen:127`, `AdminDevicesScreen:154`, `AdminLogsScreen:82`, `AdminScheduledTasksScreen:140`). Hoist to file-private `static let` or use `.formatted(.relative(…))`.
- **M** — `MetadataLibraryItemsScreen.filteredItems` computes `.lowercased().contains()` on ≤500 items per keystroke without debouncing. `MetadataBrowserScreen.swift:114-118`.
- **M** — `getItems`/`getEpisodes`/`getSeasons`/`getItem` are NOT cached by `APICache`; only `getResumeItems`/`getLatestMedia`/`getGenres`/`fetchServerInfo` are. Repeated detail-screen navigation re-hits the network.
- **M** — `JSONEncoder`/`JSONDecoder` allocated per call in playback hot path (`JellyfinAPIClient.swift:865,895,489,497,506,511`). Cache as `static let` with configured date strategy.
- **L** — `HomeViewModel.load` runs `loadGenreRows` and `loadActiveSessions` serially after the `TaskGroup` (`HomeViewModel.swift:114-122`). `MediaLibraryViewModel.performLoad` awaits `heroResult` before fanning out (`:90-105`). Both could be fully parallel.

**Verified correct**: all `AVPlayer` observer teardown, single-observer invariant, sub-controller task cancellation, `APIClient` NSLock contention is minimal.

### Code quality / refactoring

- **H — `JellyfinAPIClient.swift` (1098 LOC)** — already MARK-sectioned into 14 domains; split into `JellyfinAPIClient+Auth.swift`, `+Library.swift`, `+Admin.swift`, etc.
- **H — `NativeVideoPresenter.swift` (1256 LOC)** — extract `ChapterController` (lines 645–750) and `EndOfSeriesOverlayController` (861–1005), matching the existing `PlaybackReporter` / `SkipSegmentController` / `SleepTimerController` pattern.
- **H — Raw `UserDefaults` string keys bypass `SettingsKey` SSOT** in `NativeVideoPresenter.swift:391,558,807` (`"debug.showSkipToEnd"`, `"autoPlayNextEpisode"`). Replace with `SettingsKey.*`.
- **H — 28 `try?` call sites swallow errors silently.** Worst: `PrivacySecurityScreen.swift:269` (per-item mark-unplayed loop); `SettingsScreen+tvOS.swift:426` (empty catch, no feedback). Pattern: user-initiated failures → `toasts.error`; background loads → silent.
- **M — `MediaDetailScreen.swift` (1097 LOC)** — `iOSEpisodeCard` (478–563) and `episodeRow` (565–660) are near-duplicate episode renderers; 23 adaptive-sizing computed properties (740–869) belong in a `DetailMetrics` struct.
- **M — `AdminComingSoonScreen.swift` has zero references** (all phases shipped). Delete.
- **M — `AdminUserDetailScreen.swift:310`** — force-unwrap `parentalRatingOptions.first!`. Add safe fallback.
- **M — VM naming drift**: `load` / `reload` / `fetch` mixed within the same file. Standardize.
- **M — `reportPlaybackStart/Progress`** take 7 params. Introduce a `PlaybackReport` struct.
- **L — Hardcoded paddings** `16`/`8`/`10` in `MediaDetailScreen` season pills — use `CinemaSpacing`.

**Verified clean**: no TODO/FIXME/HACK in project code; all Swift 6 `nonisolated`/`@unchecked Sendable` usages are load-bearing and documented at their sites; fr/en localization has 586 keys each, in sync.

### Design system consistency

Top debts (by count):

- **H — `.font(.system(size: N))` without `CinemaScale.pt(...)`** in ~30+ sites. Worst offenders: `ToastOverlay`, `GlassTextField`, `MediaDetailScreen`, `ServerDiscoverySheet`, `AdminUsersScreen`, `AdminDevicesScreen`, `AdminApiKeysScreen`, `HomeScreen` ("LIVE" pill). Also `CastCircle.swift:20` uses `.font(.title2)` and `CinemaLazyImage.swift:34` uses `.font(.largeTitle)` — bare system fonts are in the `conventions.md` rejection list.
- **H — Raw `LazyImage`/`AsyncImage`**: `CastCircle.swift:13`, `SettingsScreen+tvOS.swift:625`. Replace with `CinemaLazyImage`.
- **M — Literal spacing** in ~40 sites; worst files: `MediaDetailScreen.swift`, `MovieLibraryScreen.swift`, `GlassTextField.swift`.
- **M — `.animation()` calls not gated by `motionEffectsEnabled`** in 5 places: `GlassTextField.swift:83,118`, `SettingsAppearanceView+iOS.swift:143`, `MediaDetailScreen.swift:1094`, `LoginScreen.swift:353`, `SearchScreen.swift:377` (voice-search pulse).
- **M — `CinemaButton style: .primary` on a primary CTA** — `UserSwitchSheet.swift:151` Sign-In button should be `.accent`.
- **M — 1 px borders outside the 4-item whitelist** — `SettingsScreen+iOS.swift:123`, `ToastOverlay.swift:70`.
- **L — Localization gaps**: `Text("LIVE")` in HomeScreen, `"/ 10"` suffix in `MetadataEditorScreen`, `"v\(version)"` in Plugins.

**Verified clean**: no `Color(hex:)` outside theme, no `CinemaColor.tertiary*`, no direct `@AppStorage` mode writes, no toolbar `.glass*` styles, no hardcoded 1920, no duplicate `.preferredColorScheme()`, tvOS focus rules respected (colorScheme passed, no white backgrounds, no scale transforms outside allowed pill).

### Architecture / testability

- **M — `APICache` bleeds across user switches.** Memory-only, keyed by params not `userId`. `UserSwitchSheet` re-auth does not call `clearCache()`. Either add the clear, or key by `userId`.
- **M — Dual test-location quirk**: `APICacheTests.swift` + `PlayMethodTests.swift` test CinemaxKit but live in the root `Tests/` (app target) because adding `package: CinemaxKit` to `CinemaxTests` in `project.yml` causes `Get` double-link. Move them to `Packages/CinemaxKit/Tests/` and delete the placeholder `CinemaxKitPackageTests.swift`; add a comment in `project.yml` explaining the constraint.
- **M — Zero `#Preview` blocks across 115 Shared files.** Biggest dev-velocity lift per hour for a dark design system. Add previews for the ~15 DesignSystem components first.
- **M — CinemaxKit imports UIKit** (`ImageURLBuilder.swift` via `#if canImport(UIKit)`) only for `UIScreen.main.scale`. Move pixel-scale resolution to the app layer; keep CinemaxKit UI-agnostic.

**Test coverage gap table:**

| Area | Untested |
|---|---|
| View models | `MediaLibraryViewModel`, `VideoPlayerCoordinator`, all 13 admin VMs, `IdentifyFlowModel`, `HomeViewModel.retryGenre`/`loadGenreRows` failure path, `MediaDetailViewModel.load` resolve-episode path |
| App controllers | `PlaybackReporter`, `SkipSegmentController`, `SleepTimerController` (all designed to be testable — closure seams, `PlaybackAPI`-only DI) |
| CinemaxKit | `ImageURLBuilder`, `JellyfinAPIClient` (device profile, cache keys, rating filter), `JellyfinServerDiscovery`, `ContentRatingClassifier`, `KeychainService`, `HLSManifestLoader` (VTT ASS-tag stripping) |
| App code | `LibrarySortFilterState` computed props, `precomputeEpisodeRefs` / `buildEpisodeNavigation` |
| UI tests | None exist |

**Verified good**: protocol-driven DI throughout, no `.shared` singletons in app code, leaf controllers narrow to `any PlaybackAPI` as CLAUDE.md claims, feature gating clean (`#if os(iOS)` only in platform-specific UI and Admin), existing tests are real behavioral tests (regression for defer-spinner bug, generation-counter race), navigation router is single-source.

---

## Top 15 prioritized actions

Ranked by (user-visible impact or risk) × (effort inverted).

1. **[HIGH] Fix rainbow 30 Hz accent tick** — `ThemeManager.swift:81-88`. Biggest single perf win; also violates motion-effects flag.
2. **[HIGH] Move `ImagePipeline.shared` config out of `AppNavigation.init()`** into app-level `init()`.
3. **[HIGH] Cap backdrop URLs** at `min(screenPixelWidth, 1920)`.
4. **[HIGH] Replace `UIPasteboard.general.string = token`** with expiring+local-only pasteboard item for API keys.
5. **[HIGH] Redact access tokens from debug URL logs** (`JellyfinAPIClient` + `VideoPlayerView`).
6. **[HIGH] Replace raw string keys with `SettingsKey.*`** in `NativeVideoPresenter.swift`.
7. **[HIGH] Switch `CastCircle` and tvOS settings avatar to `CinemaLazyImage`**.
8. **[HIGH] Split `JellyfinAPIClient.swift`** into 14 per-MARK extensions.
9. **[HIGH] Extract `ChapterController` + `EndOfSeriesOverlayController`** from `NativeVideoPresenter`.
10. **[MEDIUM] Clear `APICache` on user-switch** (or key by `userId`).
11. **[MEDIUM] Audit 28 `try?` sites** — start with `PrivacySecurityScreen:269` + `SettingsScreen+tvOS:426`; add toasts where user-initiated.
12. **[MEDIUM] Add tests for `PlaybackReporter` / `SkipSegmentController` / `SleepTimerController`** — they were designed for this and have no tests.
13. **[MEDIUM] Add `#Preview` blocks** for the ~15 DesignSystem components.
14. **[MEDIUM] Delete `AdminComingSoonScreen.swift`** (0 refs) and relocate `APICacheTests`/`PlayMethodTests` into `Packages/CinemaxKit/Tests/`.
15. **[MEDIUM] Font/spacing token sweep** — ~40 sites; one PR per screen region keeps diffs small.

---

## Positive signals (what's worth preserving)

- Defense-in-depth admin gating (client + server) is real and correctly implemented.
- Keychain usage is textbook-correct (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, no iCloud sync).
- `MockAPIClient` genuinely substitutes — no sneaky concrete reaches.
- Existing tests are real regression tests, not smoke.
- `AppNavigation` is the single auth router, no sub-screen drift.
- The `PlaybackReporter`/`SkipSegmentController`/`SleepTimerController` extraction pattern is the right model — just needs to be applied twice more inside `NativeVideoPresenter`.
- Swift 6 `nonisolated`/`@unchecked Sendable` usages are all load-bearing and documented.
- Single `.preferredColorScheme` call site, no `Color(hex:)` drift, no `CinemaColor.tertiary*`, fr/en localization in sync with 586 keys each.
