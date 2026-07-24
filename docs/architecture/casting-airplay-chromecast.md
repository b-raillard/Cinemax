# Casting — AirPlay & Chromecast (design study)

> **Status: proposal / not implemented.** This document is the pre-implementation
> study requested before writing any code. It maps the current state, the real
> anchor points in the codebase, the two very different technical paths, the
> constraints, and a phased recommendation. Nothing here ships until the plan is
> validated. Companion reference: `docs/architecture/playback.md`.

## 1. Goal

Let a user on an **iPhone** send video to a TV:

- **AirPlay** → Apple TV / AirPlay 2-compatible TV.
- **Chromecast** → Chromecast / Google TV device.

tvOS is explicitly **out of scope**: the tvOS build *is* the Apple-TV app, and
Chromecast has no tvOS SDK. All work below is `#if os(iOS)`.

## 2. TL;DR

| | AirPlay | Chromecast |
|---|---|---|
| Possible? | **Yes — already partly working** | **Yes — but a real integration** |
| Works today | On the **native** engine (AVPlayer already casts) | Not at all (no SDK) |
| Blocker | Default **VLC** engine can't hand video to AirPlay (hard libVLC limit) | Requires the Google Cast SDK (closed binary), a receiver App ID, LAN reachability |
| New dependency | None | `GoogleCast` XCFramework (vendored) + Protobuf transitive |
| Codec cost | Inherits the native profile (transcode for MKV/DV) | Cast device profile → server transcodes to H.264/HEVC MP4/HLS |
| Rough effort | ~0.5–1.5 day (discoverability + engine-switch prompt) | ~3–6 days (SDK, profile, UI, progress reporting, review/privacy) |

## 3. Current state (what the code already does)

### AirPlay
- **Native path works today.** `NativeVideoPresenter.swift` builds an `AVPlayer`
  with `allowsExternalPlayback = true` and
  `usesExternalPlaybackWhileExternalScreenIsActive = true`, and activates the
  audio session as `.playback` / `.moviePlayback`
  (`activatePlaybackAudioSession()`). Because it presents an
  `AVPlayerViewController`, the **AirPlay route button already appears** in the
  transport bar, and the iPhone routes true AirPlay video to an Apple TV. Reach
  it today via **Settings → Interface → "Use Native Player"** (`forceNativeAVPlayer`).
- `project.yml` already declares `UIBackgroundModes: [audio]` (keeps playback
  alive when the phone locks mid-cast) — with the in-code note that `airplay` is
  **not** a valid background-mode value (App Store validator rejects it); `audio`
  covers AirPlay.
- **Default VLC engine has no AirPlay video.** `VLCStreamPresenter` renders via
  libVLC into a `UIView`; there is no handoff to an external AirPlay display.
  Documented in `playback.md` as *"AirPlay-to-TV video impossible on any libVLC
  path — deferred."* Audio may route, the picture will not. (Whole-screen
  **mirroring** from Control Center works with zero code but is lower quality and
  keeps the phone awake — a fallback, not a feature.)

### Chromecast
- **Nothing.** No `GoogleCast`, `GCK*`, `Cast`, or route-detector symbols exist
  anywhere in the tree (verified by grep). Green field.

### Engine selection (where any cast hook lands)
- iOS entry: `VideoPlayerView.startIOSPlayback()` picks the engine from
  `forceNativeAVPlayer` and constructs either `VLCStreamPresenter` or
  `NativeVideoPresenter`.
- tvOS entry (irrelevant here): `VideoPlayerCoordinator.play(...)`.
- All play buttons already funnel through `PlayLink<Label>` (never a direct
  `NavigationLink` to the player) — the single choke point for a future
  "cast instead of play locally" decision.
- Stream URL + device profiles: `JellyfinAPIClient+Playback.swift`
  (`getPlaybackInfo(... engine:)`), with `buildVLCDeviceProfile` /
  `buildAppleDeviceProfile` and the direct-stream URL builder. This is where a
  `.cast` engine + `buildCastDeviceProfile` would be added.

## 4. Why the two are fundamentally different

- **AirPlay is an OS-level handoff.** AVPlayer hands its *player item* to the OS,
  which streams to the Apple TV. The app barely participates. That's why it
  already works on the native path and can't work on the libVLC path (libVLC owns
  the pixels; it never yields them to AirPlay).
- **Chromecast is a second player on the network.** The phone becomes a remote
  control; the **Chromecast device fetches the media URL itself** and decodes it.
  The app must: discover devices, open a session, hand over a URL the Chromecast
  can reach **and** decode, drive transport remotely, and mirror progress back to
  Jellyfin. None of the existing local-playback machinery transfers directly.

## 5. AirPlay — design

### 5.1 What "works today" already covers
If the user enables the native player, AirPlay is fully functional and
discoverable (button in the AVKit transport bar). The gap is **UX**, not
capability: on the default VLC engine there is no button and no explanation.

