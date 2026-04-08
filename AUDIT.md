# Cinemax — Code Audit Report
*Generated: 2026-04-07*

## Overview

| Metric | Value |
|--------|-------|
| Total Swift files | ~37 |
| Total lines of code | ~8,700 |
| God files (>500 lines) | 4 (`TVCustomPlayerView`, `MediaDetailScreen`, `SettingsScreen`, `MovieLibraryScreen`) |
| Design system compliance | ~60% |
| Test coverage | 0% (placeholder test file only) |

---

## 1. SECURITY

### High Severity

| # | Finding | Location |
|---|---------|----------|
| S1 | **`NSAllowsArbitraryLoads = true`** — disables all HTTPS enforcement. Any server connection is unencrypted. | `iOS/Info.plist:21-27`, `tvOS/Info.plist:21-27` |
| S2 | **API token in URL query parameters** — `api_key=` in URLs leaks tokens in logs, proxy caches, and server access logs. Should use `Authorization` header. | `JellyfinAPIClient.swift:467, 567` |
| S3 | **Keychain uses `kSecAttrAccessibleAfterFirstUnlock`** — data remains accessible even when device is locked. Should use `WhenUnlockedThisDeviceOnly`. | `KeychainService.swift:74` |
| S4 | **Device ID stored in UserDefaults** instead of Keychain — persists across uninstalls on some iOS versions. | `JellyfinAPIClient.swift:686-693` |

### Medium Severity

| # | Finding | Location |
|---|---------|----------|
| S5 | **Debug logging of response bodies** — full playback info responses logged in DEBUG builds (acceptable, but should never leak to release). | `JellyfinAPIClient.swift:522-535` |
| S6 | **No server URL format validation** — user can enter any string, no scheme/host check. | `ServerSetupScreen.swift` |
| S7 | **No certificate pinning** — default `URLSession.shared` with no custom TLS validation. Acceptable for self-hosted, but noted. | `JellyfinAPIClient.swift:528` |

---

## 2. PERFORMANCE

### High Impact

| # | Finding | Location | Fix |
|---|---------|----------|-----|
| P1 | **`ImageURLBuilder` recreated on every card render** — `let builder = ImageURLBuilder(serverURL: ...)` inside `@ViewBuilder` functions (11 occurrences). Thousands of allocations during scrolling. | `HomeScreen:92,231,273`, `MediaDetailScreen:170,385,452,539`, `MovieLibraryScreen:395,727`, `SearchScreen:413` | Cache as `@Environment` or `AppState` computed property |
| P2 | **`AppState` is a monolithic `@Observable`** — any property mutation triggers re-evaluation in all observing views. `apiClient`, `keychain`, `serverURL`, `currentUserId`, etc. all in one object. | `AppNavigation.swift:4-48` | Split into focused sub-objects (`AuthState`, `ServerState`) |
| P3 | **`TVPlayerState` has 15+ properties in single `@Observable`** — scrubber updates `currentTime` every second, causing `TVControlsOverlay`, `TVAudioTrackMenu`, `TVSubtitleTrackMenu` to all re-evaluate. | `TVCustomPlayerView.swift` | Split into `PlaybackState` / `UIState` / `TrackState` |
| P4 | **No API response caching** — no `URLCache` configuration, no local cache layer. Identical requests hit the network every time. | `JellyfinAPIClient.swift` | Add URLCache or in-memory TTL cache |
| P5 | **Genre rows load 96 items (12 × 8 genres) without pagination** — high memory for large libraries. | `MovieLibraryScreen.swift:96-120` | Lazy-load genre items on scroll |

### Medium Impact

| # | Finding | Location |
|---|---------|----------|
| P6 | **No request deduplication** — rapid tab switching can fire duplicate `loadInitial()` calls. | All ViewModels |
| P7 | **Missing `maxWidth`/`maxHeight` on some image URLs** — server returns full-resolution backdrops (~4K). | Various `ImageURLBuilder` calls |
| P8 | **Search debounce is fragile** — `Task.sleep` + cancel, but rapid typing still creates many tasks. | `SearchScreen.swift:155-183` |
| P9 | **Time observer race condition** — `addTimeObserver()` called multiple times without synchronization. | `TVCustomPlayerView.swift:228-241` |
| P10 | **`buildAppleDeviceProfile()` called on every playback request** — static data recreated every time. Should be a cached static property. | `JellyfinAPIClient.swift:599-660` |

