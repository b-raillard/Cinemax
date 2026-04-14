# Cinemax - App Store Readiness Audit & Future Roadmap

**Date**: 2026-04-14
**Scope**: Full audit for Apple App Store submission (iOS + tvOS) + future feature roadmap

---

## Part 1: App Store Compliance Audit

### 1.1 Privacy Manifest (BLOCKER)

**Status**: MISSING — `PrivacyInfo.xcprivacy` does not exist.

Since April 2024, Apple **requires** a privacy manifest for all App Store submissions. Without it, the app will be **rejected at submission**.

**Required declarations**:
- `NSPrivacyAccessedAPICategoryUserDefaults` — app uses `@AppStorage` / `UserDefaults` extensively
- `NSPrivacyAccessedAPICategorySystemBootTime` — if any dependency uses `ProcessInfo.processInfo.systemUptime`
- `NSPrivacyCollectedDataTypes` — declare that zero tracking data is collected
- `NSPrivacyTracking: false`
- Third-party SDK manifests: Nuke and jellyfin-sdk-swift should be checked for their own privacy manifests

**Action**: Create `PrivacyInfo.xcprivacy` for both iOS and tvOS targets.

---

### 1.2 Third-Party License Attribution (BLOCKER)

**Status**: MISSING — No OSS license attribution anywhere in the app.

Apple requires that apps comply with the licenses of their dependencies. All three dependencies use MIT licenses:
- `jellyfin-sdk-swift` (MIT)
- `Nuke` / `NukeUI` (MIT)
- `Get` (MIT, transitive)

**Action**: Add an "Acknowledgements" / "Licences" section in Settings, or bundle a `LICENSES.txt` file accessible from the app.

---

### 1.3 App Icons

| Platform | Status | Notes |
|----------|--------|-------|
| iOS | OK | 1024x1024 universal + dark + tinted variants. Xcode auto-generates smaller sizes. |
| tvOS | OK | Full image stack (large/small icons), Top Shelf (1920x720), Top Shelf Wide (2320x720). |

---

### 1.4 Info.plist & Usage Descriptions

| Key | iOS | tvOS | Status |
|-----|-----|------|--------|
| `NSMicrophoneUsageDescription` | Present | N/A | OK |
| `NSSpeechRecognitionUsageDescription` | Present | N/A | OK |
| `NSAppTransportSecurity` | Configured | Configured | OK (see Security section) |
| `UILaunchScreen` | Empty dict (valid) | N/A | OK |
| `CFBundleShortVersionString` | 1.0.0 | 1.0.0 | OK |

---

### 1.5 Bundle Identifiers & Signing

| Item | Value | Status |
|------|-------|--------|
| iOS bundle ID | `com.cinemax.ios` | OK |
| tvOS bundle ID | `com.cinemax.tvos` | OK |
| Code signing | `iPhone Developer` only | Needs distribution certificate + provisioning profiles |

**Action**: Configure App Store distribution signing before archive/upload.

---

### 1.6 Deployment Targets

| Platform | Target | Notes |
|----------|--------|-------|
| iOS | 18.0 | Aggressive — excludes iOS 17 users (~30% of devices as of early 2026) |
| tvOS | 26.0 | Very aggressive — limits audience to latest Apple TV firmware |
| CinemaxKit Package.swift | tvOS 18.0 | **MISMATCH** with project.yml's tvOS 26.0 |

**Action**: Fix the tvOS deployment target mismatch between `project.yml` (26.0) and `Package.swift` (18.0). Consider lowering iOS to 17.0 for broader reach.

---

### 1.7 Entitlements

No `.entitlements` files — appropriate since the app doesn't use push notifications, HealthKit, HomeKit, etc. If you add features like background audio or push notifications later, entitlements files will be needed.

---

### 1.8 App Review Guidelines — Potential Flags