### 5.2 Proposed work (discoverability + graceful engine switch)
1. **In-player route button on the native path (iOS).** Add an
   `AVRoutePickerView` to the native player chrome so AirPlay is obvious (AVKit
   shows one already, but a first-class control + our tint keeps it on-brand).
   Low value if we rely on AVKit's built-in button; include only if we want the
   control on our custom overlays.
2. **"Cast to TV" affordance on the VLC path.** Use `AVRouteDetector`
   (`isMultipleRoutesDetected`) to know when AirPlay targets exist. When they do,
   surface a button in the `VLCStreamPresenter` iOS HUD (anchor next to the
   existing transport controls built in `buildIOSTransport`) that offers:
   *"AirPlay needs the native player — switch and continue?"* → tears down the VLC
   presenter and re-launches the same item on `NativeVideoPresenter` at the
   current position (we already have `startTime` plumbing and resume). This makes
   AirPlay reachable without the user knowing about the engine setting.
3. **Optional auto-preference.** A setting `castPreferNativeEngine` (default off):
   when an AirPlay route is already active at launch, start playback on the native
   engine directly. Keeps VLC's no-transcode benefit for normal local viewing.

### 5.3 Constraints / tradeoffs
- Switching to native re-introduces the **MKV / Dolby Vision transcode** problem
  (the whole reason VLC is the default). For H.264/HEVC MP4 sources it's a
  non-issue; for DV-in-MKV the server may re-encode or fail. This is inherent to
  AirPlay, not a bug we can engineer away — AVPlayer is the only AirPlay-capable
  engine and it can't open MKV.
- The prompt must set expectations ("some formats may transcode on the server").

### 5.4 Files touched (AirPlay)
- `Shared/Screens/VideoPlayer/VLCStreamPresenter.swift` — route detector + HUD
  button + engine-switch callback (iOS-only region).
- `Shared/Screens/VideoPlayerView.swift` — accept a "start on native at position
  X" re-entry (mostly reuses existing params).
- `Shared/Screens/NativeVideoPresenter.swift` — optional explicit
  `AVRoutePickerView` if we want a branded control.
- `Shared/DesignSystem/SettingsKeys.swift` (+ `Default`) — optional
  `castPreferNativeEngine`.
- `Resources/{fr,en}.lproj/Localizable.strings` — prompt + button strings.

### 5.5 Effort
~0.5–1.5 day. No new dependency, no App Store risk. Ships independently of
Chromecast.

## 6. Chromecast — design

### 6.1 Dependency & build integration
- **SDK:** Google Cast SDK for iOS (`GoogleCast.xcframework`). It is a
  **closed-source binary** with no first-class SwiftPM package; the project uses
  XcodeGen + SwiftPM and **no CocoaPods**. Two viable routes:
  - **(preferred)** vendor the XCFramework in-repo and reference it from
    `project.yml` (`dependencies: - framework: Vendor/GoogleCast.xcframework`),
    or wrap it in a local SwiftPM `binaryTarget`. Also links its **Protobuf**
    dependency + `libc++`.
  - avoid CocoaPods (would fork the build system away from XcodeGen).
- **Privacy manifest:** recent Cast SDK versions ship their own
  `PrivacyInfo.xcprivacy`; verify it's present (Apple ITMS-91053 is per-binary —
  see the extensions RULE in `CLAUDE.md`). If absent for the pinned version, we
  must not ship it.
- **Swift 6:** the SDK predates Swift 6 concurrency annotations. Expect
  `Sendable` friction bridging `GCK*` types across `@MainActor`; wrap callback
  objects following the existing `@unchecked Sendable` box patterns.
- **App size / min-OS:** adds several MB; min iOS of the pinned SDK must be ≤
  our 26.2 deployment target (it is).

### 6.2 Receiver app
- Casting arbitrary DRM-free media can use Google's **Default Media Receiver**
  (App ID `CC1AD845`) for prototyping.
- **Production** should register a receiver in the **Google Cast SDK Developer
  Console** (one-time ~$5 developer registration) to get a stable App ID and
  (optionally) a Styled Media Receiver for branding. This is an **external
  account/config step the user must own** — it can't be done from the codebase.

### 6.3 Info.plist (iOS target, in `project.yml`)
- `NSLocalNetworkUsageDescription` — **already present** (reused; discovery needs it).
- `NSBonjourServices` — **new**, must list `_googlecast._tcp` and
  `_<APPID>._googlecast._tcp`.
- Cast options can also require `NSUserTrackingUsageDescription`-adjacent keys in
  some SDK versions for guest mode; verify per pinned version.

### 6.4 Playback flow (the important part)
The Chromecast fetches the stream **directly from the Jellyfin server**, so:

