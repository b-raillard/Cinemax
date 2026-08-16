# Cinemax — Full Codebase Audit (2026-08-16)

Scope: security, performance, Swift 6 concurrency, correctness, App Store compliance and maintainability across 257 Swift files / 56,553 lines (`Shared`, `Packages/CinemaxKit`, `iOS`, `tvOS`, `Widgets`, `TopShelf`, CI config). Audited at `main` @ `1608c71` (v1.2.0).

CLAUDE.md was used as ground truth: decisions documented as deliberate are not re-flagged; **deviations from documented contracts are**.

> **Method.** Eight independent auditors, one per dimension, each reading source directly. The 73 raw findings were then handed to per-dimension adversarial verifiers instructed to *refute* them: 55 were confirmed, 11 held as plausible, **7 were refuted and dropped**. A synthesis pass deduplicated the survivors into the 58 below and re-scored each on three axes. Static analysis only — no Swift toolchain was available, so nothing was compiled or executed.

**Overall verdict:** This is a well-engineered codebase carrying an unusually high documentation burden well. The hard subsystems are genuinely correct: the loopback stream proxy's admission and path-traversal logic is rigorous and test-locked (percent-encoded dot-segments, exact-match loopback Host to defeat DNS rebinding, GET/HEAD only); the JellyfinAPIClient lock discipline has no await inside a critical section and no accessor bypass; generation-token guards are re-checked after every await cluster in seven separate controllers; the extension session contract is Keychain-only across three copies and locked by tests; and the compliance surface (per-binary privacy manifests, required-reason APIs, usage descriptions, export compliance, entitlements, versioning SSOT) is in good shape on all three binaries. I found no critical issue: no exploitable hole, no credential exposure to third parties, no guaranteed crash on a common path, no App Store rejection risk. The real problems cluster in two places. First, failure states are systematically invisible — errors are caught and dropped across the app: MediaDetailScreen never clears errorMessage so its Retry button can never recover (H-1), Home reports "your library is empty" when the server is unreachable and latches hasLoaded so it never retries (M-1), PaginatedLoader swallows page-0 failures with no path back, the AdminDashboard writes an errorMessage no view reads, and all 39 admin catch blocks map for display without logging the raw error. Second, and more telling about process: roughly two thirds of the findings below are prior-audit items still open verbatim — the 2026-08-05 card-menu lot (F-46…F-56) was fixed thoroughly and correctly, while that same audit's view-layer lot (F-1, F-2, F-10, F-20, F-22, F-23, F-24, F-32, F-34) and network lot (F-7, F-9, F-13, F-15, F-16, F-41) were not touched at all, and three 2026-07-06 items (S1, S2, B1) are on their second re-report. The mechanisms that would catch drift are themselves disabled: the SwiftLint job ends `continue-on-error: true` so `--strict` can never fail a PR, tvOS ships with zero test execution, and localization parity is enforced only by discipline. Fix the enforcement gaps and the error-surface family first; the rest is mostly diffuse cost and hygiene.

---

## Scoreboard

| | Count |
|---|---|
| Findings | 58 |
| Critical | **0** |
| High criticality | 2 |
| Medium criticality | 22 |
| Low criticality | 34 |
| Confirmed by adversarial verification | 54 |
| Still open from a prior audit | **34** |
| Refuted during verification (dropped) | 7 |

Axis definitions, since they are scored separately:

- **Criticality** — how bad it is if it fires.
- **Importance** — how much it matters to *this* product: blast radius × likelihood of actually firing.
- **Priority** — the scheduling call that follows from importance and effort.

A critical-if-it-fires bug on an unreachable path has *low* importance; a medium bug on every app launch has *high* importance.

---

## Findings

Ranked; rank 1 = fix first. `Repeat` marks a finding that a previous audit already reported.

| # | ID | Finding | Area | Criticality | Importance | Priority | Effort | Repeat |
|---|----|---------|------|-------------|------------|----------|--------|--------|
| 1 | H-1 | MediaDetailScreen's Retry button can never recover — load() never clears errorMessage | correctness | high | high | P0 | S | — |
| 2 | H-2 | tvOS Search nests a vertical ScrollView inside a vertical ScrollView, so the results grid materialises every card at once | performance | high | high | P1 | M | `F-1 (2026-08-05), still open — unchanged in 1.2.0` |
| 3 | M-1 | A server outage renders as "Your library is empty" / "No results", and Home latches hasLoaded so it never retries | correctness | medium | high | P1 | M | — |
| 4 | M-2 | getItems — the hottest and fattest endpoint in the app — is the only uncached query in its file, and over-fetches on both axes | performance | medium | high | P1 | M | `F-9 and F-16 and F-15 (2026-08-05), all three still open` |
| 5 | M-3 | Parental rating ceiling is enforced inconsistently: off by one category on server-filtered queries, and absent on every id-addressed read | security | medium | medium | P1 | M | `S1 and S7 (2026-07-06), both still open; the intents surface is new since and inherits S7` |
| 6 | M-4 | The end-of-series overlay leaves the player's 1 s heartbeat running indefinitely — progress POSTs, Now-Playing metadata and the server-side "watching" session never stop | correctness | medium | high | P1 | S | — |
| 7 | M-5 | ThemeManager's four accent slots re-resolve the palette and allocate a dynamic UIColor on every read — twice per card | performance | medium | medium | P1 | S | `F-2 and F-3 (2026-08-05), both still open` |
| 8 | M-6 | "Recently Added" awaits its two sources sequentially in both copies, and the widget additionally fetches every poster one at a time inside WidgetKit's budget | performance | medium | medium | P1 | S | `F-7 (2026-08-05, marked "a empiré"), still open; the app-side copy was not previously reported` |
| 9 | M-7 | Blocking getaddrinfo (twice) and a 2.5 s blocking recvfrom loop run on Swift's cooperative thread pool | concurrency | medium | medium | P1 | M | `F-12 (2026-08-05), still open; the JellyfinServerDiscovery site was not covered by F-12` |
| 10 | M-8 | getCollections probes a 10.11-only endpoint speculatively (documented RULE deviation) and falls back to an unbounded, uncached recursive BoxSet scan | correctness | medium | medium | P1 | S | `F-17 (2026-08-05), still open` |
| 11 | M-9 | The iOS Home hero carousel's backdrops are never prefetched — the prefetcher's URLs don't match the hero's own request | performance | medium | high | P1 | S | `F-32 (2026-08-05), still open` |
| 12 | M-10 | .cinemaxSessionExpired is posted off the main actor and its onReceive handler reads MainActor state before hopping | concurrency | medium | medium | P1 | S | `B1 (2026-07-06), still open — listed as a P0 item in that audit's queue` |
| 13 | M-11 | The SwiftLint CI gate is decorative — `continue-on-error: true` means `--strict` can never fail a PR, and the test suite is excluded from linting entirely | compliance | medium | medium | P1 | S | `Q1 (2026-07-06, rated High and queued), still open verbatim` |
| 14 | M-12 | No rail, genre row or poster card is Equatable, so every progressive-load write re-renders every already-materialised card | performance | medium | medium | P2 | M | `F-20 and F-22 (2026-08-05), both still open` |
| 15 | M-13 | MediaDetailScreen's LazyVStack has only two children, so cast, episodes, collection and similar carousels are all built eagerly on open | performance | medium | medium | P2 | M | `F-24 (2026-08-05), still open` |
| 16 | M-14 | tvOS ships with zero automated test execution — no tvOS test target, and CI only builds the tvOS scheme | testing | medium | medium | P2 | M | `Q3 (2026-07-06), still open verbatim` |
| 17 | M-15 | Every "app-private" Keychain item is actually written into the shared extension access group, including tokens for all registered servers | security | medium | medium | P2 | M | — |
| 18 | M-16 | Native-path audio track switch orphans the previous server session (live stream + transcode job) and reports against a session the server never saw start | correctness | medium | medium | P2 | S | `F-28 fixed for the VLC wake path; this is the same class on an untouched path` |
| 19 | M-17 | KeychainService's single write path is destructive delete-then-add with no rollback, and every caller of it swallows the failure | correctness | medium | low | P2 | M | `S2 and S5 and B11 (2026-07-06), all still open; S2's scope has since grown to the registry` |
| 20 | L-1 | Loopback proxy pipes raw wire text into URLComponents.percentEncodedPath/Query, which raises on malformed percent-encoding | security | medium | low | P2 | S | — |
| 21 | L-2 | Chapter thumbnails fire as one batch during the stream-open window on the native tvOS path — the deferral the VLC path received was never applied | performance | medium | low | P2 | S | `F-5 (2026-08-05) — VLC half fixed, native half explicitly deferred and still open; also P6 (2026-07-06)` |
| 22 | L-3 | Proxy target map keeps a previous user's live access token after an in-app user switch, and is never pruned at playback teardown | security | medium | low | P2 | S | — |
| 23 | L-4 | Loopback listener accepts connections with no idle timeout and no concurrency cap, and is warmed for the whole session | security | medium | low | P2 | S | — |
| 24 | L-5 | Proxy listener bring-up has no ownership guard on either terminal branch, so a superseded listener can publish its port or free the gate | concurrency | medium | low | P2 | S | — |
| 25 | L-6 | The VLC path — the default engine — never reports progress when the app backgrounds | correctness | low | medium | P2 | S | — |
| 26 | L-7 | Cache is never cleared on logout or on connectToServer, and `serverInfo` has no server discriminator | security | low | medium | P2 | S | `B3 (2026-07-06) → F-13 (2026-08-05), still open on its third report; the logout leg is new` |
| 27 | L-8 | VLC chapter and trickplay images are cached in Nuke under a URL containing the access token, and the shared helper's contract claims the opposite | performance | low | medium | P2 | S | `F-41 (2026-08-05) — half fixed (chapters now ride the disk cache); the token-in-key half persists and the fix introduced the false claim` |
| 28 | L-9 | PlaybackInfo.authToken is deliberately nil on the transcode path, silently de-authenticating chapter, trickplay and artwork fetches | correctness | low | low | P3 | S | — |
| 29 | L-10 | The seek-heavy forced-transcode re-negotiation orphans one PlaybackInfo session per playback start, in either direction | correctness | low | low | P3 | S | — |
| 30 | L-11 | Transparent proxy reconnect assumes the origin honoured the Range; a 200 response makes the resume offset overshoot and splice corrupt bytes | correctness | low | low | P3 | S | `Q3 (2026-07-06) flagged parseRange and the reconnect budget as untested — still untested` |
| 31 | L-12 | Two unclamped Double→Int32 conversions on server-supplied tick values can trap | correctness | low | low | P3 | S | — |
| 32 | L-13 | Two seek entry points bypass the documented pending-target / coalescing path | correctness | low | low | P3 | S | — |
| 33 | L-14 | The VLC event-loop Task promotes self to a strong reference, making its [weak self] inert and leaving teardown single-triggered with no deinit net | performance | low | low | P3 | S | `F-29 (2026-08-05), still open` |
| 34 | L-15 | MediaLibraryViewModel.loadHeroNavigation writes heroPlay with no generation or identity guard | correctness | low | low | P3 | S | — |
| 35 | L-16 | Every poster and wide card eagerly constructs a MediaDetailScreen, allocating a view model per card per body pass | performance | low | low | P3 | M | — |
| 36 | L-17 | AdminItemMenu builds its whole Menu tree on every card body pass and installs a per-card sheet | performance | low | low | P3 | S | — |
| 37 | L-18 | SearchResultsGrid's == is coarser than SearchResultCard's, violating the invariant its own comment states | correctness | low | low | P3 | S | — |
| 38 | L-19 | NetworkMonitor writes isOnline with no equality guard and the app root observes it | performance | low | low | P3 | S | `F-10 (2026-08-05), still open` |
| 39 | L-20 | Multi-version ranking is re-sorted four or more times per MediaDetailScreen body pass | performance | low | low | P3 | S | `F-23 (2026-08-05), still open` |
| 40 | L-21 | Each tvOS poster card installs its own @AppStorage observer for a near-immutable Bool | performance | low | low | P3 | S | `F-34 (2026-08-05), still open` |
| 41 | L-22 | ImageURLBuilder.screenPixelWidth enumerates connectedScenes on every read, from the hottest hero bodies | performance | low | low | P3 | S | `F-33 (2026-08-05), still open` |
| 42 | L-23 | FlowLayout declares no cache and measures every subview twice per layout pass | performance | low | low | P3 | S | `F-43 (2026-08-05), still open` |
| 43 | L-24 | Both realtime sockets run on URLSessionConfiguration.default (shared disk URLCache and cookie store) while their URL carries the access token | security | low | low | P3 | S | — |
| 44 | L-25 | Plain-http server URLs are accepted silently, and NSAllowsArbitraryLoadsForMedia extends the cleartext window past the LAN | security | low | low | P3 | S | `S6 (2026-07-06), still open; the media-exemption half is new` |
| 45 | L-26 | Inbound DisplayMessage text is rendered in native app chrome with no length bound or sanitisation | security | low | low | P3 | S | — |
| 46 | L-27 | HLSManifestLoader's URLSession sets no request or resource timeout, inheriting the 7-day default | correctness | low | low | P3 | S | — |
| 47 | L-28 | Logout's auto-hop reports "switched to X" when the hop actually landed on a login screen — the registry's decision functions ignore their own model's contract | correctness | low | low | P3 | S | — |
| 48 | L-29 | SearchViewModel's stale search task can clear the newer search's spinner | concurrency | low | low | P3 | S | `B5 (2026-07-06), still open` |
| 49 | L-30 | TrickplayController accumulates a completed Task handle per tile fetch for the media's lifetime | performance | low | low | P3 | S | — |
| 50 | L-31 | All 39 admin catch blocks map the error for display but never log the raw error, deviating from the documented rule | maintainability | low | low | P3 | M | `noted inside D1's remediation (2026-07-06), still open` |
| 51 | L-32 | CI verifies only project.pbxproj for xcodegen drift, and relies on an uninstalled xcbeautify | maintainability | low | low | P3 | S | `Q4 (2026-07-06) was fixed for the pbxproj only; this is the residual gap` |
| 52 | L-33 | Localization parity is unguarded in CI despite an existing check being available as an agent-only skill | testing | low | low | P3 | S | `Q4 second half (2026-07-06), still open` |
| 53 | L-34 | jellyfin-sdk-swift is declared with a 0.x upToNextMajor range and Package.resolved is not drift-checked | maintainability | low | low | P3 | S | `the 2026-07-06 audit listed dependency pinning as healthy; that held for SwiftVLC and for Package.resolved, not for the SDK's manifest range` |
| 54 | L-35 | regen-project.yml retains a push trigger on a stale agent branch while holding contents: write | maintainability | low | low | P3 | S | — |
| 55 | L-36 | SettingsKeys.swift doc comments still place two settings rows in Appearance after they moved to Interface → Library | maintainability | low | low | P3 | S | `a new instance of the Q8 docs-drift class` |
| 56 | L-37 | Prior audit's duplication backlog is ~5% addressed, and the largest item now carries a correctness cost | maintainability | low | low | P3 | M | `D1, D2, D5 (2026-07-06) all still open; D3 confirmed fixed` |
| 57 | L-38 | Four superseded audit reports sit at the repo root and there is no README | maintainability | low | low | P3 | S | `Q6 and Q7 (2026-07-06), both still open` |
| 58 | L-39 | VLCStreamPresenter is a single 3,530-line class with ~146 stored properties and 34 platform-conditional regions | maintainability | low | low | P3 | L | — |

---

## Detail

### 1. `H-1` — MediaDetailScreen's Retry button can never recover — load() never clears errorMessage