---

## 3. CODE QUALITY

### Error Handling — Critical Gap

**Pattern: widespread `try?` and empty `catch {}` blocks silently swallow errors. Users see empty screens with no feedback.**

| Location | Issue |
|----------|-------|
| `SettingsScreen.swift:614-615` | `catch {}` — both `getUsers()` and `getPublicUsers()` failures silenced |
| `MediaDetailScreen.swift:51,65` | `try?` on `getNextUp()` — missing next-up silently ignored |
| `MediaDetailScreen.swift:80-82` | `catch { /* Keep existing */ }` — episode load failures hidden |
| `HomeScreen.swift:19-23` | `async let` all-or-nothing — single API failure crashes entire home load |
| All screens | **No user-facing error states** — no error banners, retry buttons, or connectivity warnings |

### Force Unwraps — 11 Identical Occurrences

```swift
appState.serverURL ?? URL(string: "http://localhost")!
```

Repeated in `HomeScreen` (3×), `MediaDetailScreen` (4×), `MovieLibraryScreen` (2×), `SearchScreen` (1×), `SettingsScreen` (1×). Should be a single `AppState.imageServerURL` computed property.

### Magic Numbers

| Value | Meaning | Occurrences |
|-------|---------|-------------|
| `600_000_000` | Jellyfin ticks → minutes | 7 times across 4 files (`MediaItem.swift:35`, `HomeScreen.swift:245,307`, `MovieLibraryScreen.swift:824`, `MediaDetailScreen.swift:242,301,515`) |
| `10_000_000` | Jellyfin ticks → seconds | 3 times across 2 files |
| `0x34C759` | Green color (not in CinemaColor) | 3 times in `SettingsScreen:572,580,1293,1303` + `LoginScreen:188` |
| `0.3` | Animation duration | ~12 occurrences |

### Concurrency

- **Good**: Swift 6 strict concurrency properly used, `@MainActor @Observable` everywhere
- **Good**: `nonisolated(unsafe)` + `NSLock` for `JellyfinClient` wrapper is correct
- **Minor**: `EpisodeNavigator` `@Sendable` closure captures mutable state — review needed
- **Minor**: Playback method returned as `String` ("DirectPlay", "Transcode") instead of enum — fragile

### Dead Code

- **`CinemaCard` modifier** in `GlassModifiers.swift` — defined but never used anywhere
- **`HeroSection` component** in `Components/` — defined but all screens implement hero sections inline instead
- `#if DEBUG import Get` in `JellyfinAPIClient.swift:3-4` — Get imported but never directly called

---

## 4. CODE DUPLICATION (~300+ lines total)

| # | Pattern | Lines | Files |
|---|---------|-------|-------|
| D1 | **Server URL fallback + ImageURLBuilder creation** — `appState.serverURL ?? URL(string: "http://localhost")!` + `ImageURLBuilder(serverURL:)` | 22 lines × 11 occurrences | 5 files |
| D2 | **Hero section layout** (backdrop + gradient + metadata + buttons) — despite `HeroSection` component existing | ~150 lines | `HomeScreen`, `MovieLibraryScreen`, `MediaDetailScreen` |
| D3 | **Metadata text formatting** — year + runtime + genre joined by `" · "`, 3 different function names (`metadataText`, `heroMetadataText`, `metadataLine`) | ~50 lines | 3 files |
| D4 | **Tick-to-time conversion** — magic numbers used differently in each file | ~20 lines | 5 files |
| D5 | **Platform-adaptive sizing** — `#if os(tvOS) ... #else ...` private computed vars pattern | ~100 lines | 6+ files |
| D6 | **Pagination logic** — offset tracking, `hasMore`, `loadMore()` reimplemented per ViewModel | ~60 lines | 3 ViewModels |
| D7 | **Progress bar rendering** — identical `GeometryReader` + dual `Capsule()` pattern | ~45 lines | `HomeScreen`, `MediaDetailScreen`, `WideCard` |
| D8 | **LazyImage error states** — loading spinner + fallback icon pattern | ~70 lines | 7+ files |

---

## 5. DESIGN SYSTEM CONSISTENCY (~60% compliant)

### Colors