| Guideline | Risk | Details |
|-----------|------|---------|
| 4.0 Design | Low | Custom design system is polished and consistent |
| 4.1 Copycats | Low | Original UI, not copying Netflix/Plex UI |
| 4.2 Minimum Functionality | Medium | App requires a Jellyfin server — reviewer must be able to test. Provide a demo server URL in review notes |
| 4.3 Spam | None | Single-purpose media client |
| 5.1 Privacy | HIGH | Missing privacy manifest (see 1.1) |
| 2.1 Performance | Low | No crashes found in audit, but force unwraps exist |
| 2.3 Accurate Metadata | N/A | Ensure App Store description accurately describes Jellyfin requirement |

**Action**: Prepare App Review notes with a demo Jellyfin server URL and credentials for the reviewer, or provide screenshots/video of the app in use.

---

## Part 2: Security Audit

### 2.1 Issues Carried from Previous Audit (Audit.md)

| Severity | Issue | Status |
|----------|-------|--------|
| Critical | Auth token logged in production (`VideoPlayerView.swift:797`) | **Still open** |
| High | Weak ATS — HTTP allowed for media | Open (required for LAN servers) |
| High | No TLS certificate pinning | Open |
| Medium | Password not cleared after login | **Still open** |
| Medium | Token in error messages | **Still open** |
| Medium | No search input sanitization | Open |

### 2.2 Additional Findings

| Severity | Issue | Details |
|----------|-------|---------|
| Medium | Force unwraps in URL construction | `AppNavigation.swift:10,28,30`, `ImageURLBuilder.swift:22,32,47,60`, `JellyfinAPIClient.swift:470,571` — potential crashes on malformed URLs |
| Low | No biometric auth option | Users must re-enter credentials if Keychain is cleared |
| Low | No session expiry/timeout | Token persists indefinitely in Keychain |
| Info | Keychain implementation is solid | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, proper cleanup on logout |
| Info | No hardcoded secrets found | Clean |
| Info | Device ID properly in Keychain | Migrated from UserDefaults |

---

## Part 3: Performance & Stability Audit

### 3.1 Issues Carried from Previous Audit

| Priority | Issue | Status |
|----------|-------|--------|
| High | O(n^2) episode navigation in view body | **Fixed** — precomputed maps now in ViewModel |
| High | No Nuke cache configuration | **Fixed** — 500 MB disk cache configured |
| High | Image size mismatch (always 1920px) | **Fixed** — `ImageURLBuilder.screenPixelWidth` now used |
| Medium | Race condition on season selection | **Fixed** — generation counter added |
| Medium | Missing task cancellation in coordinator | **Still open** |

### 3.2 Remaining Performance Concerns

| Priority | Issue | Details |
|----------|-------|---------|
| Medium | Sequential API calls in `MediaDetailViewModel` | Series load does seasons → episodes → nextUp sequentially. Could use `async let` for parallelism |
| Medium | `ContentRow` builds all item views upfront | `LazyHStack` defers rendering but not view creation |
| Medium | `.onAppear` pagination can fire multiple times | Consider debounce or threshold-based approach |
| Low | Computed adaptive sizing in `HomeScreen` | Called multiple times per layout pass |

---

## Part 4: UX & HIG Compliance

### 4.1 Accessibility (HIGH PRIORITY for App Store)

| Issue | Severity | Details |
|-------|----------|---------|
| Dynamic Type not respected | High | App uses custom `uiScale` (80-130%) but ignores iOS system Dynamic Type (accessibility sizes A-XXXXL). Apple reviewers test this. |
| Missing accessibility labels | Medium | Many interactive elements (poster cards, wide cards, buttons) lack `.accessibilityLabel`. Only ~10 labels found across the entire app. |
| Missing accessibility hints | Medium | No `.accessibilityHint` on any element |
| Missing accessibility traits | Low | Few `.accessibilityAddTraits` beyond one `.isHeader` in SearchScreen |
| No VoiceOver testing evidence | Medium | Screen readers likely can't navigate the app effectively |