- **Axes:** criticality `high` · importance `high` · priority `P0` · effort `S` · CONFIRMED
- **Area:** correctness
- **Where:** Shared/ViewModels/MediaDetailViewModel.swift:88 (write at :122); view branch Shared/Screens/MediaDetailScreen.swift:102-108; retry action :1329-1333
- **What & why:** `load()` sets `loadGeneration`, `isLoading = true` and then fetches; the catch at :122 writes `errorMessage = loc.userFacingMessage(for: error)`. Grep over the file shows exactly two occurrences of `errorMessage`: the declaration (:27) and that single write. There is no `errorMessage = nil` anywhere. The view's else-if chain is `isLoading` → `errorMessage` → `item`, so once the field is set, a successful retry populates `item` but the error branch still wins. Every other errorMessage-bearing view model in the codebase clears the field at load entry (HomeViewModel:121, MediaLibraryViewModel:182, LoginViewModel:157, ServerSetupViewModel:55, and all Admin VMs) — this is an outlier, not a design choice.
- **Impact:** Any user who opens a movie or series detail during a server hiccup is permanently stuck on the error screen for that push. Tapping Retry shows a spinner (isLoading flips true), the fetch succeeds, and the same error screen returns — which reads as "retry ran and failed again" and is actively misleading. The only escape is popping the screen and re-entering. This is the app's most-visited secondary screen, on both platforms.
- **Fix:** Add `errorMessage = nil` immediately after `isLoading = true` in `load()` — before the first await, so a superseded pass cannot clobber it. Consider the same at the top of `refreshAfterPlayback` for symmetry.

### 2. `H-2` — tvOS Search nests a vertical ScrollView inside a vertical ScrollView, so the results grid materialises every card at once