1. **New engine + device profile.** Add `VideoPlaybackEngine.cast` and
   `buildCastDeviceProfile` in `JellyfinAPIClient+Playback.swift`. Chromecast
   codec reality: H.264 (High) broadly; HEVC/VP9/4K only on Ultra / Google TV;
   **no Dolby Vision** on most; container support is MP4 / WebM / **HLS/CMAF**,
   **not raw MKV**. So the Cast profile advertises Cast-safe codecs and lets
   Jellyfin transcode/remux as needed (an HLS transcode profile is the safe
   default — mirrors `buildAppleDeviceProfile`, tuned for Cast). **Cast therefore
   loses VLC's "zero transcode" advantage** — unavoidable, the device dictates it.
2. **Auth in the URL, not a header.** The Chromecast can't send our
   `Authorization: MediaBrowser …` header. Like the VLC path, the token must ride
   the URL as `api_key=<token>` (the direct-stream builder currently relies on a
   header for AVPlayer — a Cast variant needs the query-param form).
3. **Reachability.** The Chromecast must reach the server. Same-LAN Jellyfin is
   fine; a LAN-only server is unreachable when only the phone has a tunnel/VPN.
   The loopback IPv6 proxy (`CinemaxStreamProxy`) is **phone-local** and does
   **not** help the Chromecast — it fetches on its own. Surface a clear error
   when the cast device can't load the URL.
4. **Load media.** Build `GCKMediaInformation` (contentURL, contentType e.g.
   `application/x-mpegurl` or `video/mp4`, `GCKMediaMetadata` title + poster,
   `streamType` buffered, start position from resume). Load via
   `GCKRemoteMediaClient`.
5. **Progress → Jellyfin.** Wire `GCKRemoteMediaClient` progress into a
   `PlaybackReporter`-compatible `TimeSource` (the reporter already accepts an
   injected time closure — the same seam VLC uses) so start/progress/stopped and
   **resume** keep working while casting. Subtitles via `GCKMediaTrack` (WebVTT
   sidecar from Jellyfin) — a follow-up, not v1.

### 6.5 UI
- **Cast button** (`GCKUICastButton`) in the player HUD and optionally on
  `MediaDetailScreen` / a nav bar — visible only when devices are discovered.
- **Mini-controller** + **expanded controls** (`GCKUIExpandedMediaControls`) for
  play/pause/seek while the video plays on the TV, plus a "casting to <device>"
  state in the app.
- **Session lifecycle** via `GCKSessionManager` — start/resume/end, and hand off
  between local ↔ cast (stop local, start remote at the same position; the
  `PlayLink` choke point routes this).
- Style must pass the design-system checklist (`docs/design-system/conventions.md`).

### 6.6 New files (indicative)
- `Shared/Screens/VideoPlayer/CastController.swift` — session + remote-media
  client + progress bridge (iOS-only, `@MainActor @Observable`, singleton like
  `SyncPlayController`).
- Cast device-profile additions in `JellyfinAPIClient+Playback.swift`.
- Cast button/mini-controller SwiftUI/UIKit wrappers.
- `Vendor/GoogleCast.xcframework` (+ `project.yml` wiring).
- Strings, a `PrivacyInfo` verification, and settings toggle if we gate it.

### 6.7 Risks
- Closed binary + Protobuf + Swift 6 bridging friction.
- External Google account/console step (owner action).
- Codec/reachability edge cases produce "casts but won't play" reports unless the
  profile + error messaging are careful — budget test time on real hardware
  (Chromecast + Google TV both).
- App size and a new privacy-manifest surface to keep green each SDK bump.

## 7. Recommendation & phasing

1. **Phase 1 — AirPlay UX (cheap, high value).** Make AirPlay reachable from the
   default VLC engine via `AVRouteDetector` + an engine-switch prompt, reusing the
   already-working native AirPlay path. No dependency, no review risk. Ships first.
2. **Phase 2 — Chromecast (scoped project).** Vendor the SDK, add the `.cast`
   engine + Cast device profile + query-param auth, `CastController` with progress
   bridging, and the Cast button / mini-controller. Requires the user to register
   a receiver App ID. Land behind a feature flag (mirror the
   `watchTogetherEnabled` kill-switch) until validated on real devices.

## 8. Open questions for the user (needed before Phase 2)
- Are you willing to register a **Google Cast receiver App ID** (one-time ~$5 dev
  fee)? Prototype can use the default receiver, production shouldn't.
- Is your Jellyfin server **reachable on the same LAN** as the Chromecast in your
  usual setup (remote/VPN-only servers can't be cast to)?
- Priority: ship **AirPlay UX first** and treat Chromecast as a follow-up, or plan
  both together?
- Acceptable that Chromecast (and AirPlay-on-native) may **transcode** MKV/Dolby
  Vision server-side, unlike local VLC playback?