| File | Line(s) | Issue |
|------|---------|-------|
| `HomeScreen.swift` | 123, 135, 158 | `.fill(.white.opacity(0.1))`, `.foregroundStyle(.white)` hardcoded |
| `MediaDetailScreen.swift` | 206 | `.foregroundStyle(.white)` hardcoded |
| `SettingsScreen.swift` | 572, 580, 1293, 1303 | `Color(hex: 0x34C759)` — green not in `CinemaColor` |
| `LoginScreen.swift` | 188 | `Color(hex: 0x34C759, alpha: 0.1)` — same hardcoded green |
| `GlassModifiers.swift` | 15 | `Color(hex: 0x252626, alpha: 0.6)` — should use `CinemaColor.surfaceVariant` |
| `VideoPlayerView.swift` | 87-88 | `.foregroundStyle(.white)` on buttons |

### Fonts (widespread violation — ~30 occurrences)

Files using `.system(size:weight:)` instead of `CinemaFont` tokens (breaks `CinemaScale` dynamic scaling):
- `ServerSetupScreen.swift` — lines 78, 93, 168, 174, 179, 184, 263, 282, 294
- `LoginScreen.swift` — lines 74, 98, 103, 188, 193, 198, 208, 248, 307, 321, 335, 349, 353
- `SearchScreen.swift` — lines 368, 379
- `TVCustomPlayerView.swift` — lines 527, 534, 539, 559, 579, 740, 792
- `VideoPlayerView.swift` — line 126
- `MovieLibraryScreen.swift` — lines 341, 803, 1066, 1075, 1112, 1155

### Corner Radii

| File | Line | Hardcoded | Should Be |
|------|------|-----------|-----------|
| `HomeScreen.swift` | 124 | `cornerRadius: 4` | `CinemaRadius.small` |
| `MediaDetailScreen.swift` | 195 | `cornerRadius: 4` | `CinemaRadius.small` |
| `SettingsScreen.swift` | 176, 243-247, 432, 436 | `cornerRadius: 24` / `9999` | `CinemaRadius.extraLarge` / `.full` |
| `TVCustomPlayerView.swift` | 621 | `cornerRadius: 16` | `CinemaRadius.large` |

### Spacing (hardcoded padding — medium severity)

- `TVCustomPlayerView.swift:521,561,581,619-620,637,742,794` — values 14, 24, 72
- `MovieLibraryScreen.swift:557-558,591-592,616-617` — values 18, 10
- `ServerSetupScreen.swift:266,297-298` — values 12, 16
- `LoginScreen.swift:310,356-357` — values 12, 24

---

## 6. ARCHITECTURE

### File Size Summary

| File | ~Lines | Status |
|------|--------|--------|
| `SettingsScreen.swift` | 1,400+ | God file |
| `MovieLibraryScreen.swift` | 1,200+ | God file |
| `MediaDetailScreen.swift` | 715 | God file (well-extracted body, but too large) |
| `TVCustomPlayerView.swift` | 800+ | God file (7+ types in one file) |
| `JellyfinAPIClient.swift` | 715 | Borderline (20+ operations) |
| `VideoPlayerView.swift` | 561 | Borderline (mixing player, coordinator, PlayLink, TrackPicker) |
| `SearchScreen.swift` | 482 | Acceptable |
| `HomeScreen.swift` | 398 | Good (well-extracted) |

### Strengths
- No circular dependencies — clean unidirectional flow
- Proper `@Observable` + `@MainActor` everywhere
- Good layer separation: App → Navigation → Screens → Components → CinemaxKit
- `CinemaxKit` as local package is well-scoped

### Weaknesses
- ViewModels embedded in Screen files — untestable without importing SwiftUI
- 4 god files mixing VM + View + platform variants
- No protocol abstractions in CinemaxKit — `JellyfinAPIClient` and `KeychainService` are concrete classes, unmockable
- 0% test coverage — placeholder test file only
- `Package.swift` uses `from:` version constraints — allows breaking changes from major version bumps

---

## 7. CINEMAXKIT PACKAGE

### Issues