**Action**: This is the single largest App Store risk after the privacy manifest. Apple frequently tests accessibility. At minimum, add labels to all interactive elements and images.

### 4.2 Platform-Specific UX

| Area | iOS | tvOS |
|------|-----|------|
| Focus engine | N/A | Good — `@FocusState` + custom focus styles |
| Siri Remote | N/A | Partial — Menu button works, no swipe gesture support |
| Dark/Light mode | Excellent | Excellent |
| Safe areas | Excellent | Excellent |
| Orientation | All orientations | N/A (landscape) |
| Haptic feedback | Not implemented | N/A |
| iPad layout | Good — split view support | N/A |
| Search | Custom (no `.searchable()`) | Custom |

### 4.3 Missing App Lifecycle Handling

| Issue | Impact |
|-------|--------|
| No `scenePhase` observation | Video doesn't pause when app backgrounds |
| No background task handling | No cleanup on termination |
| No state restoration | Tabs/position not preserved across launches |

---

## Part 5: Build & Infrastructure

### 5.1 Issues

| Priority | Issue | Details |
|----------|-------|---------|
| High | No CI/CD pipeline | No GitHub Actions, Fastlane, or automated builds |
| High | No SwiftLint/SwiftFormat | No automated code style enforcement |
| Medium | tvOS has no test target | Only iOS has `CinemaxTests` |
| Medium | Limited test coverage | 26 test methods total — covers ViewModels only |
| Low | No Fastlane for release automation | Manual archive/upload required |

### 5.2 Dead Code (from Audit.md)

| Item | Size | Status |
|------|------|--------|
| Legacy custom tvOS player (6 files) | 1,027 lines | **Still present — delete before submission** |
| Unused localization keys | 33 keys | Still present — clean up |

---

## Part 6: Pre-Submission Checklist

### Must-Fix (Blockers)

- [x] Create `PrivacyInfo.xcprivacy` for both targets — **DONE** (Resources/PrivacyInfo.xcprivacy)
- [x] Add third-party license attribution (Settings page or bundled file) — **DONE** (LicensesView.swift)
- [x] Fix tvOS deployment target mismatch (project.yml vs Package.swift) — **DONE** (audit 1.1.1: Package.swift updated to tvOS v26)
- [ ] Configure App Store distribution signing (certificates + profiles)
- [x] Guard auth token log with `#if DEBUG` — **DONE** (already fixed in prior audit)
- [x] Delete 6 dead custom tvOS player files — **DONE** (already fixed in prior audit)
- [ ] Prepare demo Jellyfin server for App Review

### Should-Fix (High Risk of Rejection)

- [x] Add accessibility labels to all interactive elements (cards, buttons, rows) — **DONE** (audit 1.1.1)
- [x] Add accessibility labels to all images (poster cards, backdrops) — **DONE** (audit 1.1.1: decorative images hidden, cards labeled)
- [ ] Respect iOS Dynamic Type settings (or document custom scaling)
- [x] Clear password from memory after login — **DONE** (already fixed in prior audit)
- [x] Handle `scenePhase` — pause playback on background — **DONE** (audit 1.1.1: reports progress on background)
- [x] Remove 33 unused localization keys — **DONE** (already fixed in prior audit)
- [ ] Replace force unwraps with safe unwrapping in URL construction

### Nice-to-Fix (Improve Quality)

- [ ] Add haptic feedback on iOS interactions
- [ ] Implement `.searchable()` modifier on iOS
- [ ] Cancel previous task in `VideoPlayerCoordinator.play()`
- [ ] Parallelize API calls in `MediaDetailViewModel`
- [ ] Add SwiftLint configuration
- [ ] Set up basic CI (GitHub Actions for build verification)
- [ ] Add tvOS test target

---

---

## Part 7: Future Roadmap

