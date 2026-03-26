# Cinemax - Jellyfin Client for Apple Platforms

## Project Overview
Native Jellyfin media streaming client targeting iOS 18+ and tvOS 26+. Uses a "Cinema Glass" design system (dark glassmorphism, editorial layouts, no borders).

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
- `Shared/DesignSystem/` — CinemaGlassTheme, ThemeManager, GlassModifiers, FocusScaleModifier, LocalizationManager, Components/
- `Shared/Navigation/` — AppNavigation (auth routing), MainTabView (tab bar/sidebar)
- `Shared/Screens/` — HomeScreen, MediaDetailScreen, VideoPlayerView, SearchScreen, MovieLibraryScreen, TVSeriesScreen, SettingsScreen
- `iOS/` — iOS app entry point
- `tvOS/` — tvOS app entry point
- `Resources/fr.lproj/` — French localization (default language)
- `Resources/en.lproj/` — English localization
- `Packages/CinemaxKit/` — Models, Networking (JellyfinAPIClient, ImageURLBuilder), Persistence (KeychainService)

## Design System Conventions
- **No 1px borders** — use color shifts for boundaries
- Static color tokens in `CinemaGlassTheme.swift` (CinemaColor, CinemaFont, CinemaSpacing, CinemaRadius)
- **Dynamic accent colors** via `ThemeManager` (`@Observable`, injected from `AppNavigation`). Use `themeManager.accent` / `.accentContainer` / `.accentDim` / `.onAccent` instead of `CinemaColor.tertiary*` for all accent-colored elements
- **Dark/Light mode** via `ThemeManager.darkModeEnabled` → applied as `.preferredColorScheme()` at root. Design system colors are dark-first; light mode only affects system controls for now
- Glass panels: `.glassPanel()` modifier
- **tvOS Focus states**: Custom focus via `@FocusState` + `.focusEffectDisabled()` + `.hoverEffectDisabled()`. Focus indicator is a thin accent-colored `strokeBorder` (2px) — no scale, no white background. Cards use `CinemaTVCardButtonStyle` (brightness on focus, no scale). Shared via `.tvSettingsFocusable()` modifier in SettingsScreen. Season tabs use `SeasonTabButtonStyle` (capsule accent border).
- **Motion Effects environment key**: `motionEffectsEnabled` (`EnvironmentKey` in `FocusScaleModifier.swift`), injected from `AppNavigation` on tvOS via `@AppStorage("motionEffects")`. When disabled, all `.animation()` calls use `nil` instead of animation curves. Consumed by `CinemaFocusModifier`, `CinemaTVButtonStyle`, `CinemaTVCardButtonStyle`, `tvSettingsFocusable()`, and toggle indicators.
- **iOS Focus states**: `.cinemaFocus()` modifier (accent border + shadow)
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
- `getPlaybackInfo()` accepts `maxBitrate` parameter (default 40 Mbps) — tvOS `VideoPlayerCoordinator` reads `@AppStorage("render4K")` and passes 120 Mbps (4K) or 20 Mbps (1080p)
- Auth via `Authorization: MediaBrowser DeviceId=..., Token=...` header (injected by SDK)
- Stream URLs use `api_key` query parameter for auth
- `#if DEBUG` guards all playback logging via `debugLog()` helper
- Raw URLSession POST used for PlaybackInfo to capture full error response body

### AVPlayer Integration (`VideoPlayerView`)
- `AVPlayerItem(url:)` with URL from PlaybackInfo
- KVO on `playerItem.status` for `.readyToPlay` / `.failed`
- Cleanup on disappear (pause + nil player + invalidate observation)

### tvOS Video Playback (UIKit-based)
- **Critical**: On tvOS, video MUST be presented via UIKit (`AVPlayerViewController` + `UIViewController.present()`), NOT via SwiftUI `fullScreenCover` or `NavigationLink`. SwiftUI presentation corrupts `TabView`/`NavigationSplitView` focus state on dismiss.
- `TVVideoPresenter` handles UIKit modal presentation directly on the root VC. Accepts `forceSubtitles` flag — when true, disables automatic media selection and selects the first available subtitle track (preferred language order)
- `VideoPlayerCoordinator` (`@Observable`) reads `@AppStorage("forceSubtitles")` and `@AppStorage("render4K")`, fetches the stream URL via `getPlaybackInfo(maxBitrate:)`, then calls `TVVideoPresenter.present(url:forceSubtitles:)`
- `PlayLink<Label>` — cross-platform component: `Button` → coordinator on tvOS, `NavigationLink` on iOS
- All play buttons across screens use `PlayLink` instead of direct `NavigationLink` to `VideoPlayerView`