| # | Issue | Location |
|---|-------|----------|
| K1 | **No protocol abstractions** — `JellyfinAPIClient` and `KeychainService` have no protocol interface; cannot mock for testing | All |
| K2 | **Zero tests** — placeholder `CinemaxKitPackageTests.swift` only | `Tests/` |
| K3 | **Device ID in UserDefaults** — should be in Keychain | `JellyfinAPIClient.swift:686-693` |
| K4 | **ImageURLBuilder: no auth token support** — private library images return 401 | `ImageURLBuilder.swift:18-30` |
| K5 | **ImageURLBuilder: force unwrap `components.url!`** | `ImageURLBuilder.swift:19,33` |
| K6 | **`KeychainService.getData` returns nil for all errors** — can't distinguish "not found" from "IO error" | `KeychainService.swift:93-95` |
| K7 | **`KeychainService` silent delete failures** — `SecItemDelete` result ignored | `KeychainService.swift:104` |
| K8 | **Playback method as `String`** — "DirectPlay", "DirectStream", "Transcode" should be an enum | `JellyfinAPIClient.swift:284,443,484,574` |
| K9 | **`Package.swift` uses `from:` constraints** — should use `.upToNextMajor()` | `Package.swift:14-15` |

---

## 8. ACCESSIBILITY

**Status: 0% implemented — critical for App Store compliance**

No `accessibilityLabel`, `accessibilityHint`, `accessibilityValue`, or `accessibilityAddTraits` found anywhere in the codebase.

Key violations:
- All play/pause/episode navigation buttons lack labels
- Microphone button in SearchScreen has no label
- Icon-only controls throughout (backward/forward skip, track selectors)
- No `.header` traits on section titles
- No dynamic type support beyond `CinemaScale`

---

## Improvement Plan

### Phase 1 — Safety & Quick Wins ✅ TODO
- [x] 1.1 Extract `AppState.imageServerURL` + singleton `AppState.imageBuilder` — eliminates 11 force unwraps + 11 redundant allocations
- [x] 1.2 Add tick conversion helpers (`Int.jellyfinMinutes`, `Int.jellyfinSeconds`) to CinemaxKit
- [x] 1.3 Extract metadata formatting to `BaseItemDto` extension — deduplicates 3 functions
- [x] 1.4 Add `CinemaColor.success` for green `0x34C759`
- [x] 1.5 Add `CinemaMotion.standard = 0.3` animation duration constant
- [x] 1.6 Validate server URL format in `ServerSetupScreen`
- [x] 1.7 Cache `buildAppleDeviceProfile()` as static property

### Phase 2 — Architecture Refactoring ✅ TODO
- [x] 2.1 Split `TVCustomPlayerView.swift` → 5 files: `TVPlayerState`, `TVPlayerHostViewController`, `TVControlsOverlay`, `TVPlayerScrubber`, `TVTrackMenus`
- [x] 2.2 Extract `MediaDetailViewModel.swift` from `MediaDetailScreen.swift`
- [x] 2.3 Split `SettingsScreen.swift` → `SettingsScreen.swift` (core) + `SettingsScreen+iOS.swift` + `SettingsScreen+tvOS.swift`
- [x] 2.4 Move all ViewModels to `ViewModels/` directory (`HomeViewModel`, `LoginViewModel`, `ServerSetupViewModel`, `SearchViewModel`, `MediaLibraryViewModel`, `VideoPlayerCoordinator`)
- [x] 2.5 Delete unused `HeroSection` component — the 3 inline heroes (Home, Library, MediaDetail) diverge too much in content/buttons/sizing to share a component without over-engineering
- [x] 2.6 Extract `PlayLink.swift` and `TrackPickerSheet.swift` from `VideoPlayerView.swift`