### Priority 1 — Core Features (Next Release)

| Feature | Description | Platform |
|---------|-------------|----------|
| **Offline Downloads** | Download movies/episodes for offline viewing. Requires background download sessions, local storage management, DRM handling. Major feature for mobile users. | iOS |
| **Push Notifications** | Notify users when new content is added to their Jellyfin library. Requires server-side webhook + APNs integration. | iOS |
| **User Profiles / Multi-User** | Support multiple Jellyfin users on the same device with quick-switch. Currently single-session only. | Both |
| **Watchlist / Favorites** | Mark items as favorites, create personal watchlists synced with Jellyfin's built-in favorites API. | Both |
| **Multiple Servers** | Connect to multiple Jellyfin servers simultaneously, switch between them from Settings. Requires storing multiple `UserSession` entries in Keychain, a server picker UI, and scoping all API calls to the active server context. | Both |
| **Continue Watching Widget** | iOS Lock Screen / Home Screen widget showing resume items. WidgetKit + AppIntents. | iOS |
| **tvOS Top Shelf Extension** | Dynamic Top Shelf showing recently added or continue-watching content. WidgetKit + TVServices. | tvOS |

### Priority 2 — Enhanced Playback

| Feature | Description | Platform |
|---------|-------------|----------|
| **Picture-in-Picture** | PiP support for multitasking on iOS/iPad. AVPlayerViewController supports this natively. | iOS |
| **AirPlay** | Cast to Apple TV or AirPlay-compatible devices from iOS app. | iOS |
| **Chapters Support** | Display chapter markers in the player scrubber from Jellyfin chapter data. | Both |
| **Skip Intro/Credits** | Detect and skip intro/credits using Jellyfin's intro detection plugin data. | Both |
| **Playback Speed** | 0.5x, 0.75x, 1x, 1.25x, 1.5x, 2x playback speed control. | Both |
| **Subtitle Timing Offset** | Adjust subtitle display timing with +/- seconds controls (e.g. +0.5s, -1s) to fix out-of-sync subtitles. Applies a time offset to the selected subtitle track in the player. | Both |
| **External Subtitle Files** | Support loading `.srt`/`.ass` subtitle files from device storage. | iOS |
| **Audio Output Selection** | Choose audio output device (Bluetooth headphones, HomePod, etc.) from within the player. | iOS |

### Priority 3 — Discovery & Social

| Feature | Description | Platform |
|---------|-------------|----------|
| **Collections / Playlists** | Browse and play Jellyfin collections and playlists. | Both |
| **Genre/Mood Browsing** | Dedicated genre pages with curated rows (similar to Netflix genre pages). | Both |
| **Actor/Director Pages** | Tap on a person → see all their movies/shows in the library. | Both |
| **Spotlight Search** | Index library content in iOS Spotlight for system-wide search. `CoreSpotlight` integration. | iOS |
| **Siri Shortcuts** | "Hey Siri, play [movie name] on Cinemax" — SiriKit Media Intents. | iOS |
| **Recommendations API** | Feed into tvOS system recommendations for the TV app. | tvOS |
| **Recently Added Notifications** | In-app notification banner when new content appears. | Both |

### Priority 4 — Polish & Platform Features

| Feature | Description | Platform |
|---------|-------------|----------|
| **SharePlay** | Watch together via FaceTime with synchronized playback. | iOS |
| **Handoff / Continuity** | Start watching on iPhone, continue on Apple TV (and vice versa). | Both |
| **Server Discovery (mDNS)** | Auto-discover Jellyfin servers on the local network via Bonjour/mDNS. | Both |
| **Parental Controls** | Content filtering by rating, PIN-protected profiles. | Both |
| **Watch History** | Full watch history view with date/time stamps. | Both |
| **Statistics** | Personal viewing stats (hours watched, genres, etc.). | Both |
| **App Clips** | Share a media item link → App Clip shows trailer/info with "Get Full App" CTA. | iOS |
| **CarPlay** | Audio-only content (music, audiobooks) playback via CarPlay. | iOS |