## Navigation Flow
- `AppNavigation` → checks Keychain for stored session → restores via `apiClient.reconnect()` + `fetchServerInfo()`
- `AppNavigation` injects `ThemeManager` and `LocalizationManager` and applies `.preferredColorScheme()` at root
- No server → `ServerSetupScreen` → `LoginScreen` → `MainTabView`
- `MainTabView`: **TabView (top tab bar) on tvOS**, sidebar on iPad, bottom tab bar on iPhone
- Home hero Play → `PlayLink` → video; More Info → `MediaDetailScreen` (episodes/seasons auto-resolve to parent series)
- Continue Watching → `PlayLink` → video; Recently Added → `MediaDetailScreen`
- Libraries → `MediaDetailScreen` → Play → `PlayLink` → video

## Completed Phases
- **Phase 1**: Project setup, design system, navigation shell
- **Phase 2**: Jellyfin API, authentication, Keychain persistence
- **Phase 3**: Home screen, Movie/TV libraries with real data
- **Phase 4**: Media detail screen, video player, search, navigation wiring
- **Phase 5**: Sort & filter (movies/TV), voice search (iOS), settings redesign (tvOS tabbed layout), dynamic accent color system, dark/light mode toggle, tvOS video focus fix (UIKit presentation)
- **Phase 6**: tvOS Settings rework — Cinema Glass design system, single-page two-column layout, profile management with server users + profile images, custom toggle indicators, server connection info, interface options (motion effects, subtitles, 4K rendering), premium focus style (thin accent border, no scale/zoom)
- **Phase 7**: UI polish — tvOS focus without image overlap (border instead of scale), card image alignment (Color.clear container pattern), full i18n system (French default + English, in-app language switcher via `LocalizationManager`), accent color picker in settings, `@AppStorage`+`@Observable` reactivity fix (`_revision` counter pattern), series image fallback (`parentBackdropItemID` → `seriesID` → `id`)
- **Phase 8**: Settings toggles wired up (Motion Effects → `motionEffectsEnabled` environment key disables all tvOS animations; Force Subtitles → auto-selects subtitle track on playback; 4K Rendering → adjusts max streaming bitrate 120/20 Mbps). MediaDetailScreen refactored: episodes/seasons auto-resolve to parent series for full detail, dead More Info button removed, tvOS scrolling fixed (`.focusable()` on overview text), backdrop height increased, action button spacing widened. Season tab buttons use custom `SeasonTabButtonStyle` (accent capsule border, no native focus effect).

## tvOS Interface Settings
Three `@AppStorage` toggles in SettingsScreen (tvOS only):
- **Motion Effects** (`motionEffects`, default: `true`) — controls all UI animations via `motionEffectsEnabled` environment key injected from `AppNavigation`. When off, `.animation(nil)` is used everywhere
- **Force Subtitles** (`forceSubtitles`, default: `false`) — read by `VideoPlayerCoordinator`, passed to `TVVideoPresenter.present(url:forceSubtitles:)`. Disables `appliesMediaSelectionCriteriaAutomatically` and selects first `.legible` track
- **4K Rendering** (`render4K`, default: `true`) — read by `VideoPlayerCoordinator`, sets `maxBitrate` to 120 Mbps (on) or 20 Mbps (off) in `getPlaybackInfo()` and `DeviceProfile`

## MediaDetailScreen
- `MediaDetailViewModel` auto-resolves Episode/Season items to their parent Series (fetches series by `seriesID`, loads seasons + episodes)
- Uses `resolvedType` (not initial `itemType`) for layout decisions (show seasons, metadata format)
- tvOS scrolling: overview text uses `.focusable()` to enable focus-driven scrolling past non-interactive content
- Action buttons: Play only (no More Info — the user is already on the detail page)

## Localization
- In-app language switching via `LocalizationManager` (`@Observable`, injected from `AppNavigation`)
- Default language: French (`fr`). Also supports English (`en`)
- All UI strings use `loc.localized("key")` or `loc.localized("key", args...)` — never hardcoded
- Strings files at `Resources/{lang}.lproj/Localizable.strings`
- Uses `@ObservationIgnored` + `@AppStorage` + `_revision` counter pattern (same as `ThemeManager`) to trigger SwiftUI updates

## Image URL Patterns
- `ImageURLBuilder` builds Jellyfin `/Items/{id}/Images/{type}` URLs
- **Series/episode backdrop fallback**: Episodes don't have their own backdrop — use `item.parentBackdropItemID ?? item.seriesID ?? item.id` for backdrop image IDs
- **Card image containers**: Use `Color.clear` + `.aspectRatio()` + `.frame(maxWidth: .infinity)` + `.overlay { LazyImage }` + `.clipped()` for consistent sizing

## Build
```bash
# iOS
xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# tvOS
xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

## Xcode Project Generation
Uses XcodeGen: `cd Cinemax && xcodegen generate`