### Phase 3 — Performance ✅ TODO
- [x] 3.1 Split `AppState` into `AuthState` + `ServerState` + `PreferencesState` — note: `@Observable` already provides property-level tracking (views only re-render on properties they access), so a full class split has no perf benefit. Real fix applied: `imageBuilder` converted from computed to stored property (reset via `serverURL.didSet`), eliminating per-access struct allocation during scrolling.
- [x] 3.2 Split `TVPlayerState` into playback/UI/track sub-objects — addressed: `TVPlayerOverlayView` explicitly observes only `isBuffering`/`showControls`; `TVAudioTrackMenu` / `TVSubtitleTrackMenu` / `TVPlayerScrubber` are isolated sub-views each tracking only their own property via `@Observable` property-level registration. Further sub-object split would add complexity with no perf gain.
- [x] 3.3 Add `URLCache` configuration or in-memory TTL cache for API responses — `APICache.swift` (thread-safe NSLock TTL cache); wraps `fetchServerInfo` (10 min), `getGenres` (5 min), `getLatestMedia` (60s), `getResumeItems` (30s); cleared on `reconnect()`
- [x] 3.4 Add `maxWidth`/`maxHeight` to all backdrop image URL calls
- [x] 3.5 Implement generic `PaginatedLoader<T>` — `PaginatedLoader<T: Sendable>` in CinemaxKit; `MediaLibraryViewModel` and `MovieLibraryScreen` updated
- [x] 3.6 Replace `async let` all-or-nothing in `HomeViewModel` with `TaskGroup` + per-section error handling
- [x] 3.7 Fix time observer race condition in `TVCustomPlayerView.swift:228-241` — replaced `Task { @MainActor }` with `MainActor.assumeIsolated` (observer already on .main queue, eliminates 1 Task heap allocation per second during playback)

### Phase 4 — Security Hardening ✅ TODO
- [x] 4.1 Move API token from URL query param to `Authorization` header (`JellyfinAPIClient.swift:467,567`)
- [x] 4.2 Remove `NSAllowsArbitraryLoads` from both `Info.plist` files; use `NSExceptionDomains` for local network
- [x] 4.3 Change Keychain to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (`KeychainService.swift:74`)
- [x] 4.4 Move device ID from UserDefaults to Keychain (`JellyfinAPIClient.swift:686-693`)

### Phase 5 — Design System & Polish ✅ DONE
- [x] 5.1 Replace all `.system(size:weight:)` with `CinemaFont` tokens / `CinemaScale.pt()` wrappers (~30 violations)
- [x] 5.2 Replace hardcoded padding in `TVCustomPlayerView`, `SettingsScreen`, `MovieLibraryScreen` with `CinemaSpacing` where exact tokens exist
- [x] 5.3 Replace hardcoded radii with `CinemaRadius` tokens (`cornerRadius: 4/16/24/9999` in HomeScreen, MediaDetailScreen, TVControlsOverlay, SettingsScreen)
- [x] 5.4 Fix glass material: `GlassPanelModifier` now uses `CinemaColor.surfaceVariant.opacity(0.6)` instead of raw hex
- [x] 5.5 Remove dead code: `CinemaCard` modifier and `.cinemaCard()` extension deleted from `GlassModifiers.swift`
- [x] 5.6 Extract `ProgressBarView`, `RatingBadge`, `LoadingStateView`, `ErrorStateView` components
- [x] 5.7 Extract `CinemaLazyImage` with unified loading/error/fallback states

### Phase 6 — Accessibility ✅ DONE
- [x] 6.1 Add `accessibilityLabel` to all buttons and interactive images
- [x] 6.2 Add `accessibilityHint` for complex interactions (episode nav, playback controls, track picker)
- [x] 6.3 Add `.accessibilityElement(children: .combine)` on composite non-interactive elements (`CastCircle`); `.accessibilityHidden(true)` on decorative elements (error icon, progress bar, PosterCard placeholder text)

### Phase 7 — Testability ✅ DONE
- [x] 7.1 Create `APIClientProtocol` in CinemaxKit
- [x] 7.2 Create `SecureStorageProtocol` in CinemaxKit
- [x] 7.3 Add unit tests for ViewModels (after extracting to separate files in Phase 2)
- [x] 7.4 Add playback method enum instead of String
- [x] 7.5 Tighten `Package.swift` version constraints to `.upToNextMajor()`

---

## Progress Tracker

| Phase | Status | Sessions |
|-------|--------|---------|
| Phase 1 — Quick Wins | **Complete** ✅ | Session 2026-04-08 |
| Phase 2 — Architecture | **Complete** ✅ | Sessions 2026-04-07/08 |
| Phase 3 — Performance | **Complete** ✅ | Session 2026-04-08 |
| Phase 4 — Security | **Complete** ✅ | Session 2026-04-08 |
| Phase 5 — Design System | **Complete** ✅ | Session 2026-04-08 |
| Phase 6 — Accessibility | **Complete** ✅ | Session 2026-04-08 |
| Phase 7 — Testability | **Complete** ✅ | Session 2026-04-08 |