### Priority 5 — Advanced / Long-term

| Feature | Description | Platform |
|---------|-------------|----------|
| **Live TV & DVR** | Jellyfin Live TV support with EPG guide, recording management. | Both |
| **Music Playback** | Full music library browsing and playback (Jellyfin supports music). | Both |
| **Photo Browsing** | Browse and display photo libraries from Jellyfin. | Both |
| **macOS / Catalyst** | Native macOS app via Mac Catalyst or dedicated SwiftUI target. | macOS |
| **visionOS** | Immersive media viewing experience for Apple Vision Pro. | visionOS |
| **Sync Play** | Jellyfin SyncPlay integration — synchronized group watching over network. | Both |
| **Admin Panel** | When the authenticated user has admin role (`policy.isAdministrator`), show an admin section in Settings with: server dashboard (active streams, transcoding status), user management (create/edit/delete users, reset passwords, assign permissions), library management (trigger scans, manage libraries), scheduled tasks, server logs, and plugin management. Gate all admin UI behind role check. | Both |
| **Custom Server Dashboards** | View server status, active streams, user activity (admin feature). | Both |
| **Jellyfin Plugin Integration** | Support popular plugins: intro detection, TMDb metadata, etc. | Both |
| **Multi-Platform Servers (Plex, Emby)** | Abstract the networking layer behind a server-agnostic protocol so Cinemax can connect to Plex, Emby, and other media servers in addition to Jellyfin. Requires a `MediaServerProtocol` abstraction over authentication, library browsing, metadata, playback info, and reporting — with platform-specific adapters (`JellyfinAdapter`, `PlexAdapter`, `EmbyAdapter`). Major architectural change. | Both |

### Technical Debt & Infrastructure

| Item | Description |
|------|-------------|
| **CI/CD Pipeline** | GitHub Actions: build on PR, run tests, lint, archive for TestFlight |
| **Fastlane** | Automate screenshots, TestFlight uploads, App Store submission |
| **Crash Reporting** | Integrate crash analytics (Firebase Crashlytics, Sentry, or TelemetryDeck for privacy) |
| **Analytics** | Privacy-respecting usage analytics (TelemetryDeck) to understand feature usage |
| **Unit Test Coverage** | Target 60%+ coverage on ViewModels and networking layer |
| **UI Tests** | XCUITest suite for critical flows (login, browse, play) |
| **Snapshot Tests** | Point-free SnapshotTesting for design regression detection |
| **Localization Expansion** | Add German, Spanish, Italian, Portuguese, Japanese, Chinese |
| **SwiftLint + SwiftFormat** | Enforce consistent code style across the project |
| **Modularization** | Extract features into separate Swift packages for build time and testability |
| **Documentation** | Generate DocC documentation for CinemaxKit public API |

---

## Summary

### App Store Readiness: 7/10

The app is functionally complete and well-architected. The primary blockers are:
1. **Missing privacy manifest** (automatic rejection)
2. **Missing OSS license attribution** (legal compliance)
3. **Weak accessibility** (common rejection reason)

The security posture is reasonable for a v1.0 media client connecting to user-owned servers. The design system is consistent and the codebase is clean. After addressing the blockers and high-priority items in the checklist, the app should be ready for submission.

### Estimated Effort to Ship v1.0

| Category | Effort |
|----------|--------|
| Privacy manifest + licenses | 2-3 hours |
| Accessibility pass | 1-2 days |
| Security fixes (token log, password clear) | 1 hour |
| Dead code cleanup | 30 minutes |
| Scene phase + lifecycle | 2-3 hours |
| Signing + TestFlight setup | 2-3 hours |
| App Store metadata + screenshots | 1 day |
| **Total** | **~3-4 days** |