- **Axes:** criticality `high` · importance `high` · priority `P1` · effort `M` · CONFIRMED
- **Area:** performance
- **Where:** Shared/Screens/SearchScreen.swift:64-79 (outer) and :679-714 (SearchResultsGrid's own ScrollView)
- **Prior audit:** F-1 (2026-08-05), still open — unchanged in 1.2.0
- **What & why:** The tvOS branch wraps `VStack { searchField; filterChips; resultContent }.frame(minHeight: 720, maxHeight: .infinity)` in a ScrollView, and `resultContent` emits `SearchResultsGrid`, which opens its OWN vertical ScrollView around the LazyVStack/LazyVGrid. A vertical ScrollView nested in a vertical ScrollView receives a nil height proposal and reports its content's ideal height, so the inner viewport equals the full content and the LazyVGrid's laziness is defeated entirely. `LibrarySearchRanker.rank` fans out the phrase plus up to four significant words at `limit: 30` each (:143, :153), so a broad query unions up to 150 DTOs.
- **Impact:** On the A15 Apple TV a broad search instantiates ~150 SearchResultCards up front — each building a poster URL, a MediaDetailScreen destination (see L-16) and a Nuke request — instead of a screenful. The inner ScrollView also lacks `.scrollClipDisabled()`, unlike the equivalent grids in FavoritesScreen:192 and WatchedHistoryScreen:250; that half is cosmetic and largely unreachable given the grid never actually scrolls internally, but it is the same inconsistency.
- **Fix:** Give `SearchResultsGrid` a `wrapInScrollView: Bool` (or split into scrolling/non-scrolling variants) so on tvOS the LazyVStack/LazyVGrid render directly into the outer ScrollView, and drop the `minHeight: 720, maxHeight: .infinity` frame. Add `.scrollClipDisabled()` wherever an inner tvOS ScrollView is retained.

### 3. `M-1` — A server outage renders as "Your library is empty" / "No results", and Home latches hasLoaded so it never retries

- **Axes:** criticality `medium` · importance `high` · priority `P1` · effort `M` · CONFIRMED
- **Area:** correctness
- **Where:** Shared/Screens/HomeScreen.swift:61-71 and :223-236; Shared/ViewModels/HomeViewModel.swift:53, :118; Packages/CinemaxKit/Sources/CinemaxKit/Utils/PaginatedLoader.swift:43-47; Shared/Screens/MovieLibraryScreen.swift:376-379; Shared/Screens/Admin/Dashboard/AdminDashboardViewModel.swift:10,30-32
- **What & why:** Every phase-1 fetch in `HomeViewModel.load` swallows its error into `logger.warning(...) + return nil`; `errorMessage` is declared (:53) and cleared (:121) but never assigned, and HomeScreen contains zero references to it. An all-failed load therefore reaches `homeEmptyState`, whose strings are `empty.home.title` / `empty.home.subtitle` — literally "your library is empty / add movies or series to your Jellyfin server". Worse, `hasLoaded = true` is set at :118 BEFORE any fetch, so a fully-failed load latches the guard and re-entering the tab never retries (MediaLibraryViewModel does this correctly, latching only `if succeeded` at :103/:157). The same misdiagnosis exists in the filtered library grid: `PaginatedLoader.loadMore` catches and only resets `isLoadingMore`, with no failure record and no retry hook — and because `maybeLoadMore` is driven by the last card's `.onAppear`, a page-0 failure leaves zero cards and therefore no trigger to ever retry. AdminDashboardViewModel is a third instance: it writes `errorMessage` that no view reads, so both-fetches-failed shows empty cards with no message. `FavoritesViewModel` already carries the right pattern (a `loadFailed` flag explicitly so the view can drive an error state instead of the misleading empty state).
- **Impact:** The single most common failure mode of a self-hosted client — server down, VPN off, reverse-proxy cert expired — is reported to the user as a factual claim that their library is empty, with instructions to add media to their server. On Home it is sticky for the tab's lifetime. Diagnosis is impossible for the user, and the retry affordance that does exist (pull-to-refresh / the empty-state Refresh button) gives no reason to think it would help.
- **Fix:** Give HomeViewModel the `loadFailed` treatment FavoritesViewModel already has, set it when every phase-1 source failed, and branch to `ErrorStateView(message: loc.userFacingMessage(for:), retryTitle:)` ahead of the empty state; move `hasLoaded = true` behind success. Add a failure hook to PaginatedLoader so MediaLibraryScreen can distinguish empty from failed. Either wire AdminDashboardViewModel.errorMessage into its screen or delete it.

### 4. `M-2` — getItems — the hottest and fattest endpoint in the app — is the only uncached query in its file, and over-fetches on both axes

- **Axes:** criticality `medium` · importance `high` · priority `P1` · effort `M` · CONFIRMED
- **Area:** performance
- **Where:** Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Library.swift:124-166 (no cache), :156 (unconditional fields); Shared/ViewModels/MediaLibraryViewModel.swift:197-209 (hero limit 20, first item used)
- **Prior audit:** F-9 and F-16 and F-15 (2026-08-05), all three still open
- **What & why:** `getItems(...)` contains no `cache.get`/`cache.set`/`coalesce` — verified against the full cache-operation sweep of the file (hits at :33,45,66,81,102,116,175,203,232,236,281,288,325,330,344,349,366,378, none inside this function). All ten of its neighbours cache, including `getSeriesWithRecentEpisodes` added alongside it at TTL 60 s. It is also the fattest: `params.fields = [.overview, .genres, .childCount]` is unconditional, so every grid cell and genre-row item carries 300-1500 bytes of overview that only the hero reads. And the library hero fetch asks for `limit: 20` while consuming only `.items.first` and `.totalCount` — `totalRecordCount` is the pre-limit count, so `limit: 1` returns identical information.
- **Impact:** Byte-identical genre rows are re-downloaded on every browse re-entry, every reload and every tier-1 refresh; the browse layout alone is 1 hero + up to 8 genre `getItems` per load. Nothing can dedupe them because the TTL/coalescing layer is bypassed for this endpoint entirely. Consumers: Home Recently Added and Favorites, every Home genre row, library hero, every library genre row, every paginated page, getPersonItems, getCollections' fallback.
- **Fix:** TTL 30-60 s keyed on the COMPLETE argument tuple (parentId, types, sortBy, sortOrder, genres, years, isFavorite, filters, limit, startIndex, `getMaxContentAge()`) — Favorites and Watch History differ only by isFavorite/filters, so omitting either collides across screens — plus an `items-` entry in `userDataCachePrefixes` so the watched/favorite mutators sweep it. Make `.overview` opt-in for the hero query only, and drop the hero fetch to `limit: 1`.

### 5. `M-3` — Parental rating ceiling is enforced inconsistently: off by one category on server-filtered queries, and absent on every id-addressed read

- **Axes:** criticality `medium` · importance `medium` · priority `P1` · effort `M` · CONFIRMED
- **Area:** security
- **Where:** Packages/CinemaxKit/Sources/CinemaxKit/Models/ContentRatingClassifier.swift:58-67; JellyfinAPIClient+Library.swift:139 (getItems), :300 (searchItems), :214-249 (getItem, unfiltered); Shared/Intents/MediaItemQuery.swift:41; Shared/ViewModels/MediaDetailViewModel.swift:91,163
- **Prior audit:** S1 and S7 (2026-07-06), both still open; the intents surface is new since and inherits S7
- **What & why:** Two distinct gaps in one control. (a) `maxOfficialRatingCode(forAge:)` maps 11...12 → "PG-13" (whose own ageMap entry is 13) and 15...16 → "TV-MA" (age 17), while the client-side `passes(rating:maxAge:)` applies a strict `<= maxAge`. Jellyfin's `maxOfficialRating` is inclusive, so two of the five selectable ceilings admit exactly one category above themselves — and `getItems`/`searchItems` rely on that server code ALONE (neither calls `applyRatingFilter` on its results), whereas getResumeItems/getLatestMedia/getSimilarItems/getEpisodes/getNextUp/getPersonItems all apply the strict client filter. The two paths therefore provably disagree. (b) `getItem` applies no ceiling at all, so every id-addressed read is unfiltered: the detail screen (MediaDetailViewModel:91/163), a `cinemax://item/{id}` widget or Top Shelf deep link, and a saved Shortcut re-resolved through `MediaItemQuery.entities(for:)` all open an over-ceiling title. IntentSessionProvider.swift:81-84 explicitly claims the opposite ("Without it an intent would surface titles the app itself hides").
- **Impact:** A title Home's rails hide is browsable, searchable and openable, defeating the stated purpose of the setting. The ceiling has no PIN or any other lock, so this is a convenience filter rather than a security control — but its behaviour should at least be self-consistent, and the intent provider's doc comment currently overclaims.
- **Fix:** Map each ceiling to a rating whose own age is ≤ the ceiling (12 → "PG"/"TV-PG", 16 → "TV-14"), and update `ContentRatingClassifierTests.serverCode`, which currently pins the wrong mapping. Independently, apply `applyRatingFilter` to `getItems`/`searchItems` results the way `getPersonItems` already does, and decide explicitly whether the ceiling is a discovery filter (then fix the IntentSessionProvider comment) or a control (then filter `getItem` and the deep-link dispatcher too).

### 6. `M-4` — The end-of-series overlay leaves the player's 1 s heartbeat running indefinitely — progress POSTs, Now-Playing metadata and the server-side "watching" session never stop

- **Axes:** criticality `medium` · importance `high` · priority `P1` · effort `S` · CONFIRMED
- **Area:** correctness
- **Where:** Shared/Screens/VideoPlayer/VLCStreamPresenter.swift:3237-3263 (handlePlaybackEnded), overlay at :3266; timer writers at :544-545, :888-894, :2699; detach at :546
- **What & why:** `handlePlaybackEnded` ends with `reporter?.reportStop()`, `liveActivity.detach()`, then `showEndOfSeriesOverlay()` — which only presents a UIAlertController and keeps the view controller on screen. `progressTimer` has exactly three writers (teardown, startProgressTimer, navigateToEpisode's entry) and teardown is reachable only from `viewWillDisappear` when `isBeingDismissed`. So `onSecondTick` keeps firing: `reporter?.onTick()` (→ reportPeriodicProgress every 10 ticks, plus tickKeepAlive against a session that was just stopped), `nowPlaying.update(...)` every second, the sleep countdown, the skip-button refresh. `nowPlaying.detach()` also lives only in teardown, so MPNowPlayingInfoCenter keeps advertising the finished episode at its last written rate of 1.0. With `autoPlayNextEpisode` off, the guard at :3251 fails on EVERY episode end, not only the last one.
- **Impact:** After a series ends, the "You finished X" card sits over a live 1 s timer: an XPC write to mediaremoted every second and a `reportPlaybackProgress` POST every 10 s, indefinitely. The account shows as permanently "watching" in `/Sessions`, which is exactly what Home's admin-only Watching Now row renders. On an Apple TV left on overnight that is hours of wake-ups and requests against a self-hosted server, and the iPhone Lock Screen / Remote widget keeps showing a finished episode as playing.
- **Fix:** On the non-autoplay branch of `handlePlaybackEnded`, stop the heartbeat and detach the metadata controllers the way teardown does — `progressTimer?.invalidate(); progressTimer = nil; sleepActive = false; nowPlaying.detach()` — before `showEndOfSeriesOverlay()`. The dismiss branch is already covered by viewWillDisappear → teardown.

### 7. `M-5` — ThemeManager's four accent slots re-resolve the palette and allocate a dynamic UIColor on every read — twice per card

- **Axes:** criticality `medium` · importance `medium` · priority `P1` · effort `S` · CONFIRMED
- **Area:** performance
- **Where:** Shared/DesignSystem/ThemeManager.swift:113-158 (accent/accentContainer/accentDim/onAccent), :161 (colorScheme reads _accentRevision), :96-102 (rainbow task); Shared/DesignSystem/CinemaGlassTheme.swift:11-17; read sites Shared/DesignSystem/FocusScaleModifier.swift:24 and :32
- **Prior audit:** F-2 and F-3 (2026-08-05), both still open
- **What & why:** `palette` re-runs `AccentOption(rawValue: accentColorKey) ?? .green` on every read, and each accent slot returns a fresh `Color.dynamic(...)`, which allocates a `UIColor { traits in ... }` with a capture closure. `accentColorKey`'s getter additionally reads an `@AppStorage`-backed value (a UserDefaults lookup) and touches the observation registrar. `cinemaFocus()` reads `themeManager.accent` twice (border + shadow) and is applied by PosterCard, WideCard and LibraryPosterCard — i.e. every card in the app. Every `CinemaColor` token, by contrast, is a `static let` resolved once. Separately, `colorScheme` also reads `_accentRevision` and the root applies `.preferredColorScheme(themeManager.colorScheme)`, so while the rainbow accent easter egg is active its 100 ms hue task rebuilds the entire root tree at 10 Hz.
- **Impact:** A 48-card tvOS grid pass costs ~96 UIColor allocations plus ~192 UserDefaults reads. Diffuse rather than frame-killing — on the order of tens to low hundreds of microseconds per pass — but it is pure waste on the hottest path in the app, and the rainbow leg is a genuine 10 Hz root rebuild for anyone who unlocked the easter egg.
- **Fix:** Memoise the four resolved `Color`s in `@ObservationIgnored` stored properties, invalidated by the `accentColorKey` / `darkModeEnabled` setters and by each `_rainbowHue` step, and return the cached values. Decouple `colorScheme` from `_accentRevision` so the rainbow tick cannot invalidate the root.

### 8. `M-6` — "Recently Added" awaits its two sources sequentially in both copies, and the widget additionally fetches every poster one at a time inside WidgetKit's budget

- **Axes:** criticality `medium` · importance `medium` · priority `P1` · effort `S` · CONFIRMED
- **Area:** performance
- **Where:** Widgets/CinemaxWidget/CinemaxWidget.swift:143-145 (serial JSON) and :158-183 (serial poster loop); Shared/ViewModels/HomeViewModel.swift:151-160; timeouts JellyfinLite.swift:42,148,176,186,231
- **Prior audit:** F-7 (2026-08-05, marked "a empiré"), still open; the app-side copy was not previously reported
- **What & why:** The same two-source merge exists twice, once in the app and once in the widget's dependency-free copy, and both `await` source A fully before starting source B even though neither consumes the other (they are merged by the pure `mergeRecentlyAdded`). The widget then loops `for item in items { await JellyfinLite.fetchImage(...) }` with no TaskGroup, up to 7 posters on `.systemLarge`, each request bounded only by a 10 s inactivity timeout. In the app the offending task is one of four in the phase-1 TaskGroup whose drain gates `isLoading = false`, so it can decide time-to-first-paint.
- **Impact:** Widget worst case on a slow reverse-proxied origin is 2 JSON + 7 image round-trips strictly in series; WidgetKit's per-invocation budget is a few seconds, so the extension can be terminated before it ever calls the timeline handler and the widget keeps its previous entry with no error state. In the app the cost is one extra round-trip of Home skeleton latency on every cold load and pull-to-refresh.
- **Fix:** `async let` both JSON sources in each copy; fan the widget's poster loop out with a `withTaskGroup` bounded to 4 (the app's own discipline is 6), collecting into an index-keyed dict; lower `timeoutIntervalForRequest` in `JellyfinLite.session` to ~5 s. Note the fix must be applied twice — the widget links no CinemaxKit and only the app-side copy is covered by HomeViewModelTests.

### 9. `M-7` — Blocking getaddrinfo (twice) and a 2.5 s blocking recvfrom loop run on Swift's cooperative thread pool

- **Axes:** criticality `medium` · importance `medium` · priority `P1` · effort `M` · CONFIRMED
- **Area:** concurrency
- **Where:** Shared/Screens/VideoPlayer/CinemaxStreamProxy.swift:97-108 (nonisolated async), :115-123 and :125-149 (the two getaddrinfo calls); Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinServerDiscovery.swift:24-28, :78-100
- **Prior audit:** F-12 (2026-08-05), still open; the JellyfinServerDiscovery site was not covered by F-12
- **What & why:** `StreamTransportPolicy.refresh()` spawns a Task that awaits `shouldPreferProxy`, declared `nonisolated ... async`, so under SE-0338 it hops to the generic (cooperative) executor and then makes two synchronous blocking syscalls back to back with no queue hop. The condition being probed for is precisely "getaddrinfo hangs or fails slowly on this network" — the code's own comment at :98-104 says so. `probeTask?.cancel()` cannot interrupt a blocked syscall, so a superseding refresh does not free the thread. The file demonstrates the correct pattern one function below: `ipv6ResolvesQuickly` (:152-183) uses NWConnection on its own DispatchQueue bridged with `withCheckedContinuation`. `JellyfinServerDiscovery.discover` has the same shape via `Task.detached` (which also draws from the cooperative pool) around a `while Date() < deadline` recvfrom loop.
- **Impact:** One of the pool's ~5-6 threads is held for the resolver's timeout, re-armed on launch, on server change, on every `scenePhase == .active` and on every `network.isOnline` flip. That is queueing latency for unrelated awaits (playback negotiation, Home's genre fan-out), not a stall — but it is the only executor-blocking code in the codebase (verified: zero `DispatchQueue.global`/`.sync` sites elsewhere) and it is armed on exactly the networks where it blocks longest.
- **Fix:** Wrap both getaddrinfo helpers and `performDiscovery` in the same DispatchQueue + `withCheckedContinuation` shape already used by `ipv6ResolvesQuickly`, and add `withTaskCancellationHandler` so a superseding refresh stops waiting.

### 10. `M-8` — getCollections probes a 10.11-only endpoint speculatively (documented RULE deviation) and falls back to an unbounded, uncached recursive BoxSet scan

- **Axes:** criticality `medium` · importance `medium` · priority `P1` · effort `S` · CONFIRMED
- **Area:** correctness
- **Where:** Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Library.swift:510-541; contract at Packages/CinemaxKit/Sources/CinemaxKit/Models/ServerVersion.swift:5-9, :71
- **Prior audit:** F-17 (2026-08-05), still open
- **What & why:** CLAUDE.md states "RULE — server capability gating goes through `ServerVersion`, never a speculative request", and ServerVersion's own header names this exact call as the motivating case. The code still issues an unconditional hand-built `GET /Items/{id}/Collections` behind `try?`, eats the 404 on every pre-10.11 server, then falls back to `getItems(isRecursive: true, includeItemTypes: [.boxSet])` with no `limit`, no `startIndex`, and no cache read or write. The `try?` also swallows a 401 without `notifyIfUnauthorized`, while its sibling fallback does notify — an asymmetry that invites drift.
- **Impact:** Every movie detail open on a 10.10.x server pays a guaranteed wasted round-trip plus a full unbounded BoxSet scan, uncached, repeated per movie. It is off the render critical path (`loadCollection` is a detached side task by design), so the cost is diffuse rather than user-visible latency.
- **Fix:** Add `static let itemCollectionsEndpoint = ServerVersion(10, 11)` and gate the direct request on `serverSupports(...)` (unknown version ⇒ fallback, per the documented rule). Put a `limit` on the fallback scan and cache it under a `collections-` prefix. Route the direct request's error through `notifyIfUnauthorized` instead of a bare `try?`.

### 11. `M-9` — The iOS Home hero carousel's backdrops are never prefetched — the prefetcher's URLs don't match the hero's own request

- **Axes:** criticality `medium` · importance `high` · priority `P1` · effort `S` · CONFIRMED
- **Area:** performance
- **Where:** Shared/Screens/HomeScreen.swift:187-190 (prefetch at maxWidth 600), :555-560 (hero request at ImageURLBuilder.backdropPixelWidth), candidates :419-430, rotation :517-528
- **Prior audit:** F-32 (2026-08-05), still open
- **What & why:** `prefetchCardImages` warms continue-watching/next-up backdrops at `maxWidth: 600`, while the hero requests `maxWidth: ImageURLBuilder.backdropPixelWidth` (1179/1290/1920 depending on device). Nuke keys on the URL, so nothing warmed is ever reused — and the method's own doc comment (:170-174) states the invariant being violated: "URLs mirror the cards' own requests exactly (same maxWidth + tag) — a parameter mismatch would warm a different cache entry". `latestItems` backdrops are not prefetched at all (only their 2:3 posters).
- **Impact:** Heroes 2-5 of the auto-advancing carousel start a cold download at the moment they crossfade in, showing the plain surface colour on the single most-looked-at region of the app — precisely the flash the `hasBackdropImage` guard on candidates 2-5 exists to prevent. Intermittent (a LAN fetch can beat the 0.6 s crossfade) but on every Home visit with two or more candidates.
- **Fix:** Add a third prefetch pass over `heroCandidates` building the URL with identical parameters to the hero's (`.backdrop`, `ImageURLBuilder.backdropPixelWidth`, `item.backdropImageTagValue`).

### 12. `M-10` — .cinemaxSessionExpired is posted off the main actor and its onReceive handler reads MainActor state before hopping

- **Axes:** criticality `medium` · importance `medium` · priority `P1` · effort `S` · CONFIRMED
- **Area:** concurrency
- **Where:** Shared/Navigation/AppNavigation.swift:96-98 (post) and :1045-1053 (observe); Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient.swift:168-170
- **Prior audit:** B1 (2026-07-06), still open — listed as a P0 item in that audit's queue
- **What & why:** `setOnUnauthorized` posts the notification directly, and `notifyIfUnauthorized` invokes it on whatever executor the failing async call resumed on (JellyfinAPIClient is a plain Sendable final class, so its methods are nonisolated). NotificationCenter delivers synchronously on the posting thread and Combine's publisher forwards there, with no `.receive(on:)` on the pipeline — so the closure's first statement, `guard appState.isAuthenticated else { return }`, a read of @MainActor-isolated @Observable state, executes on a cooperative-pool thread. The code's own comment at :91-95 claims the opposite ("Bridge through NotificationCenter — AppNavigation listens on MainActor"). Scoping datum: of the 19 `.cinemax*` post sites in the app, this is the only one outside a @MainActor type, so one fix closes the class.
- **Impact:** An unsynchronised read of main-actor state on the one path that can sign a user out. The subsequent `Task { }` carries static MainActor isolation, so `handlePossibleSessionExpiry` itself runs correctly — the damage is bounded to the guard read (a word-sized load, benign in practice on arm64) plus a registrar access from the wrong context. It is a real Swift 6 strict-concurrency violation, reportable under TSan, on a security-relevant path.
- **Fix:** Post from inside `Task { @MainActor in ... }` in the `setOnUnauthorized` closure — preferable to `.receive(on:)` because it fixes every current and future consumer at the source.

### 13. `M-11` — The SwiftLint CI gate is decorative — `continue-on-error: true` means `--strict` can never fail a PR, and the test suite is excluded from linting entirely

- **Axes:** criticality `medium` · importance `medium` · priority `P1` · effort `S` · CONFIRMED
- **Area:** compliance
- **Where:** .github/workflows/ci.yml:98-102; .swiftlint.yml:36-42 (excludes Tests), :14 (empty_xctest_method)
- **Prior audit:** Q1 (2026-07-06, rated High and queued), still open verbatim
- **What & why:** The lint job runs `swiftlint --strict --quiet` and then declares `continue-on-error: true`, converting any failure to a green check. `.swiftlint.yml` opts into 23 rules and sets force_unwrapping/force_cast/force_try to `warning`, which `--strict` promotes to errors — the job is configured to be meaningful and then neutered. `excluded:` also lists `Tests`, so the entire 36-file suite is unlinted and the opted-in `empty_xctest_method` rule (which can only ever fire on test code) is permanently dead. Secondary: `brew install swiftlint` is unpinned, the exact per-runner coin-flip problem the adjacent xcodegen step documents at length and solves with a pinned release artifact (ci.yml:27-40).
- **Impact:** The only style/quality gate in CI reports success unconditionally; every reviewer and every agent reading a green check believes lint passed. This is the enforcement half of the theme running through this audit — several documented RULEs are maintained by discipline alone because the mechanisms that would catch drift are switched off.
- **Fix:** The codebase is already close to clean (4 force unwraps total across Shared/, Packages/CinemaxKit/Sources/, Widgets/ and TopShelf/; zero `try!`/`as!`), so fix those, then delete `continue-on-error: true`. Pin SwiftLint via a release artifact + `SWIFTLINT_VERSION` env the way xcodegen is pinned, and drop `Tests` from `excluded:`.

### 14. `M-12` — No rail, genre row or poster card is Equatable, so every progressive-load write re-renders every already-materialised card

- **Axes:** criticality `medium` · importance `medium` · priority `P2` · effort `M` · CONFIRMED
- **Area:** performance
- **Where:** Shared/ViewModels/MediaLibraryViewModel.swift:296-299 (8 incremental itemsByGenre writes); Shared/Screens/MovieLibraryScreen.swift:319-340; Shared/Screens/LibraryGenreRow.swift:13 (stored closure); Shared/Screens/LibraryPosterCard.swift:31; Shared/Screens/HomeScreen.swift (grep -c Equatable = 0)
- **Prior audit:** F-20 and F-22 (2026-08-05), both still open
- **What & why:** `fetchGenreItems` writes `itemsByGenre[genre]` once per completed genre (up to 8, chunked at 6) — which is documented-deliberate progressive rendering and must NOT be batched away. The actionable half is that `LibraryGenreRow` and `LibraryPosterCard` are not Equatable and store function-typed properties (`let onViewAll: () -> Void`), and the call site constructs fresh closures each pass; a freshly-allocated closure context is never structurally equal, so no row or card can ever short-circuit. HomeScreen has zero Equatable extractions at all. The codebase already carries the correct recipe in `MediaDetail*Section`, `MediaDetailEpisodeCard/Row` and `SearchResultCard` (nonisolated `==` ignoring closures, DTO reads wrapped in `MainActor.assumeIsolated`).
- **Impact:** Each of the 8 genre writes re-runs the body of every previously-rendered row and visible card — image-URL construction, subtitle formatting, CardMenuItem extraction, plus the eager MediaDetailScreen construction of L-16. Roughly 400 card-body evaluations during a single library browse load on the A15. Bounded to load sequences, not steady-state scrolling.
- **Fix:** Make `LibraryGenreRow` and `LibraryPosterCard` `View, Equatable` with a `nonisolated static func ==` comparing id/name/tag/userData and ignoring the closures, apply `.equatable()`, and do the same for HomeScreen's rails.

### 15. `M-13` — MediaDetailScreen's LazyVStack has only two children, so cast, episodes, collection and similar carousels are all built eagerly on open

- **Axes:** criticality `medium` · importance `medium` · priority `P2` · effort `M` · CONFIRMED
- **Area:** performance
- **Where:** Shared/Screens/MediaDetailScreen.swift:192-199; eager VStack at :243-250; sections at :298-327; backdropHeight :1337-1343
- **Prior audit:** F-24 (2026-08-05), still open
- **What & why:** The LazyVStack contains exactly `backdropSection(item)` and `belowHeroContent(item)`, and the latter resolves to an eager `VStack` holding both column groups. Since the tvOS backdrop is 760 pt against a 1080 pt viewport, the second child intersects the visible rect on first layout and is materialised immediately — taking the whole eager VStack with it, including each carousel's own horizontal ScrollView/LazyHStack, which then materialises its first screenful and fires its Nuke requests.
- **Impact:** Opening any detail screen immediately builds ~15-20 off-screen cards and starts their image downloads, contending with the backdrop fetch at exactly the moment the user is waiting for the hero. The images are mostly wanted eventually, so this is contention rather than pure waste — but it is on every detail open, on both platforms.
- **Fix:** Emit the sections as direct children of the LazyVStack (the pattern `HomeScreen.content` already uses at :255-340) rather than wrapping them in an eager VStack; keep the iPad two-column HStack as the one exception.

### 16. `M-14` — tvOS ships with zero automated test execution — no tvOS test target, and CI only builds the tvOS scheme

- **Axes:** criticality `medium` · importance `medium` · priority `P2` · effort `M` · CONFIRMED
- **Area:** testing
- **Where:** project.yml:209 (`testTargets: []`), :308-310 (CinemaxTests is platform: iOS); .github/workflows/ci.yml:65-75 (iOS test) vs :77-87 (tvOS build only)
- **Prior audit:** Q3 (2026-07-06), still open verbatim
- **What & why:** `CinemaxTV.scheme.testTargets` is empty and the only test bundle targets iOS, so no test runs on tvOS. The tvOS build job does compile and type-check every `#if os(tvOS)` branch, so the gap is behavioural, not syntactic — but that is exactly where the risk is: CLAUDE.md documents a long series of tvOS-only defects that shipped and were fixed after the fact (the Menu-peel infinite loop, the `hiddenHUDIntent` press whitelist, the stats-panel dead zone, the focus-position tab remount, the tab-bar pill alignment heuristic). None of that logic is exercised by any test; `hiddenHUDIntent(for:)` is a `private static` inside a `#if os(tvOS)` region on the view controller and is untestable as written.
- **Impact:** tvOS is a co-equal shipped platform carrying the highest-churn, highest-regression-density code in the repo, and its only regression net is manual on-device recette — which is demonstrably how these bugs have been found. Invert the whitelist in `hiddenHUDIntent` and both CI jobs still pass.
- **Fix:** Add a `CinemaxTVTests` bundle (`platform: tvOS`, depending on `CinemaxTV`), wire it into `CinemaxTV.scheme.testTargets`, and add an `xcodebuild test` step for the tvOS scheme. Seed it with the pure tvOS logic that already has regression history: `hiddenHUDIntent`, the Menu-peel decision keyed on `controlsContainer.alpha`, and TVScrubBar's incremental-translation accumulation — which means extracting them out of the view controller first.

### 17. `M-15` — Every "app-private" Keychain item is actually written into the shared extension access group, including tokens for all registered servers

- **Axes:** criticality `medium` · importance `medium` · priority `P2` · effort `M` · CONFIRMED
- **Area:** security
- **Where:** Packages/CinemaxKit/Sources/CinemaxKit/Persistence/KeychainService.swift:362 (save), :379 (getData), :394 (delete), :307 (getOrCreateDeviceID); iOS/Cinemax.entitlements:9-12 and the three siblings, from project.yml:74-75/174-175/225-226/263-264
- **What & why:** The private read/write/delete helpers set kSecClass/kSecAttrService/kSecAttrAccount/kSecAttrAccessible and never kSecAttrAccessGroup. When `keychain-access-groups` is present, an item added without an explicit group lands in the FIRST entry of that list — here the only entry, `$(AppIdentifierPrefix)com.cinemax.shared`, which both extensions hold. So `access_token`, `user_session`, `server_url`, `servers` (a JSON array carrying an access token for EVERY registered server), `active_server_id` and `device_id` all live in the shared group, contradicting the file's own contract (:7 "App-private Keychain storage", :173-174) and CLAUDE.md's "two new **app-private** Keychain accounts … (never the shared extension group)".
- **Impact:** A compartmentalisation failure, not a third-party exposure: the readers are this project's own two extensions, signed with the same team. The delta over what is deliberately shared (the single active-session snapshot at `extension_session`) is the non-active servers' tokens plus device_id and server_url — i.e. the design's stated boundary is simply not in force, and any code added to an extension inherits access it was never meant to have. Reads and deletes are group-agnostic, which is why nothing broke and nobody noticed.
- **Fix:** Add `kSecAttrAccessGroup` = the app-identifier group to `save`/`getData`/`delete` and the device-id queries. Because existing installs already wrote items into the shared group and the readers are unscoped, this needs a read-then-migrate, not a bare writer change — adding the attribute to writers alone would silently sign users out. Then lock it: extend ExtensionSessionContractTests with a signed-build assertion that `extension_session` is in the shared group and `access_token`/`servers` are not.

### 18. `M-16` — Native-path audio track switch orphans the previous server session (live stream + transcode job) and reports against a session the server never saw start

- **Axes:** criticality `medium` · importance `medium` · priority `P2` · effort `S` · CONFIRMED
- **Area:** correctness
- **Where:** Shared/Screens/NativeVideoPresenter.swift:470-505 (switchTracks); helper that exists but is unwired here at :772-789; correct sibling at Shared/Screens/VideoPlayer/VLCStreamPresenter.swift:3530
- **Prior audit:** F-28 fixed for the VLC wake path; this is the same class on an untouched path
- **What & why:** `switchTracks` negotiates a fresh `getPlaybackInfo` and assigns `self.playbackInfo = info`, dropping the previous one with no `closeLiveStream`/`stopEncoding` and no `reportStop`. `getPlaybackInfo` always sends `isAutoOpenLiveStream = true` (JellyfinAPIClient+Playback.swift:91), so each negotiation opens a server-side live stream and, on a transcode, an ffmpeg job. `releaseServerSessionAfterFailure` exists in this very file but is wired only to the terminal error path; the VLC sibling does the right thing for the same shape of mutation. No `reportPlaybackStart` is issued for the incoming session either, so the server receives progress reports for a playSessionId it never saw begin, and the outgoing session's final position is never recorded.
- **Impact:** Each language switch leaves another orphaned job competing for the server's CPU, which makes the NEW stream stutter — the same defect class as the already-fixed F-28, on a path that lot never visited. Multi-audio items (FR/EN) are exactly the ones users switch on. Bounded by the native player being opt-in (`forceNativeAVPlayer` defaults false).
- **Fix:** Factor `releaseServerSessionAfterFailure` into `releaseServerSession(_ stale: PlaybackInfo)` taking the info explicitly (as VLCStreamPresenter already does), capture the outgoing info before overwriting, and call it. Add the missing stop/start reports. Worth a one-off sweep of all four sites that overwrite a PlaybackInfo — navigateToEpisode ×2, reResolveAndResume, switchTracks — only this one is wrong today.

### 19. `M-17` — KeychainService's single write path is destructive delete-then-add with no rollback, and every caller of it swallows the failure

- **Axes:** criticality `medium` · importance `low` · priority `P2` · effort `M` · CONFIRMED
- **Area:** correctness
- **Where:** Packages/CinemaxKit/Sources/CinemaxKit/Persistence/KeychainService.swift:362-377 (save), :120-122 (saveServers), :133-139 (saveActiveServerId uses try?), :227-243 + :248-273 (migration excludes device-id from allSucceeded); Shared/Navigation/AppNavigation.swift:328-338; Shared/ViewModels/LoginViewModel.swift:112-147
- **Prior audit:** S2 and S5 and B11 (2026-07-06), all still open; S2's scope has since grown to the registry
- **What & why:** `save(data:for:)` deletes first, then `SecItemAdd`s, and throws on failure — there is no `SecItemUpdate` anywhere. Every credential goes through it, including the whole multi-server registry (`saveServers`). No caller acts on the throw: `persistRegistry` logs and then calls `saveActiveServerId` unconditionally (which itself swallows with `try?`), and `LoginViewModel.completeSession` logs and continues straight to `isAuthenticated = true`, so a login can visibly succeed while nothing persisted and the next cold launch lands on LoginScreen with no explanation. Separately, `migrateAccessibilityIfNeeded` excludes the device-id rewrite from its `allSucceeded` test and that rewrite is itself a delete-then-add with both statuses discarded, so the one-shot flag can latch while `device_id` is stale or destroyed — after which nothing retries, and the connected-devices screen's "THIS DEVICE" guard matches no row, making the user's own live session revocable.
- **Impact:** Latent rather than demonstrated: all writers run from foreground user-driven paths under `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and I could not construct a state where a successful read is followed by a failed add. But the blast radius has grown — one failed write now silently deletes the entire server registry, and `saveServers`' doc comment asserts an atomicity the implementation does not provide.
- **Fix:** Make `save` try `SecItemUpdate` first (both kSecAttrAccessible and kSecValueData are updatable) and fall back to delete+add only when the item is absent; or write to a temp account and swap. Fold the device-id rewrite into `allSucceeded`. Surface a persistence failure to the user on the login path ("session could not be saved") instead of only logging.

### 20. `L-1` — Loopback proxy pipes raw wire text into URLComponents.percentEncodedPath/Query, which raises on malformed percent-encoding

- **Axes:** criticality `medium` · importance `low` · priority `P2` · effort `S` · PLAUSIBLE
- **Area:** security
- **Where:** Shared/Screens/VideoPlayer/CinemaxStreamProxy.swift:230-238 (url(forRest:)), :478-496 (route, query unvalidated), :511-515 (isSafeComponent falls back to raw text)
- **What & why:** `rest` and `query` come verbatim off the loopback socket and are assigned to the `percentEncoded*` setters, which Apple documents as raising for an incorrectly percent-encoded string — an uncatchable abort from Swift. `isSafeComponent` explicitly tolerates a malformed escape: `removingPercentEncoding` returns nil for `a%ZZ`, the code falls back to the raw text, finds no separator, and admits it. `query` gets no validation at all.
- **Impact:** A hostile or malfunctioning origin whose HLS manifest names a child `main%ZZ.m3u8` can terminate the app mid-playback. Blind loopback probing cannot reach it (the UUIDv4 target lookup runs first), and an origin that can serve arbitrary manifest bodies already owns the content path, so added harm is small.
- **Fix:** Reject any component whose `removingPercentEncoding` is nil, and validate `query` against the RFC 3986 query set, in `route` — which is already the pure, unit-tested chokepoint. Or assemble the absolute string and use `URL(string:)`, which returns nil rather than raising. Add `%ZZ`/`#`/`{}` cases to StreamProxyTests.

### 21. `L-2` — Chapter thumbnails fire as one batch during the stream-open window on the native tvOS path — the deferral the VLC path received was never applied

- **Axes:** criticality `medium` · importance `low` · priority `P2` · effort `S` · CONFIRMED
- **Area:** performance
- **Where:** Shared/Screens/VideoPlayer/ChapterController.swift:57-78 (unchunked withTaskGroup, inside #if os(tvOS)); call sites Shared/Screens/NativeVideoPresenter.swift:325-330 and :597-602, both immediately after avPlayer.play(); correct pattern at VLCStreamPresenter.swift:2020-2052
- **Prior audit:** F-5 (2026-08-05) — VLC half fixed, native half explicitly deferred and still open; also P6 (2026-07-06)
- **What & why:** `fetchAndApply` adds one task per chapter with no chunking and is invoked synchronously after `play()`, i.e. exactly while AVKit is negotiating and pulling the first segments. The VLC path solved this with `pendingChapterThumbnails`, released by `noteMediaOpened()`, and CLAUDE.md documents the reasoning verbatim. Concurrency is not actually unbounded — `loadImage` routes through AuthenticatedImageFetch → `ImagePipeline.shared.data(for:)`, and Nuke 12.9.0 bounds its dataLoadingQueue at 6 — so the real shape is ~30 requests draining 6 at a time alongside the opening stream.
- **Impact:** Time-to-first-frame the user waits through on a self-hosted or reverse-proxied server, repeated on every episode navigation. Gated on tvOS AND the opt-in native player AND items with extracted chapter images, so it is off the default path for essentially all users.
- **Fix:** Chunk the fan-out to 6 like every other fan-out in the app, and defer the batch behind `.readyToPlay` or the first periodic tick (the presenter already owns a 1 s observer); apply markers incrementally as chunks land.

### 22. `L-3` — Proxy target map keeps a previous user's live access token after an in-app user switch, and is never pruned at playback teardown

- **Axes:** criticality `medium` · importance `low` · priority `P2` · effort `S` · CONFIRMED
- **Area:** security
- **Where:** Shared/Screens/VideoPlayer/CinemaxStreamProxy.swift:269 (targets holds a token), :316-320 (written), :337-338 (cleared only in stop()); Shared/Screens/VideoPlayer/CinemaxStreamProxy.swift:51-57 and Shared/Navigation/AppNavigation.swift:943,968 (configure keys on serverURL alone)
- **What & why:** `targets` maps `/s/<uuid>` → (origin, token) and is cleared only by `stop()`, which runs only when `StreamTransportPolicy.configure` is called with a nil serverURL. `UserSwitchSheet` re-authenticates a different account against the SAME server URL, so `changed == false` and nothing clears the map. Up to six registrations keep the previous user's still-valid token, and the listener will replay it upstream as `Authorization: MediaBrowser Token=` to whoever presents the matching path. Registrations also outlive the stream they were minted for, for the whole session.
- **Impact:** Credential-lifetime hygiene rather than a live hole: exploitation needs a UUIDv4 guess against a random loopback port from a co-resident process, and the map is LRU-bounded to 6. The `.sessionExpired` variant is benign (that token is revoked).
- **Fix:** Add `clearTargets()` and call it whenever credentials change — the simplest hook is to key `StreamTransportPolicy.configure` on `(serverURL, currentUserId)` and to clear unconditionally in `logout(reason:)`; the listener can stay warm. Also drop a stream's registration at presenter teardown.

### 23. `L-4` — Loopback listener accepts connections with no idle timeout and no concurrency cap, and is warmed for the whole session

- **Axes:** criticality `medium` · importance `low` · priority `P2` · effort `S` · CONFIRMED
- **Area:** security
- **Where:** Shared/Screens/VideoPlayer/CinemaxStreamProxy.swift:390-409 (accept/readRequestHead), :358-360 (NWParameters, no connectionIdleTimeout), :331-344 (stop is the only reaper), :58 (prestart on every configure)
- **What & why:** `readRequestHead` recurses on `conn.receive(minimumIncompleteLength: 1, ...)` whose only exits are the CRLFCRLF terminator, an error, isComplete, or a 64 KB cap. A peer that connects and never terminates the head holds an NWConnection and a pending receive indefinitely — classic slowloris. `NWListener.newConnectionLimit` is never set, so there is no concurrency bound either, and `prestart()` keeps the listener exposed for the entire app session even for users who never take the proxy path.
- **Impact:** Confined to the app's own process (fd/memory exhaustion degrading its networking); not a disclosure path, since admission and the UUID gate still hold, and the attacker must already be co-resident.
- **Fix:** Arm a per-connection deadline in `accept` (cancelled once `forward` runs) and keep a live-connection counter under `stateLock`, refusing past a small bound (16 is generous — libVLC opens one per Range). Optionally defer `prestart()` to the first playback that needs the proxy.

### 24. `L-5` — Proxy listener bring-up has no ownership guard on either terminal branch, so a superseded listener can publish its port or free the gate

- **Axes:** criticality `medium` · importance `low` · priority `P2` · effort `S` · CONFIRMED
- **Area:** concurrency
- **Where:** Shared/Screens/VideoPlayer/CinemaxStreamProxy.swift:351-384 — `.ready` branch :371-374 (no guard at all), `.failed/.cancelled` branch :375-380 (guards listener/listenerPort but not listenerStarting)
- **What & why:** The admission gate is `listenerPort != nil || listenerStarting`. A previous listener's terminal callback clears `listenerStarting` unconditionally even when it is no longer current, so during a stop→prestart window a `localURL(for:)` miss can pass the gate and mint a third listener, overwriting the only strong reference to the second — which then reaches `.ready` and stays bound for the process's life, unreachable by `stop()`. The `.ready` branch is the more damaging half: it writes `listenerPort = port` with no `listener === l` test at all, so a superseded listener can publish ITS port as the live one while `listener` holds a different object.
- **Impact:** A stray bound loopback socket, or loopback URLs minted against an orphan port. Same admission checks and same targets map apply, so it is not an exposure. The window is milliseconds and requires a logout → different-server → immediate-playback sequence.
- **Fix:** Wrap both branches in `guard self.listener === l` so only the current generation can clear the gate or publish a port.

### 25. `L-6` — The VLC path — the default engine — never reports progress when the app backgrounds

- **Axes:** criticality `low` · importance `medium` · priority `P2` · effort `S` · CONFIRMED
- **Area:** correctness
- **Where:** Shared/Screens/VideoPlayer/VLCStreamPresenter.swift:3453-3465 (handleDidEnterBackground); the method exists at Shared/Screens/VideoPlayer/PlaybackReporter.swift:119 and is called only from Shared/Screens/NativeVideoPresenter.swift:911-920
- **What & why:** `handleDidEnterBackground` records `didBackgroundWhilePlaying`, `positionAtBackgroundMs` and `backgroundedAt`, but never calls `reporter?.reportBackgroundProgress()`. Grep confirms the method has exactly two references: its definition and the native presenter's observer. The asymmetry is the whole finding — the opt-in engine gets the fresh position, the default engine does not.
- **Impact:** If the OS terminates the suspended app (routine on tvOS after launching another app), the server's last known position is whatever the 10-tick progress cadence happened to record — up to ~10 s stale — and no stop report is ever sent. Bounded: a foreground return re-resolves via `handleDidBecomeActive`, a normal dismiss sends a full reportStop, and on iOS with PiP/background audio the process is not suspended at all.
- **Fix:** Call `reporter?.reportBackgroundProgress()` at the top of `handleDidEnterBackground` (it already reports `isPaused: true`, which is the right semantics). Optionally also fire `reportStop()` on `willTerminateNotification`.

### 26. `L-7` — Cache is never cleared on logout or on connectToServer, and `serverInfo` has no server discriminator

- **Axes:** criticality `low` · importance `medium` · priority `P2` · effort `S` · CONFIRMED
- **Area:** security
- **Where:** Shared/Navigation/AppNavigation.swift:606-662 (logout touches apiClient nowhere); Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient.swift:190-213 (connectToServer), :246-283 (authenticate), :217-243 (serverInfo key, TTL 600, re-seeds version on the hit path)
- **Prior audit:** B3 (2026-07-06) → F-13 (2026-08-05), still open on its third report; the logout leg is new
- **What & why:** Every other transition that repoints the client clears the cache (`reconnect` at :374-375, `applyActiveServer` at AppNavigation:387-388, `applyContentRatingLimit`), but `logout(reason:)` and `connectToServer`/`authenticate` do not. So the departing user's resume list, item DTOs, similar and genre lists stay resident while the app sits on LoginScreen, and a same-user re-login inside the TTLs (10 s item/episodes/seasons/nextup, 30 s resume, 60 s latest, 300 s genres/similar) is served pre-logout state. The `serverInfo` key is the one undiscriminated key in the cache and its hit path re-seeds `setServerVersion(cached.version)`, so a future call site in the add-server flow would stamp server A's version onto server B's client and mis-gate a capability.
- **Impact:** Not a disclosure: APICache is in-memory only, nothing is persisted, and every other key carries userId plus a server-specific item GUID so cross-user and cross-server bleed are structurally impossible. The functional consequence is stale data on a fast re-login, and a latent capability-gating hazard one call site away. The `.userInitiated` logout that hops to another server does clear (via reconnect); the no-candidate and `.sessionExpired` branches do not.
- **Fix:** Add `apiClient.clearCache()` to `logout()` alongside `keychain.clearAll()`, add `cache.clear()` right after `setClient` in `connectToServer`, and key the entry `serverInfo-<normalizedURL>`. Three one-liners.

### 27. `L-8` — VLC chapter and trickplay images are cached in Nuke under a URL containing the access token, and the shared helper's contract claims the opposite

- **Axes:** criticality `low` · importance `medium` · priority `P2` · effort `S` · CONFIRMED
- **Area:** performance
- **Where:** Shared/Screens/VideoPlayer/VLCStreamPresenter.swift:2125-2127 and :114-123 (authedURL); Shared/Screens/VideoPlayer/TrickplayController.swift:162-163; false claim at Shared/Screens/VideoPlayer/AuthenticatedImageFetch.swift:24-26; correct native path at Shared/Screens/VideoPlayer/ChapterController.swift:139-140
- **Prior audit:** F-41 (2026-08-05) — half fixed (chapters now ride the disk cache); the token-in-key half persists and the fix introduced the false claim
- **What & why:** The VLC path appends `api_key` to the URL before handing it to `AuthenticatedImageFetch`, which also sets the `Authorization` header — so the query item is redundant here (this fetch goes through URLSession/Nuke, not libVLC, so authedURL's header-injection rationale does not apply). Nuke keys on the URL, so the token becomes part of the cache key. The helper's doc comment states "Chapter/artwork URLs carry no token", which is false for the default engine on both platforms. The native path passes the bare builder URL, so the two engines cache identical bytes under different keys.
- **Impact:** Every token rotation (re-login, user switch, session-expiry recovery, Quick Connect) orphans the whole chapter + trickplay cache for every item — ~23 MB of trickplay sheets per film re-downloaded — which is exactly the cost AuthenticatedImageFetch was introduced to remove. Toggling the player engine stores each thumbnail twice. No at-rest token exposure: Nuke hashes the cache key into the filename.
- **Fix:** Drop `authedURL` from `VLCStreamPresenter.loadImage` and `TrickplayController.loadTile` so both engines share a stable token-free key, and correct the doc comment either way — it is the only contract statement covering three call sites.

### 28. `L-9` — PlaybackInfo.authToken is deliberately nil on the transcode path, silently de-authenticating chapter, trickplay and artwork fetches

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · PLAUSIBLE
- **Area:** correctness
- **Where:** Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Playback.swift:220 (transcode branch) vs :266 (direct branch); consumers Shared/Screens/VideoPlayer/VLCStreamPresenter.swift:1992 and :497, Shared/Screens/NativeVideoPresenter.swift:328,601
- **What & why:** The transcode branch returns `authToken: nil` with the comment "token already embedded in Jellyfin's HLS URL" — correct for the stream, but three consumers use the same field as a general-purpose API token for image fetches. `AuthenticatedImageFetch.data(from:token:)` omits the header when the token is nil and `authedURL` is a no-op, so those requests go out with no credential at all. One field, two meanings.
- **Impact:** On a transcoded item the chapter-thumbnail, trickplay-tile and now-playing-artwork requests are unauthenticated. Jellyfin's item image endpoints are anonymous so posters survive; whether the trickplay endpoint rejects anonymous requests could not be verified without a server, so the concrete symptom (silently missing scrub previews on transcoded items) is asserted, not demonstrated.
- **Fix:** Add a separate always-populated `apiToken` field on PlaybackInfo, leaving `authToken` as the stream-only credential — or thread the client's token into the presenters independently for the three image consumers.

### 29. `L-10` — The seek-heavy forced-transcode re-negotiation orphans one PlaybackInfo session per playback start, in either direction

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** correctness
- **Where:** Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Playback.swift:180-199; first POST at :103-108 with isAutoOpenLiveStream at :87
- **What & why:** When the response reveals a seek-heavy container, the function re-POSTs with `forceTranscode: true` and returns whichever negotiation wins. Neither branch closes the loser: on success the first negotiation's playSessionID/liveStreamID are dropped, and when the retry does not yield `.transcode` the SECOND negotiation is discarded unreleased. The caller only ever holds the returned PlaybackInfo, so no stop report will ever reference the orphan.
- **Impact:** One abandoned live stream (and on the retry, an encoding job) per affected playback. Narrow: the up-front container check normally decides before the first POST, so this is now only the fallback for items whose `getItem` carried no media source or container.
- **Fix:** Capture the first response's playSessionID/liveStreamID before re-negotiating and fire `closeLiveStream` + `stopEncoding` on whichever negotiation is discarded.

### 30. `L-11` — Transparent proxy reconnect assumes the origin honoured the Range; a 200 response makes the resume offset overshoot and splice corrupt bytes

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** correctness
- **Where:** Shared/Screens/VideoPlayer/CinemaxStreamProxy.swift:762-765 (reconnect), :445 (rangeStart from the request header only), :782-794 (sendHead never records the status), :690-701 (only the reconnect's status is validated)
- **Prior audit:** Q3 (2026-07-06) flagged parseRange and the reconnect budget as untested — still untested
- **What & why:** `resumeFrom = rangeStart + bytesDelivered` assumes `bytesDelivered` counts from `rangeStart`. If the origin ignored `Range` and answered 200 with the whole entity, it counts from 0 and the resume overshoots by `rangeStart`, splicing those bytes into the same loopback connection with no head — libVLC sees a silently corrupt feed rather than a clean close it could recover from.
- **Impact:** Narrow, because the reconnect's own `guard status == 206` bails to a clean close: an origin that ignores Range once will usually ignore it again and never splice. Corruption needs an inconsistent cache/proxy tier that honours Range on the retry but not the first request.
- **Fix:** Record the original response's status and Content-Range in `didReceive response`, set a `resumable` flag only when it was a 206 starting at `rangeStart` (or a 200 with `rangeStart == 0`), and gate `reconnect()` on it. While there, add unit tests for `parseRange` and the reconnect budget — the doc comment cites them as the pure/testable precedent but StreamProxyTests covers only route/admission/isLoopbackHost.

### 31. `L-12` — Two unclamped Double→Int32 conversions on server-supplied tick values can trap

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** correctness
- **Where:** Shared/Screens/VideoPlayer/VLCStreamPresenter.swift:1043 (skipSegmentTapped, segment.endTicks) and :2009 (fetchChapters, startSec); clamping precedents in the same file at :3589 and :2116
- **What & why:** Both use the non-clamping `Int32(Double)` initialiser on values derived straight from server JSON, while the file elsewhere documents this exact hazard and uses `Int32(clamping:)` with the comment "traps on overflow if a corrupt resume tick yields a huge position".
- **Impact:** A tick value above ~2.15e13 (≈25 days of runtime) crashes the player outright — a hard trap, not an exception. Only reachable with corrupt or hostile server metadata, and the intro/outro site additionally requires the Intro Skipper plugin. `fetchChapters` runs on every playback start of an item with chapters.
- **Fix:** `Int32(clamping: Int(...))` on both lines.

### 32. `L-13` — Two seek entry points bypass the documented pending-target / coalescing path

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** correctness
- **Where:** Shared/Screens/VideoPlayer/VLCStreamPresenter.swift:3042-3049 (iOS scrubberDone, no pendingScrubTargetMs) and :1042-1049 (skipSegmentTapped, direct userEngineSeek); correct tvOS commit at :1751-1767; chapter path at :2116
- **What & why:** The tvOS scrub commit writes `pendingScrubTargetMs` and repaints, so the bar and labels hold at the target while libVLC re-opens the byte range; the iOS slider release does not, so the next `refreshTimeUI` paints `currentMs`. Skip-intro/outro calls `userEngineSeek` directly, getting neither the coalescing that the ±N skip and chapter-chip paths use nor the anti-snap-back hold.
- **Impact:** Cosmetic: a possible one-tick snap-back of the iOS slider and labels after a scrub release, and an un-coalesced seek on skip-intro. Note the CLAUDE.md sentence about "scrub release" sits inside the tvOS TVScrubBar rule, so the iOS slider is not strictly covered — this is an asymmetry, not a contract breach.
- **Fix:** Set `pendingScrubTargetMs` + `writeTimeLabels(position: target, ...)` in `scrubberDone` before `userEngineSeek`, and route `skipSegmentTapped` through `accumulateSeek` like the other entry points.

### 33. `L-14` — The VLC event-loop Task promotes self to a strong reference, making its [weak self] inert and leaving teardown single-triggered with no deinit net

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · PLAUSIBLE
- **Area:** performance
- **Where:** Shared/Screens/VideoPlayer/VLCStreamPresenter.swift:826-828 (guard let self before the for await), :530-537 (the only teardown trigger), :888-895 (Timer on RunLoop.main, invalidated only in teardown); no deinit in the file
- **Prior audit:** F-29 (2026-08-05), still open
- **What & why:** `guard let self else { return }` binds strongly for the loop's entire lifetime, and the loop only ends when `player.events` finishes — which requires the player to be released, which requires self to be released. The cycle is broken only by `eventsTask?.cancel()` in `teardown()`, called from exactly one place guarded on `isBeingDismissed`.
- **Impact:** Structural rather than demonstrated: I traced all eight dismissal sites and every one is a self-`dismiss(animated:)` on a plainly-presented modal, which sets `isBeingDismissed`, so on all shipped paths teardown does run. The finding is that the safety net is missing, not that a leak is reachable today — and note the strong capture means the presenter can never deallocate WITHOUT teardown, so the two failure modes coincide rather than compound.
- **Fix:** Capture the stream in a local before the loop and re-acquire self weakly per iteration, and add a `deinit` (or a second `viewDidDisappear` trigger) that cancels `eventsTask` and invalidates `progressTimer`/`openWatchdog`.

### 34. `L-15` — MediaLibraryViewModel.loadHeroNavigation writes heroPlay with no generation or identity guard

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** correctness
- **Where:** Shared/ViewModels/MediaLibraryViewModel.swift:225-228 (unstructured side Task), :381-445 (three awaits, write at :436 with no re-check), :365-369 (refreshHeroNavigation, a second unordered writer)
- **What & why:** The probe captures `hero` in its opening guard, awaits getNextUp → getSeasons → getEpisodes, then writes `heroPlay` without re-reading `heroItem`. It is spawned as an unstructured Task, so cancelling the parent load does not cancel it, and `refreshHeroNavigation` (called from `.onAppear` and the tvOS dismiss observer) can run concurrently. Every other stale-result site in this file and its sibling uses a guard — `loadTask` draining, the `appliedGenreSortFilter` stamp, `MediaDetailViewModel.loadGeneration`.
- **Impact:** A late probe can pin the hero's Play button to an episode of the previous hero — most concretely across a server switch, where the id does not exist on the new server and Play fails to negotiate. Narrow: the hero is a deterministic `dateCreated desc` first item, so an ordinary reload re-selects the same item and the late write is identical; the window needs the hero to actually change while a probe is outstanding, and the failure is recoverable by leaving and re-entering the tab.
- **Fix:** Add `heroNavGeneration`, bump it where `heroPlay = nil` is set and in `refreshHeroNavigation`, snapshot at the top of `loadHeroNavigation`, and re-check it plus `heroItem?.id == seriesId` immediately before the write — the pattern `MediaDetailViewModel.loadGeneration` already uses.

### 35. `L-16` — Every poster and wide card eagerly constructs a MediaDetailScreen, allocating a view model per card per body pass

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `M` · CONFIRMED
- **Area:** performance
- **Where:** Shared/Screens/MediaDetailScreen.swift:94-96; call sites Shared/Screens/LibraryPosterCard.swift:120-124, SearchScreen.swift:809, HomeScreen.swift:635/708/951, FavoritesScreen.swift:229, WatchedHistoryScreen.swift:298, MediaDetailSimilarSection.swift:40, PersonDetailScreen.swift:113, LibraryHeroSection.swift:136
- **What & why:** `State.init(initialValue:)` takes a value, not an autoclosure, and `NavigationLink(destination:label:)`'s destination is a non-escaping ViewBuilder evaluated at init — so `MediaDetailViewModel(...)` is constructed when the link is built, not when it is followed.
- **Impact:** Two heap allocations per card per body pass (the class plus its ObservationRegistrar state); the init only stores two strings and every collection property is an empty literal, which does not allocate, and no `State` box or observation registration occurs because the view is never installed. ~100 short-lived allocations per 48-card grid pass — not measurable on an A15. It is also a direct consequence of the documented lazy-container RULE, so there is no cheap fix that preserves navigation.
- **Fix:** Only worth doing as part of a broader move to `NavigationLink(value:)` + one `navigationDestination(for:)` per screen root; alternatively make `MediaDetailScreen` hold `@State private var viewModel: MediaDetailViewModel?` created in `.task`, so its init is free.

### 36. `L-17` — AdminItemMenu builds its whole Menu tree on every card body pass and installs a per-card sheet

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** performance
- **Where:** Shared/Screens/Admin/Components/AdminItemMenu.swift:48-83 (inline Menu content, 5 loc.localized lookups) and :84-96 (per-card .sheet); host Shared/Screens/LibraryPosterCard.swift:152-161
- **What & why:** `Menu.init(@ViewBuilder content:label:)` is non-escaping — the same property that made `contextMenu` eager and drove the F-46 fix — so for an administrator every visible card builds four Buttons, four Labels, a Divider, five bundle lookups and four escaping closures each capturing the enclosing DTO, for a menu nobody opened. `MediaCardContextMenu` solved exactly this by moving the tree into a standalone `CardMenuContent` view whose body is deferred; AdminItemMenu kept the inline builder and additionally attaches its own presentation host per card.
- **Impact:** iOS-only and administrator-only, so it never touches the A15 Apple TV the perf budget is written against, and iPhone/iPad absorb ~5 bundle lookups × ~20 visible cards easily.
- **Fix:** Apply the `CardMenuContent` recipe: move the buttons into a standalone `AdminItemMenuContent` view and pass scalars (id, name) rather than the whole BaseItemDto. Consider hoisting the delete sheet to the screen root.

### 37. `L-18` — SearchResultsGrid's == is coarser than SearchResultCard's, violating the invariant its own comment states

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** correctness
- **Where:** Shared/Screens/SearchScreen.swift:636-663 (grid ==) vs :786-797 (card ==); consumer :841-851
- **What & why:** The grid compares id/name/primaryImageTagValue/isPlayed/isFavorite per element; the card additionally compares `type` and `productionYear`, both of which feed `subtitle(for:)`. The comment at :646-651 explicitly requires the outer comparator to be at least as fine-grained, because when it compares equal the cards are never re-created and the card's own `==` is never consulted.
- **Impact:** After a server-side metadata edit corrects a production year, re-running the same query short-circuits and the visible cards keep the stale subtitle. Narrow — `type` is effectively immutable, and an edit that also touched the poster would change the image tag and break the tie.
- **Fix:** Add `a.type != b.type || a.productionYear != b.productionYear` to the zip comparison so the outer test is a strict superset.

### 38. `L-19` — NetworkMonitor writes isOnline with no equality guard and the app root observes it

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** performance
- **Where:** Shared/ViewModels/NetworkMonitor.swift:12-29; Shared/Navigation/AppNavigation.swift:1038 (root reads it inside onChange); MediaDetailScreen.swift:870,876,881,1027,1043,1056
- **Prior audit:** F-10 (2026-08-05), still open
- **What & why:** `NWPathMonitor.pathUpdateHandler` fires on any path change, not only on a status transition, and the write is unconditional — `@Observable` fires `withMutation` even for an identical value. Because the root body reads the property inside `.onChange`, it registers an Observation dependency and is re-evaluated on every path event. This is the same defect class CLAUDE.md documents as a RULE elsewhere ("the knownRemoteTargetCount writer must keep its equality guard").
- **Impact:** A re-evaluation of AppNavigation.body and of any open detail screen's action rows on every path event. Cheap — the root's children are value types that mostly diff equal — and NWPathMonitor coalesces, so the prior claim of per-second churn is unsupported.
- **Fix:** `guard online != isOnline else { return }` before the write, and hop only when it differs so the no-op case does not even allocate a Task.

### 39. `L-20` — Multi-version ranking is re-sorted four or more times per MediaDetailScreen body pass

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** performance
- **Where:** Shared/Screens/MediaDetailScreen.swift:496-514 (selectedSource re-enters versionSources); callers at :163, :275, :543-544, :730, :793, :850
- **Prior audit:** F-23 (2026-08-05), still open
- **What & why:** `versionRow` calls `versionSources` and then `selectedSource`, which ranks again; the badges and the action buttons each call `selectedSource` too. The comparator inspects bitrate cap, resolution, HDR range, an IMAX string match on name/path, audio format, channels and bitrate.
- **Impact:** Bounded by source count — 2-3 elements in any realistic library — and gated behind `sources.count > 1`, so single-version items (the overwhelming majority) pay nothing. Pure repeated work on a screen that re-renders on every favourite/watched toggle.
- **Fix:** Resolve `versionSources(item)` and the selected source once in `detailContent` and thread both into `versionRow`, `MediaQualityBadges` and `actionButtons`.

### 40. `L-21` — Each tvOS poster card installs its own @AppStorage observer for a near-immutable Bool

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** performance
- **Where:** Shared/Screens/LibraryPosterCard.swift:106-114 (PosterCardContent); contrast the EnvironmentValues pattern at Shared/DesignSystem/FocusScaleModifier.swift:5-7 injected once at Shared/Navigation/AppNavigation.swift:903
- **Prior audit:** F-34 (2026-08-05), still open
- **What & why:** `@AppStorage(SettingsKey.dimUnfocusedPosters)` is a DynamicProperty that installs a UserDefaults observer per installed view, so a tvOS grid plus 8 genre rows registers hundreds of observers for one Bool, torn down and re-installed as cells recycle. The neighbouring `motionEffectsEnabled` on the same lines shows the right mechanism for exactly this shape of flag. Note the per-card `@FocusState` design is documented-deliberate — only the storage mechanism is the finding.
- **Impact:** Cheap registrations; a broadcast to all of them when the toggle flips. Hygiene.
- **Fix:** Promote it to an EnvironmentValues entry injected once at the root and read with `@Environment` in PosterCardContent.

### 41. `L-22` — ImageURLBuilder.screenPixelWidth enumerates connectedScenes on every read, from the hottest hero bodies

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** performance
- **Where:** Packages/CinemaxKit/Sources/CinemaxKit/Networking/ImageURLBuilder.swift:53-65; read at Shared/Screens/HomeScreen.swift:557, Shared/Screens/MediaDetailScreen.swift:345, LibraryHeroSection
- **Prior audit:** F-33 (2026-08-05), still open
- **What & why:** The property enumerates `UIApplication.shared.connectedScenes` and compactMaps them on every read, with no memoization, and it is read inside hero bodies i.e. once per body pass.
- **Impact:** Small per-read cost on the paths that re-render most; the correct value changes only on a scene/display change.
- **Fix:** Memoise behind a cached value invalidated on `UIScene` connect/disconnect (the same shape as `CinemaScale.cachedFactor`, which already does this correctly).

### 42. `L-23` — FlowLayout declares no cache and measures every subview twice per layout pass

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** performance
- **Where:** Shared/DesignSystem/Components/FlowLayout.swift:7,31
- **Prior audit:** F-43 (2026-08-05), still open
- **What & why:** The `Layout` conformance uses `cache: inout ()` and calls `subview.sizeThatFits(.unspecified)` once in `sizeThatFits` and again in `placeSubviews`.
- **Impact:** Every chip is measured twice per pass; hit hardest by the library filter sheet's 25-60 genre chips.
- **Fix:** Declare a cache type holding the measured sizes and populate it in `makeCache`.

### 43. `L-24` — Both realtime sockets run on URLSessionConfiguration.default (shared disk URLCache and cookie store) while their URL carries the access token

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** security
- **Where:** Packages/CinemaxKit/Sources/CinemaxKit/Networking/SessionSocket.swift:36-38; SyncPlaySocket.swift:30-32; token in the URL at JellyfinAPIClient+RemoteControl.swift:123-126 and +SyncPlay.swift:122-124
- **What & why:** Every other session in the codebase is `.ephemeral` with `urlCache = nil` (JellyfinAPIClient.swift:417, ServerReachability, HLSManifestLoader, CinemaxStreamProxy, both extensions). These two inherit `URLCache.shared` and `HTTPCookieStorage.shared` from `.default`. The documented RULE is worded as "no authenticated request rides URLSession.shared", which these technically do not — so this is a gap in the rule's enumerated list and a break from uniform practice rather than a literal violation.
- **Impact:** A WebSocket upgrade is not cacheable, so there is no cached token today; exposure is limited to a non-upgrade handshake response keyed on a token-bearing URL. SessionSocket is the always-on one (`playback.remoteControl` defaults true); SyncPlaySocket is unreachable behind the Watch Together kill-switch.
- **Fix:** Build both on `URLSessionConfiguration.ephemeral` with `urlCache`, `httpCookieStorage` and `urlCredentialStorage` nil, and invalidate the session in `stop()`. Two one-line changes with no behavioural cost.

### 44. `L-25` — Plain-http server URLs are accepted silently, and NSAllowsArbitraryLoadsForMedia extends the cleartext window past the LAN

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** security
- **Where:** Packages/CinemaxKit/Sources/CinemaxKit/Models/ServerURLNormalizer.swift:33-34; Shared/ViewModels/ServerSetupViewModel.swift:28-31; project.yml:93-95 (and :190-192, :239-241, :278-280)
- **Prior audit:** S6 (2026-07-06), still open; the media-exemption half is new
- **What & why:** `normalize` accepts either scheme and returns nil as its only signal, so a caller cannot distinguish rejected from accepted-over-cleartext, and no call site inspects `url.scheme` afterwards. ATS permits the load via `NSAllowsLocalNetworking` — but all four targets ALSO set `NSAllowsArbitraryLoadsForMedia: true`, which exempts AVFoundation media loads to any host, so a remote http server's stream URL (carrying `api_key` in the query string) loads in cleartext over the public internet with no ATS objection.
- **Impact:** The `MediaBrowser Token=` header and every `api_key`-bearing stream/image URL travel in the clear with no user-visible signal that the session is unprotected. Allowing http is mandatory for self-hosted LAN Jellyfin — the gap is the missing signal, and the media exemption widening it beyond the local network.
- **Fix:** Show a one-time non-blocking warning when the committed URL's scheme is http and mark the entry "unencrypted" in ServersScreen. Consider dropping `NSAllowsArbitraryLoadsForMedia` and relying on `NSAllowsLocalNetworking` alone, which is what the LAN case actually needs.

### 45. `L-26` — Inbound DisplayMessage text is rendered in native app chrome with no length bound or sanitisation

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** security
- **Where:** Shared/Screens/RemoteControlListener.swift:139-145; parsed at Packages/CinemaxKit/Sources/CinemaxKit/Networking/SessionSocket.swift:143-152; advertised at JellyfinAPIClient+RemoteControl.swift:100-105
- **What & why:** The header and text arrive off the session socket with no length bound and no sanitisation beyond a whitespace trim, and are handed verbatim to `toasts.info(header, message: text)` — a glass pill that reads as the app's own voice. `DisplayMessage` is the ONE command the capability post advertises, so this is the always-on inbound path.
- **Impact:** Jellyfin permits an admin with EnableRemoteControlOfOtherUsers to target another user's session, so a server-side actor can paint arbitrary text in native chrome (phishing-shaped: "Session expired — re-enter your password"), and an unbounded string blows out the ToastOverlay layout. This is the only place in the app where untrusted remote text reaches the UI unbounded.
- **Fix:** Clamp both strings (`.prefix(200)` on the message, shorter on the header) and consider a visual marker that the message came from the server rather than the app.

### 46. `L-27` — HLSManifestLoader's URLSession sets no request or resource timeout, inheriting the 7-day default

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** correctness
- **Where:** Shared/Screens/HLSManifestLoader.swift:29-35; contrast JellyfinAPIClient.swift:412-419 (30/60), ServerReachability.swift:83-84, JellyfinLite.swift:42
- **What & why:** The config sets `urlCache`, `requestCachePolicy` and `waitsForConnectivity` but neither timeout, so the defaults apply (60 s inactivity, 604800 s resource). CLAUDE.md's bounded-timeouts RULE covers every session in the app, and the two other private sessions set both.
- **Impact:** On the native-AVPlayer iOS path, a manifest or WebVTT fetch from a server that accepts the connection and then trickles is bounded only by per-packet inactivity, with no overall ceiling — AVPlayer's resource-loading request never completes and the player sits on a spinner with no error. Doubly gated: iOS only, and the native player is opt-in.
- **Fix:** Set `timeoutIntervalForRequest = 30` and `timeoutIntervalForResource = 60` to match `fastFailSessionConfiguration`, and extend the doc comment to claim parity on both halves of the discipline rather than just urlCache.

### 47. `L-28` — Logout's auto-hop reports "switched to X" when the hop actually landed on a login screen — the registry's decision functions ignore their own model's contract

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** correctness
- **Where:** Packages/CinemaxKit/Sources/CinemaxKit/Models/ServerRegistry.swift:90-94 (nextCandidate) and :105-117 (decideSwitch), both gating on hasSession; contract at ServerEntry.swift:70-76; Shared/Navigation/AppNavigation.swift:473-476 (switchTo returns .commit unconditionally), :344-355, :635-639; toasts at SettingsScreen.swift:397-402 and ServersScreen.swift:213-216
- **What & why:** `ServerEntry` documents the token-without-userId shape as reachable and provides `hasUsableSession` for exactly this, warning that any "is this server signed in?" test must use it. Both registry decision functions ask `hasSession` (token only), and `switchTo` returns `.commit` even when `applyActiveServer` bailed into `beginReLogin`.
- **Impact:** The user signs out, sees a green "Basculé sur <server>" toast, and is looking at a login form; ServersScreen has the same mislabel plus a dismiss. Wrong signal over a correct destination, on a partial-migration shape.
- **Fix:** Filter `nextCandidate` and gate `decideSwitch` on `hasUsableSession`, and have `switchTo` return the real outcome (`.needsLogin`) when `applyActiveServer` takes its re-login branch.

### 48. `L-29` — SearchViewModel's stale search task can clear the newer search's spinner

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · PLAUSIBLE
- **Area:** concurrency
- **Where:** Shared/ViewModels/SearchViewModel.swift:359 (cancel only), :377-386 (defer sets isSearching = false with no ownership token)
- **Prior audit:** B5 (2026-07-06), still open
- **What & why:** `search(using:)` cancels the previous task without awaiting its unwind, and both tasks write one shared `isSearching` flag. Both are main-actor-isolated so this is an ordering artefact, not a data race — the view model is the only one in the codebase lacking the generation counter its siblings use (MediaDetailViewModel.loadGeneration, MenuConfigStore.refreshGeneration, TrickplayController.generation).
- **Impact:** If the previous search's cancellation takes longer than the new search's 400 ms debounce, the old task's `defer` clears a spinner for a search that is genuinely in flight. Requires a stalled server, and is bounded by the new results landing.
- **Fix:** Capture a monotonically-bumped generation before the sleep and guard every write, including the `defer`, on it.

### 49. `L-30` — TrickplayController accumulates a completed Task handle per tile fetch for the media's lifetime

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** performance
- **Where:** Shared/Screens/VideoPlayer/TrickplayController.swift:138-147 (append), :88-89 (only shrink is reset())
- **What & why:** `fetchTasks.append(task)` on every cache miss; the array is emptied only by `reset()` on configure/teardown, and tasks never remove their own handle. `inflightTiles` already applies the right discipline.
- **Impact:** Bounded in practice — `fetchTile` early-returns for cached or in-flight tiles and a 3 h film has on the order of ten tile sheets, so total waste is kilobytes of Task handles per session. Hygiene in a controller whose stated purpose is bounded memory.
- **Fix:** Key the handles by tile index in a dictionary and have each task remove its own on completion.

### 50. `L-31` — All 39 admin catch blocks map the error for display but never log the raw error, deviating from the documented rule

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `M` · CONFIRMED
- **Area:** maintainability
- **Where:** Shared/Screens/Admin/Devices/AdminDevicesViewModel.swift:18-29 and :33-40; 39 `userFacingMessage` sites across 15 files in Shared/Screens/Admin, where `grep -rn "logger|Logger("` returns 0 hits; contrast Shared/ViewModels/HomeViewModel.swift:351-352
- **Prior audit:** noted inside D1's remediation (2026-07-06), still open
- **What & why:** CLAUDE.md's localization RULE reads "Map via LocalizationManager.userFacingMessage(for:) … log the raw error instead. VMs that show errors take `loc:` and `logger`." Admin VMs take `loc:` and do the mapping half; none declares a logger, while 8 non-admin VMs do.
- **Impact:** Diagnosability only — the user-facing half of the rule is honoured everywhere. But it means the highest-blast-radius operations in the app (policy revocations, device and API-key revocation, item deletion, metadata writes) fail with a generic sentence and leave no trace: a sysdiagnose yields nothing, no status code, no endpoint.
- **Fix:** Fold the 39 identical isLoading/errorMessage/do-catch blocks into one shared `withLoad(loc:logger:)` helper that maps AND logs in one place — that closes this permanently and removes ~200 lines (the D1 backlog item), rather than adding 15 loggers by hand.

### 51. `L-32` — CI verifies only project.pbxproj for xcodegen drift, and relies on an uninstalled xcbeautify

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** maintainability
- **Where:** .github/workflows/ci.yml:50-55 (path-scoped diff), :75 and :87 (xcbeautify never installed); generated-and-committed files: iOS/tvOS/Widgets/TopShelf Info.plist and the four .entitlements
- **Prior audit:** Q4 (2026-07-06) was fixed for the pbxproj only; this is the residual gap
- **What & why:** `git diff --exit-code -- Cinemax.xcodeproj/project.pbxproj` is path-scoped, but xcodegen also writes eight further committed files from `info:`/`entitlements:` blocks in project.yml — carrying the App Group, the shared Keychain group, the URL scheme, UIBackgroundModes, NSSupportsLiveActivities, ITSAppUsesNonExemptEncryption and every NS*UsageDescription. Separately, both build steps pipe into xcbeautify, which the workflow never installs (unlike xcodegen, which is explicitly pinned) and which combined with `set -o pipefail` would fail both steps with `command not found` if the runner image ever drops it.
- **Impact:** Drift in exactly the files whose silent divergence produces an App Store rejection or a runtime capability failure passes CI unnoticed. Blast radius is limited because CI regenerates before building, so the shipped binary is built from fresh output — the risk is a committed tree that no longer describes what ships, which defeats the step's purpose.
- **Fix:** Widen the check to a bare `git diff --exit-code` after `xcodegen generate` (a strictly smaller command covering all nine files), and install/pin xcbeautify explicitly.

### 52. `L-33` — Localization parity is unguarded in CI despite an existing check being available as an agent-only skill

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** testing
- **Where:** .github/workflows/ci.yml:13,89 (only build and lint jobs); .claude/skills/localize-check/SKILL.md
- **Prior audit:** Q4 second half (2026-07-06), still open
- **What & why:** Neither CI job touches Resources/*.lproj. A parity checker exists but is reachable only by an agent. Current state is clean — I re-measured 796 keys in each of fr/en Localizable.strings with an empty symmetric difference — but that is discipline, not enforcement, and the table has grown ~70 keys since the last audit.
- **Impact:** A missing key does not fail the build: `loc.localized("key")` returns the key, so an untranslated string ships as a raw dotted identifier in one language's UI. Quieter still for AppShortcuts.strings, where a phrase in the wrong table simply never resolves with no build error — a trap CLAUDE.md documents explicitly.
- **Fix:** Add a third CI job with the ~10-line key-set diff the skill already encodes, extended to InfoPlist.strings and AppShortcuts.strings.

### 53. `L-34` — jellyfin-sdk-swift is declared with a 0.x upToNextMajor range and Package.resolved is not drift-checked

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** maintainability
- **Where:** Packages/CinemaxKit/Package.swift:14; .github/workflows/ci.yml:59-64 (Package.resolved used only as a cache key); contrast project.yml:32 (SwiftVLC exactVersion 1.0.0)
- **Prior audit:** the 2026-07-06 audit listed dependency pinning as healthy; that held for SwiftVLC and for Package.resolved, not for the SDK's manifest range
- **What & why:** `.upToNextMajor(from: "0.4.1")` resolves `>=0.4.1 <1.0.0` for a 0.x package, i.e. every future minor. The pin that actually holds the build together is Package.resolved (0.6.0/e7bb3b79, verified consistent across both committed copies), and nothing in CI verifies it is unchanged. The code depends on 0.6.0-specific surface — CLAUDE.md records that ~190 lines of hand-built SyncPlay plumbing were deleted on the strength of `Paths.syncPlay*` and a typed `UtcTimeResponse` existing in 0.6.0.
- **Impact:** Any resolution refresh silently moves the SDK to the newest 0.x; in a generated-API package a minor bump routinely renames or removes `Paths.*` operations, so the failure mode is a wall of compile errors at a moment nobody chose. Bounded by the committed Package.resolved being honoured unless someone explicitly resolves.
- **Fix:** Tighten to `.upToNextMinor(from: "0.6.0")` or `exact: "0.6.0"`, matching the SwiftVLC precedent, and add both Package.resolved files to the CI drift check from L-32.

### 54. `L-35` — regen-project.yml retains a push trigger on a stale agent branch while holding contents: write

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** maintainability
- **Where:** .github/workflows/regen-project.yml:19-20 (push trigger), :28-29 (contents: write), :66 (auto-push)
- **What & why:** The inline comment says the push trigger existed only because workflow_dispatch does not work until the workflow is on the default branch. It now is, so the bootstrap reason has expired, leaving a write-capable job bound to a branch name anyone with push access can recreate.
- **Impact:** No privilege escalation (the trigger requires push access, which already implies write), but a resurrected branch would get its pbxproj silently rewritten and force-committed under the github-actions identity, unattended.
- **Fix:** Delete the `push:` block; workflow_dispatch is now sufficient and is the documented intent.

### 55. `L-36` — SettingsKeys.swift doc comments still place two settings rows in Appearance after they moved to Interface → Library

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** maintainability
- **Where:** Shared/DesignSystem/SettingsKeys.swift:78-80 and :88-89; actual homes at Shared/Screens/Settings/SettingsScreen+tvOS.swift:489,507-518 and SettingsScreen+iOS.swift:438,481-499
- **Prior audit:** a new instance of the Q8 docs-drift class
- **What & why:** `libraryBrowseLayout`'s comment says "the iOS toggle lives in Appearance, the tvOS one in Appearance too" and `dimUnfocusedPosters`' says "Settings → Appearance (tvOS)". Both rows are in `tvLibrarySection` / `iOSLibrarySection` under Interface → Library. CLAUDE.md agrees with the code, not the comments.
- **Impact:** SettingsKeys.swift is explicitly the SSOT for @AppStorage keys and is the first file anyone reads when adding or relocating a setting; two of its own settings are misdescribed. These are the only two stale comments in the file.
- **Fix:** Update both comments to say Settings → Interface → Library.

### 56. `L-37` — Prior audit's duplication backlog is ~5% addressed, and the largest item now carries a correctness cost

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `M` · CONFIRMED
- **Area:** maintainability
- **Where:** Shared/Screens/Settings/SettingsScreen+iOS.swift:87-136 vs :375-422 (48-line twins); D1: `grep "AsyncLoadable|func withLoad"` → 0 hits; D2: `grep "AdminListRow|AdminStatusPill"` → 0 hits
- **Prior audit:** D1, D2, D5 (2026-07-06) all still open; D3 confirmed fixed
- **What & why:** `iOSCategoryButton` and `iOSInterfaceSubButton` differ in three tokens (parameter type, assignment target, isFirst derivation) and are otherwise byte-identical. D1 (~200 lines of hand-written admin load scaffold, 34+ copies) and D2 (~110 lines) are untouched; only D3 was done (iOSRowIcon/iOSSettingsSectionHeader are now shared in SettingsRowHelpers.swift:73,96).
- **Impact:** Pure hygiene except for D1, which is now also the reason the missing admin error logging (L-31) exists in 39 places — there is no shared helper to put it in once.
- **Fix:** Do D1 first, for the logging rather than the line count: one `withLoad(loc:logger:)` helper adopted by the 15 admin VMs closes L-31 and removes ~200 lines in the same diff. D5 is a 20-minute generic extraction (`settingsHubButton(icon:title:isHero:action:)`) with zero behavioural risk.

### 57. `L-38` — Four superseded audit reports sit at the repo root and there is no README

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `S` · CONFIRMED
- **Area:** maintainability
- **Where:** APP_STORE_AUDIT.md, AUDIT.md, AUDIT_2026-06-09.md, Audit_post_vlc.md (~65 KB total) alongside docs/audits/; `ls README*` → not found
- **Prior audit:** Q6 and Q7 (2026-07-06), both still open
- **What & why:** The four root files predate the docs/audits/ convention and carry no date ordering relative to it — one of them still cites DownloadManager, a feature removed before 1.0.5. The only entry-point document is CLAUDE.md, which is explicitly agent-facing and 210 KB (up 101% in 22 days, measured from git history).
- **Impact:** A reader or an agent globbing `*.md` at root can act on conclusions later audits reversed. A human cloning the repo has no statement of the required toolchain (Xcode 26.5 per project.yml:10), the pinned xcodegen 2.46.0 bootstrap, `git config core.hooksPath scripts/git-hooks`, or which of the four schemes to build.
- **Fix:** Move the four files into docs/audits/ with dates in the filename, or delete them if actioned. Add a ~40-line README with toolchain, xcodegen bootstrap, schemes, the hook install, and how to run the tests including the `-only-testing` caveat.

### 58. `L-39` — VLCStreamPresenter is a single 3,530-line class with ~146 stored properties and 34 platform-conditional regions

- **Axes:** criticality `low` · importance `low` · priority `P3` · effort `L` · CONFIRMED
- **Area:** maintainability
- **Where:** Shared/Screens/VideoPlayer/VLCStreamPresenter.swift:143 to EOF (3,672); 24 MARK headers naming distinct responsibilities; 9 hand-written `!isTearingDown` liveness guards and 6 hand-written `navGeneration` re-checks
- **What & why:** The class is the app's riskiest file and has no direct test coverage — only the extracted pure helpers (SeekCoalescer, SeekSettleTracker, PlaybackEndPolicy, PlayerTimeFormat, VLCEngineLog) are tested, which is genuinely good practice as far as it goes. The concern is the 15 hand-repeated invariant checks: 15 independent opportunities to forget one, and CLAUDE.md records that this has already happened (the audio-session activation path "was the one path that historically skipped it").
- **Impact:** No reachable defect today — every historical bug of this shape is documented as fixed, which is evidence the invariants are watched. This is a structural risk note, not a defect, and the earlier quantification of it overstated the repetition by ~40%.
- **Fix:** Extract along the MARK boundaries that already exist, starting with the pieces with no view-hierarchy coupling: the seek/loading state machine (`pendingScrubTargetMs`, `seekSettle`, `seekLoadingWork`, `seekCommitWork`) into a clock-testable `SeekController`; then the chapter strip + trickplay preview; then the two transport UIs behind one protocol, which alone removes most of the 34 `#if` regions. Replace the 15 hand-written re-checks with one `withLiveness(gen:) { }` helper.

---

## Systemic themes

These are causes, not instances — each spans several findings above.

1. FAILURE STATES ARE INVISIBLE. This is the strongest systemic pattern and it spans seven independent sites: MediaDetailScreen never clears errorMessage so Retry is a dead end (H-1); HomeViewModel declares an errorMessage nothing writes and reports an outage as "your library is empty", latching hasLoaded so it never retries (M-1); PaginatedLoader swallows a page-0 failure with no record and no trigger to retry; AdminDashboardViewModel writes an errorMessage no view reads; all 39 admin catch blocks map for display without logging the raw error (L-31); every Keychain write failure is log-only, including one that can wipe the server registry (M-17); and LoginViewModel logs a failed session save and signs the user in anyway. The pattern is not 'errors are unhandled' — they are caught, carefully mapped, and then dropped.

2. ENFORCEMENT MECHANISMS ARE SWITCHED OFF, so documented RULEs are upheld by discipline alone. SwiftLint's `--strict` job ends `continue-on-error: true` and excludes the entire test suite (M-11); tvOS — the highest-regression-density platform, with a documented history of shipped focus and transport bugs — has zero test execution (M-14); localization parity is checked only by an agent-only skill (L-33); the xcodegen drift check covers one of nine generated files (L-32). The codebase's discipline is genuinely high, which is precisely why the absence of enforcement has not yet cost much — but every finding in this audit that is a RULE deviation (the ServerVersion gate, the log-the-raw-error rule, the bounded-timeouts rule, the prefetch-URL-identity rule) went undetected by tooling.

3. PRIOR AUDIT FOLLOW-THROUGH IS SELECTIVE, AND THE SELECTION IS TELLING. The 2026-08-05 card-menu lot (F-46…F-56) was fixed thoroughly and correctly — verified in code, including the subtle parts. The same audit's view-layer lot (F-1, F-2, F-3, F-10, F-20, F-22, F-23, F-24, F-32, F-33, F-34, F-43) and network lot (F-7, F-9, F-13, F-15, F-16, F-41) were not touched at all, and three 2026-07-06 items (S1 rating mapping, S2 keychain writes, B1 off-main notification) are on their second or third re-report. Work lands when it is scoped as a lot; findings filed as a list do not get scheduled.

4. THE TWO PLAYER ENGINES DIVERGE ON EVERYTHING THAT ISN'T THE CRITICAL PATH. VLC got the chapter-thumbnail deferral, the native path did not (L-2). The native path reports background progress, VLC does not (L-6). VLC releases the superseded PlaybackInfo, the native path's track switch does not (M-16). VLC embeds api_key in image cache keys, the native path does not (L-8). The engine choice is a single boolean setting, so every one of these is a behaviour difference a user can toggle into without knowing.

5. SERVER-SESSION RELEASE IS CENTRALISED IN PlaybackReporter — EXCEPT AT EVERY SITE THAT REPLACES A PlaybackInfo. There are four such sites (navigateToEpisode ×2, reResolveAndResume, switchTracks) plus the negotiation-level retry in getPlaybackInfo; three are correct, two leak (M-16, L-10). Because `isAutoOpenLiveStream = true` on every negotiation, each miss is a real server-side resource, and a one-off sweep of 'who overwrites a PlaybackInfo' would close the class permanently.

6. THE PROXY'S REQUEST-HANDLING IS RIGOROUS; ITS LIFECYCLE IS NOT. Admission, traversal defence and the UUID target gate are carefully reasoned and locked by 13 tests. Everything around them is unguarded: listener bring-up has no ownership check on either terminal branch (L-5), connections have no idle timeout or concurrency cap (L-4), target registrations outlive both the stream and the signed-in user (L-3), and the malformed-percent-encoding path can trap (L-1). The tested surface is the pure functions; the stateful surface has no tests at all.

7. ONE FIELD, TWO MEANINGS. `PlaybackInfo.authToken` is the stream credential to its producer and a general API token to its three image consumers (L-9). `ServerEntry.hasSession` means 'has a token' while three registry decision points use it to mean 'is signed in', despite the model's own doc comment forbidding exactly that (L-28). Both bugs are invisible at the call site and only appear when the two meanings diverge.

8. SECOND COPIES DRIFT WHERE THEY AREN'T TEST-LOCKED. The widget duplicates HomeViewModel's Recently Added merge and inherits its serialisation defect with no test coverage of its own (M-6); AuthenticatedImageFetch's contract comment now contradicts two of its three callers (L-8); SettingsKeys.swift's doc comments contradict both the code and CLAUDE.md (L-36). The counter-example proves the point: the extension Keychain contract also exists in three copies and is exactly in sync, because ExtensionSessionContractTests asserts each literal.

---

## Quick wins

- H-1 — one line (`errorMessage = nil` after `isLoading = true` in MediaDetailViewModel.load) removes a dead-end error screen on the app's most-visited secondary view. Highest value-per-character fix in this audit.
- M-9 — one extra prefetch pass over `heroCandidates` with the hero's own maxWidth and tag; removes a grey flash on the most-looked-at region of the app, on every Home visit with two or more heroes.
- M-4 — four statements in handlePlaybackEnded's non-autoplay branch (invalidate the timer, clear the sleep flag, nowPlaying.detach) stop an indefinite 1 s wake-up loop, a progress POST every 10 s, and a permanently-'watching' server session.
- Near-misses worth batching with the above (effort S, importance medium): M-7 memoising ThemeManager's four accent slots; M-10 posting .cinemaxSessionExpired from a @MainActor Task; M-8 gating getCollections on ServerVersion; M-11 deleting `continue-on-error: true` (the codebase is already near lint-clean: 4 force unwraps, zero try!/as!); L-19 adding an equality guard to NetworkMonitor.isOnline.

---

## Recommendations

- Schedule the remaining findings as LOTS, not as a list. The evidence is unambiguous: the one prior lot that was scoped as a unit (card menus, F-46…F-56) landed completely and correctly; everything filed as a table is still open a year of commits later. Suggested lots, in order: (1) 'error surfaces' — H-1, M-1, L-31, plus the LoginViewModel and persistRegistry silent failures from M-17; (2) 'view-layer perf' — H-2, M-7, M-12, M-13, M-9, L-22, L-23, which is most of the untouched 2026-08-05 audit; (3) 'session lifecycle' — M-16, L-10, plus a sweep of every site that overwrites a PlaybackInfo; (4) 'proxy lifecycle' — L-1, L-3, L-4, L-5.
- Turn the SwiftLint gate on before adding anything else to CI. It is 4 force unwraps away from being real, and it is the only mechanism that would have caught several findings here mechanically. Pin SwiftLint the way xcodegen is pinned, and drop `Tests` from `excluded:` so the opted-in test rules stop being dead.
- Create the tvOS test target now, even if it starts with three tests. The blocker is not effort but shape: the tvOS logic worth testing (hiddenHUDIntent, the Menu-peel alpha decision, TVScrubBar's incremental accumulation) is `private static` inside a 3,500-line view controller. Extracting those three is the first slice of the VLCStreamPresenter decomposition (L-39) and buys regression cover for the exact defects CLAUDE.md documents as having shipped.
- Decide explicitly what `privacy.maxContentAge` IS. Today it is a discovery filter that is off by one category on two of its five settings, absent on every id-addressed read, and documented as a control in IntentSessionProvider. Either fix the mapping and filter `getItem` and the deep-link dispatcher (making it a control), or fix the mapping and correct the doc comments (making it an honest filter). Both are defensible; the current mixture is not.
- Adopt a rule that CLAUDE.md is amended in the same commit as the code it describes, and that a stale RULE is a defect. The document doubled to 210 KB in 22 days and both humans and agents are instructed to treat it as ground truth. The forensic narratives are genuinely valuable — but consider moving them to `docs/decisions/` behind one-line references so the invariants stay readable, and note that the one staleness this audit found (L-36) is in the code's comments, not CLAUDE.md: the doc is currently ahead of the source.
- Add three shared helpers that each close a class rather than an instance: `withLoad(loc:logger:)` for the 39 admin catch blocks (closes L-31 and the D1 backlog together), `withLiveness(gen:)` for the 15 hand-repeated player guards, and a `releaseServerSession(_:)` chokepoint every PlaybackInfo replacement must route through.
- Cite prior findings by label when re-reporting. Four items in this pass (M-11, M-14, L-31, and the README half of L-38) were re-discovered independently without reference to their 2026-07-06 originals; the fact that they are unchanged after two audits is more actionable information than the findings themselves.
- Two things need a Mac to close and neither can be done statically: confirm whether `NWParameters.allowLocalEndpointReuse` maps to SO_REUSEADDR (harmless) or SO_REUSEPORT (in which case a co-resident process could bind the proxy's port and receive token-bearing requests — that would be a high-severity finding, not a low one); and confirm the Keychain access-group placement in M-15 on a signed build before writing the migration.

---

## Verified healthy (51)

Subsystems specifically checked and found **correct**. Recorded deliberately: knowing what was verified is as useful as knowing what failed, and it prevents a future audit re-litigating them.

- Loopback stream proxy security core: `route` rejects dot-segments AND any component decoding to a separator (so `%2E%2E%2Fsecret` is refused), `admission` exact-matches the loopback Host (defeating `localhost.evil.com`-style rebinding, and the host check runs before the method check so a probe cannot learn its host was accepted), only GET/HEAD are forwarded upstream, the listener binds `requiredInterfaceType = .loopback`, the request head is capped at 64 KB, and targets are keyed by unguessable UUIDv4 and bounded to 6. StreamProxyTests holds 13 tests over exactly these traps, including the full HLS master→variant→segment round-trip and sub-path-hosted base-path preservation.
- No SSRF in the proxy: the upstream origin is never derived from the request — an unknown id answers 502 before any URLRequest exists.
- The proxy's URLSession uses a concurrent delegate queue (maxConcurrentOperationCount = 8) as its blocking-backpressure design requires, so MKV seek requests cannot head-of-line-block behind the main stream.
- JellyfinAPIClient lock discipline is exact: all six `nonisolated(unsafe)` fields are reachable only through locked accessors, no `await` occurs inside any critical section, `serverSupports` does not re-enter the lock, and no call site across the seven `+` extension files bypasses the accessors.
- APICache.coalesce registers the in-flight Task synchronously under the lock before any suspension so a racing caller always joins, removes it via `defer` on success and failure so a thrown error cannot poison retries, and coalesces `getItem` at `T == Void` with a read-back so the non-Sendable BaseItemDto never crosses the boundary.
- APICache key construction is otherwise correct: every cached endpoint carries userId, and the rating-cap-sensitive ones either carry `getMaxContentAge()` in the key or apply `applyRatingFilter` on the read path. `userDataCachePrefixes` is genuinely swept by all three documented mutators.
- APICache's opportunistic expired-entry sweep on write is documented, deliberate and test-locked (`storedKeyCount` exists as a test hook; APICacheTests asserts it).
- Generation-token discipline is near-universal and was checked after EVERY await cluster, not just the first: MediaDetailViewModel.loadGeneration (13 re-checks), NowPlayingInfoController.generation (bumped in attach and detach, re-checked in both the enrich and artwork tasks), PlaybackLiveActivityController.generation + resolvedGeneration, VLCStreamPresenter.navGeneration, MenuConfigStore.refreshGeneration (including in the defer and the catch), VideoPlayerCoordinator.currentGeneration, TrickplayController.generation, PaginatedLoader.generation.
- PlaybackAudioSession is the single AVAudioSession owner (no other setCategory/setActive anywhere in the playback stack), `activate()` is awaited — never fire-and-forget — at all four media-opening paths with liveness guards on both sides of the hop, and PlayerEngineSurface passes `managesAudioSession: false`.
- PlaybackReporter owns the session lifecycle correctly: reportStop reports with liveStreamId and THEN stopEncoding, sequentially; the transcode keep-alive pings only when paused with a playSessionId and resets its counter on any unmet condition; positionTicks guards non-finite and saturates.
- CardPlayTargetResolver.ProbeRace is a correct single-resume continuation guard (outcome taken under NSLock with `defer { continuation = nil }`, resumed outside the lock), the loser is deliberately not cancelled so the nextup cache still warms, and only Sendable scalars cross the boundary. F-54 fixed.
- OptimisticFlag carries both the server value it derives from and a 20 s expiry, and all three consumers (label, play entries, resolvedCardPlayTarget) read the same resolved value. F-52 fixed.
- MediaCardContextMenu's F-46 mitigation is fully intact: scalars-only CardMenuItem so no escaping closure captures a DTO, standalone CardMenuContent/CardArtworkPreview views so lookups are deferred, and `forwardingEnvironment` re-injecting the objects the contextMenu presentation context drops. The knownRemoteTargetCount writer now has both its equality guard and a generation check (F-47 fixed).
- PaginatedLoader.refreshLoadedSpan does exactly what its doc claims — one request from index 0 for `items.count`, identity and scroll position preserved, hasLoadedAll re-derived from the fresh total, generation-guarded on both paths — and is now wired on all three surfaces including MediaLibraryScreen's filtered grid (F-8 fixed).
- MediaLibraryScreen's two-tier refresh is correct: tier-2 answers with refreshHeroNavigation() in browse mode and refreshLoadedSpan in grid mode, never a full reload, and both defer behind `isVisible`.
- Every card that clips a fill-scaled image carries `.contentShape(Rectangle())` right after the clip (PosterCard, WideCard, LibraryPosterCard), closing the long-press hit-test regression on all three.
- SeekSettleTracker keeps its baseline until the 120 ms threshold is actually crossed (the sampling-rate-independence fix), and SeekCoalescer's clamp/relativeTarget saturate through Int32(clamping:) and honour the 250 ms end guard. PlaybackEndPolicy implements the documented three-way reading exactly, with `.unexpectedStop` routed into handlePlaybackError.
- noteMediaOpened() is the sole renewer of the retry budget and `.playing` explicitly does not renew it; clearLoadingIfOpen() is gated on mediaConfirmedOpen and all four fresh-open paths route through beginOpenLoading(). scrubberChanged's `guard slider.isTracking` is the first statement, before both writes.
- Both documented overlay hit-testing fixes are present: loadingIndicator and statsContainer both set `isUserInteractionEnabled = false`, so neither creates a dead zone for swipe-to-dismiss or hold-to-2×.
- paintPosition/writeTimeLabels gating is intact — writeTimeLabels is the sole label writer, paintPosition early-returns on hidden controls and on an unchanged whole second, and the partial iOS drag write correctly nils lastPaintedPosition.
- TrickplayController forces its decode off the main actor via preparingForDisplay() (F-26 fixed) and reResolveAndResume releases the superseded PlaybackInfo before overwriting it (F-28 fixed); fetchChapters correctly owns the pendingChapterThumbnails clear so the retry and wake paths keep their parked queue.
- RemoteCommandController.attach calls detach() first and detach() removes every target, so no duplicate MPRemoteCommandCenter targets accumulate across episode navigations.
- The extension session contract is Keychain-only and in sync across all three copies (service, account, group suffix, JSON key set), locked by ExtensionSessionContractTests; the legacy plaintext App-Group copy is gone and is actively scrubbed before publish's early-return. Prior finding S3 CLOSED.
- Both extensions send `Authorization: MediaBrowser Token=` as a header on every request they issue, on private ephemeral sessions with urlCache nil; the single api_key-in-URL case is the documented Top Shelf setImageURL path the system fetches. Neither extension reads UserDefaults at all.
- No token reaches a log: zero `print()` in Shared/Packages/Widgets/TopShelf, every URL-bearing log routes through `redactedURL`, and VLCEngineLog.scrubbed strips api_key from libVLC's own messages before OSLog.
- Keychain items all use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly — never synced to iCloud, never in backups. Logout scoping is correct: clearAll touches only the legacy trio, clearSession strips the active entry only, the registry survives, and the shared snapshot is deleted on both logout reasons.
- Server-side revocation and the per-server reachability probe are standalone and structurally unauthenticated (own ephemeral sessions, own MediaBrowser header, never the shared client), so a dead secondary server cannot drive the 401→logout machinery.
- No authenticated request rides URLSession.shared, and every authenticated session sets urlCache = nil (fastFailSessionConfiguration, playbackInfoSession, ServerReachability ×2, HLSManifestLoader, CinemaxStreamProxy, both extensions).
- No TLS or trust customization anywhere — zero URLAuthenticationChallenge/serverTrust implementations. ATS carries only NSAllowsLocalNetworking and NSAllowsArbitraryLoadsForMedia; never NSAllowsArbitraryLoads.
- Admin API-keys hardening matches its documented design: first-4/last-4 masking, `.privacySensitive()`, an explicit comment refusing `.textSelection(.enabled)` on the token, and UIPasteboard `.localOnly` + 60 s expiry as the only export path, with reveal state cleared on disappear.
- Item ids that drive navigation are shape-validated through one SSOT (`AppState.isValidItemId`, 32-char hex or canonical GUID), gating the public deep link, the authenticated remote-control play path and persisted Shortcuts identities. SessionSocket's parsers are pure, static, defensive and unit-tested; the App Intents composite (server, item) identity is enforced twice.
- ServerURLNormalizer restricts to http(s), lowercases scheme+host, drops credentials/query/fragment, preserves sub-paths and round-trips IPv6 literals; UDP-discovered addresses are never auto-dialled. ServerRegistry.upsert preserves the stored id and moves lastUsedAt forward only; `sorted` is a total order.
- AppState.serverTransitionGeneration is bumped by all six transition methods and re-checked after the awaits that need it; handlePossibleSessionExpiry sets its debounce before the first suspension, defers the reset, re-checks isAuthenticated && isOnline inside every retry, and logs out only on a server-confirmed `.invalid`.
- MenuConfigStore's "resolvedTabs never empty" invariant holds — the fallback is in computeResolvedTabs, every input mutator recomputes, the recompute is equality-guarded, and no input property carries a didSet. MainTabView's tvOS snapshot freeze is implemented exactly as documented, with iOS deliberately live.
- ServerVersion gating honours "unknown means unsupported" end to end, including clearing on reconnect and re-seeding on the fetchServerInfo cache hit, and its parser handles the 2-to-4 component forms plus `v` prefixes and rc/build suffixes.
- Every framework callback CLAUDE.md flags as previously-crashing is correctly annotated: the MPMediaItemArtwork handler is @Sendable, the AVAudioEngine installTap block is @Sendable capturing a nonisolated(unsafe) request, the speech result handler is @Sendable [weak self] extracting scalars before hopping, both TCC requests are bridged through nonisolated async + withCheckedContinuation, and NWPathMonitor extracts a Bool before hopping.
- Every `MainActor.assumeIsolated` sits behind a genuinely main-thread callback (main-queue periodic observers and notifications, AVKit delegate methods, and SwiftUI's main-actor view diff in the six nonisolated `==` implementations).
- SyncPlaySocket and SessionSocket are structurally identical actors and reentrancy-clean: isStopped re-checked at both loop levels, the ws handle held as a local, continuation.finish() idempotent, keepAlive cancelled before every reconnect, and `messages` nonisolated off an immutable AsyncStream of Sendable elements.
- UpstreamHandler's @unchecked Sendable claim holds: `_task` is the only cross-queue field and it is NSLock-guarded; the other counters are reached only from per-task-serialised delegate callbacks; finish() is one-shot and handles the re-fired completion after a `.cancel` disposition.
- KeychainService.cachedDeviceID's nonisolated(unsafe) static is fully guarded by deviceIDLock; HLSManifestLoader's @unchecked Sendable holds only `let`s; the device-profile static arrays are immutable.
- No blocking dispatch anywhere else in the codebase: zero `DispatchQueue.global` and zero `.sync {` across Shared/ and Packages/; the two getaddrinfo sites are the only executor-blocking calls.
- IntentSessionProvider builds a fresh client and never calls setOnUnauthorized, so a scene-less Siri resolution cannot feed the app's 401→logout machinery; it correctly reads the registry entry rather than the legacy mirror and refuses when activeServerId is absent.
- Localization integrity is exact: 796 keys in each of fr/en with an empty symmetric difference, all 729 distinct `loc.localized` keys present in both tables, printf placeholder shapes matching on every key (0 mismatches), and the hardcoded-string sweep returning only bullet glyphs and the two intentional layout placeholders. All 9 keys with no bare literal are read via interpolation. Siri phrases match the CinemaxShortcuts literals character for character, all carry ${applicationName}, and only AppEntity parameters are interpolated.
- No raw `localizedDescription` reaches a user-facing surface — the only two non-logging occurrences in Shared/ and Packages/ are doc comments.
- Crash-risk sweep outside the player is clean: zero `try!`, zero `as!`, 4 force unwraps total, every implicitly-unwrapped optional confined to the player presenters, and every computed-index subscript guarded. The documented ForEach-over-index-snapshot crash class has not regressed — the only two index-based ForEach sites iterate locally-built arrays.
- Fan-out is bounded at the documented chunk of 6 in all three app-level fan-outs, and LibrarySearchRanker caps at 5 concurrent terms. JSON decoding never runs on the main actor (JellyfinAPIClient is a plain Sendable class, so its async methods run on the cooperative pool).
- No unbounded accumulator in the networking/caching layer: proxy targets bounded to 6 and cleared on stop, trickplay tiles behind an NSCache with a 64 MB cost limit, chapter-thumb tasks cancelled and emptied at teardown and re-fetch.
- Compliance surface is in good shape on all three binaries: per-binary PrivacyInfo.xcprivacy (all lint-clean, NSPrivacyTracking false, empty collected-data types), no undeclared required-reason API in use (SystemBootTime / DiskSpace / FileTimestamp / ActiveKeyboards all clean by grep), ITSAppUsesNonExemptEncryption declared on both apps, usage descriptions complete and localized in both InfoPlist.strings, App Group and shared Keychain group consistent across all four targets with AppIdentifierPrefix injected rather than hardcoded, and MARKETING_VERSION/CURRENT_PROJECT_VERSION single-sourced in project.yml.
- Test breadth is better than the file count suggests: 54 @Suite declarations and 456 @Test cases across 36 files, and every "Locked by <X>" claim in CLAUDE.md resolves to a real suite. CinemaxTests correctly omits `package: CinemaxKit`, honouring the documented double-link rule. MockAPIClient conforms to the full protocol, guards its call recording with an NSLock (with the reasoning documented), and exposes per-call handlers for delay/cancellation injection.
- CI build hygiene is correct: iOS and tvOS build serially (avoiding the documented DerivedData race) and both use `set -o pipefail`. xcodegen is pinned identically in both workflows via the official release zip, and the pbxproj drift verification the prior audit asked for now exists. The pre-commit hook is sound: it backs up the working copy, installs an EXIT trap that restores it on every path, and degrades safely where xcodegen is unavailable.
- Only one TODO/FIXME/HACK remains in the entire codebase, and it matches the documented v2 scope. Prior finding D3 was properly fixed.
