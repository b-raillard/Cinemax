# Cinemax - Jellyfin Client for Apple Platforms

## Project Overview
Native Jellyfin media streaming client targeting iOS 18+ and tvOS 18+. Uses a "Cinema Glass" design system (dark glassmorphism, editorial layouts, no borders).

## Architecture
- **SwiftUI** multi-platform (single Xcode project, iOS + tvOS targets)
- **CinemaxKit** local Swift Package at `Packages/CinemaxKit` — shared networking, models, persistence
- **@Observable** + `@MainActor` for all state management
- **Swift 6** strict concurrency
- **JellyfinClient** wrapped with `NSLock` + `nonisolated(unsafe)` for Sendable conformance

## Key Dependencies
- `jellyfin-sdk-swift` v0.6.0 — Jellyfin API client (uses Get/URLSession under the hood)
- `Nuke` / `NukeUI` v12.9.0 — image loading + caching
- `AVKit` / `AVPlayer` — video playback (VLCKit planned for broader codec support)

## Project Structure
- `Shared/DesignSystem/` — CinemaGlassTheme, GlassModifiers, FocusScaleModifier, Components/
- `Shared/Navigation/` — AppNavigation (auth routing), MainTabView (sidebar/tab)
- `Shared/Screens/` — HomeScreen, MediaDetailScreen, VideoPlayerView, SearchScreen, MovieLibraryScreen, TVSeriesScreen, SettingsScreen
- `iOS/` — iOS app entry point
- `tvOS/` — tvOS app entry point
- `Packages/CinemaxKit/` — Models, Networking (JellyfinAPIClient, ImageURLBuilder), Persistence (KeychainService)

## Design System Conventions
- **No 1px borders** — use color shifts for boundaries
- Color tokens in `CinemaGlassTheme.swift` (CinemaColor, CinemaFont, CinemaSpacing, CinemaRadius)
- Glass panels: `.glassPanel()` modifier
- Focus states: `.cinemaFocus()` modifier (1.1x scale + glow on tvOS)
- Platform-adaptive layouts: `#if os(tvOS)` or `horizontalSizeClass` checks

## Video Playback Architecture
Follows the same flow as Swiftfin (reference: https://github.com/jellyfin/swiftfin):

### Playback Flow (`JellyfinAPIClient.getPlaybackInfo()`)
1. **Get item** via `getItem()` — fetches full metadata
2. **Resolve non-playable items**: Series → `getNextUp()` or first episode; Season → first episode
3. **POST PlaybackInfo** with `DeviceProfile` (Swiftfin-style: `isAutoOpenLiveStream=true`, `mediaSourceID`, `userID` in body)
4. **Build stream URL** from response:
   - If server returns `transcodingURL` → use it (HLS transcode)
   - Otherwise → direct stream `/Videos/{id}/stream?static=true&playSessionId=...&mediaSourceId={id}`
5. **Fallback**: direct stream URL without PlaybackInfo session

### Key Playback Details
- **Series/Season items have no media sources** — must resolve to an Episode first
- **DeviceProfile** matches Swiftfin native player: DirectPlay for mp4/m4v/mov with h264/hevc; transcode to HLS mp4 container
- Auth via `Authorization: MediaBrowser DeviceId=..., Token=...` header (injected by SDK)
- Stream URLs use `api_key` query parameter for auth
- `#if DEBUG` guards all playback logging via `debugLog()` helper
- Raw URLSession POST used for PlaybackInfo to capture full error response body

### AVPlayer Integration (`VideoPlayerView`)
- `AVPlayerItem(url:)` with URL from PlaybackInfo
- KVO on `playerItem.status` for `.readyToPlay` / `.failed`
- Cleanup on disappear (pause + nil player + invalidate observation)

## Navigation Flow
- `AppNavigation` → checks Keychain for stored session → restores via `apiClient.reconnect()` + `fetchServerInfo()`
- No server → `ServerSetupScreen` → `LoginScreen` → `MainTabView`
- `MainTabView`: sidebar on tvOS/iPad, tab bar on iPhone
- Home hero Play → `VideoPlayerView`; More Info → `MediaDetailScreen`
- Continue Watching → `VideoPlayerView`; Recently Added → `MediaDetailScreen`
- Libraries → `MediaDetailScreen` → Play → `VideoPlayerView`

## Completed Phases
- **Phase 1**: Project setup, design system, navigation shell
- **Phase 2**: Jellyfin API, authentication, Keychain persistence
- **Phase 3**: Home screen, Movie/TV libraries with real data
- **Phase 4**: Media detail screen, video player, search, navigation wiring

## Build
```bash
# iOS
xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# tvOS
xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

## Xcode Project Generation
Uses XcodeGen: `cd Cinemax && xcodegen generate`
