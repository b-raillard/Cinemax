# App Store Submission — TODO

End-to-end checklist for shipping Cinemax to the App Store on **iOS** (`com.cinemax.ios`) and **tvOS** (`com.cinemax.tvos`). Source of truth for submission — follow top to bottom.

Code-level readiness (privacy manifest, accessibility, security, etc.) is tracked in `APP_STORE_AUDIT.md` — resolve the "Must-Fix" and "Should-Fix" items there **before** working through this file.

---

## 0. Bundle ID note (both platforms)

iOS and tvOS have **different bundle IDs** (`com.cinemax.ios` / `com.cinemax.tvos`), so App Store Connect will have **two separate app records** — not a single universal app. All steps below that say "per platform" apply to both records independently.

If we ever want a single "Cinemax" entry that covers both, we'd need to unify the bundle IDs (`com.cinemax.app` across targets) and use Xcode's multi-platform scheme. Not required for v1.0.

---

## 1. Jellyfin test server for App Review

Apple reviewers need reliable access to a working Jellyfin backend for the entire review window (often 1–3 days, longer if rejected + resubmitted).

### Options (ranked)

**1. Dedicated reviewer account on our own server — recommended**
- Full control over uptime, content, and state.
- Requirements:
  - Public HTTPS endpoint (Cloudflare Tunnel, or reverse proxy + Let's Encrypt).
  - Dedicated `reviewer@` user with a fixed password.
  - Library restricted to legally-distributable content only (see below).
  - App Review Notes: URL + credentials + 3-line "how to log in" guide.

**2. Jellyfin public demo server (`demo.jellyfin.org`) — backup only**
- We don't control uptime or content.
- If it's down during review, we get rejected through no fault of our own.
- Acceptable as a *secondary* URL in review notes, not the primary.

**3. Ephemeral sandbox on a cheap VPS (Hetzner / DigitalOcean ~$5/mo)**
- Official Jellyfin Docker image, seeded with the content list below, subdomain pointed at it.
- Better isolation from our personal server, slightly more setup.

### Content — where to get rights-free media

#### Animated shorts & feature films (CC-BY / CC0)
- **Blender Open Movies** — https://studio.blender.org/films
  *Big Buck Bunny*, *Sintel*, *Tears of Steel*, *Cosmos Laundromat*, *Agent 327*, *Spring*, *Charge*. CC-BY, 1080p/4K sources available. Gold standard for media-app demos.
- **High-bitrate masters** at https://download.blender.org/ (e.g. `durian/`, `peach/`) — good for showing transcoding.

#### Public-domain feature films
- **Internet Archive — Feature Films** — https://archive.org/details/feature_films
  Filter by "Public Domain". Reliable picks: *Night of the Living Dead* (1968), *Nosferatu* (1922), *The General* (1926), *His Girl Friday* (1940), *Plan 9 from Outer Space*, *Charade* (1963).
- **Library of Congress — National Screening Room** — https://www.loc.gov/film-and-videos/
  Curated PD titles with clean metadata.
- **Prelinger Archives** — https://archive.org/details/prelinger
  Ephemeral films; good for content variety.

#### TV series (harder — few PD options)
- Classic serials on Internet Archive: early *Lone Ranger*, *Dick Tracy*, *Dragnet*, some *Beverly Hillbillies* / *Andy Griffith Show* episodes.
- **Practical shortcut:** build a fake "series" from Blender shorts — name it `Blender Shorts (2006–2024)`, each film as an episode:
  ```
  Blender Shorts/Season 01/S01E01 - Elephants Dream.mp4
  Blender Shorts/Season 01/S01E02 - Big Buck Bunny.mp4
  ...
  ```
  Jellyfin picks this up as a series → covers series/season/episode navigation for the reviewer with zero rights risk.

#### Documentaries / variety
- **NASA Image and Video Library** — https://images.nasa.gov — all public domain.
- **Wikimedia Commons video** — https://commons.wikimedia.org/wiki/Category:Videos — mixed CC.

#### Metadata & artwork
- **TMDB** — https://www.themoviedb.org — has entries for all Blender films and most PD classics. The Jellyfin TMDB plugin auto-fetches posters/backdrops/descriptions so the demo library looks real instead of bare filenames.

### Minimal demo library (convincing + low effort)

- **Movies (8–10):** all 7 Blender open movies + 2–3 Internet Archive PD classics (e.g. *Night of the Living Dead*, *Charade*, *Nosferatu*). Variety of runtime, aspect ratio, era.
- **Series (1–2):** Blender shorts restructured as a fake series; optionally a classic PD serial as a second entry.
- **1 "in-progress" movie** with playback position set → reviewer sees Continue Watching + resume flow.

Total download: ~15–25 GB. Exercises every screen in Cinemax (home, library, detail, playback, resume, episode nav).

### Do NOT include

- Any copyrighted film or TV content, even if "personal backup". #1 reason client apps get rejected.
- Pixar SparkShorts or any studio shorts — not PD.
- Music / audiobooks unless we've verified the license.

### Checklist

- [x] Decide: own server (option 1) vs VPS sandbox (option 3). — own server, exposed via Cloudflare Tunnel
- [x] Stand up public HTTPS endpoint if not already in place. — Cloudflare Tunnel
- [x] Create `reviewer@` Jellyfin user with fixed password, restricted to demo library.
- [x] Download Blender open movies (7 films).
- [x] Download 3 PD classics (see picks below).
- [x] Build fake "Blender Shorts" series folder structure.
- [x] Seed one movie with a playback position for Continue Watching demo.
- [x] Verify Jellyfin TMDB plugin is enabled and populating metadata + artwork.
- [x] Test end-to-end from a clean install: login → browse → play → resume → series nav.

### PD classics — recommended picks (3)

Goal: variety of era / runtime / genre so the demo library doesn't look like 7 Blender shorts plus filler. All three are confirmed US public domain and were verified downloadable on 2026-04-30 — re-verify the day you actually pull them, since IA items occasionally get taken down.

1. **Night of the Living Dead** (1968, George A. Romero, ~96 min, B&W horror)
   - Source: https://archive.org/details/night-of-the-living-dead_202309 — `MPEG4 download` ~570 MB.
   - Why: iconic title with recognizable TMDB metadata; exercises B&W rendering and a longer runtime.

2. **His Girl Friday** (1940, Howard Hawks, ~88 min, B&W screwball comedy)
   - Source: https://archive.org/details/HisGirlFriday — `H.264 MP4` ~526 MB.
   - Why: mainstream Hollywood with stars (Cary Grant / Rosalind Russell), changes tonal mix away from horror, clean encode.

3. **Nosferatu** (1922, F. W. Murnau, ~92 min, B&W silent horror)
   - Source: https://archive.org/details/Nosferatu1922 — `H.264 MP4` ~548 MB.
   - Why: silent era, oldest entry in the library, different aspect ratio / score path. Great TMDB poster.

Backup picks (also confirmed live on 2026-04-30): *The General* (1926, Buster Keaton) — https://archive.org/details/TheGeneral720p1926; *Plan 9 from Outer Space* (1957) — https://archive.org/details/plan.-9.-from.-outer.-space.-1957.

After download:
- Rename to `Title (Year).mp4` (`Night of the Living Dead (1968).mp4`, `His Girl Friday (1940).mp4`, `Nosferatu (1922).mp4`) so the Jellyfin TMDB plugin matches cleanly.
- Drop into the `Movies/` library folder next to the Blender films.
- Verify each plays through the Cinemax player on a real device — some IA encodes use older MPEG-4 variants that need transcode.

---

## 2. Apple Developer account & App Store Connect setup

### 2.1 Apple Developer Program
- [ ] Active Apple Developer Program membership ($99/year) on `bastienraillard@gmail.com`.
- [ ] Agreements, Tax, and Banking sections complete in App Store Connect (paid apps need banking even for free apps in some regions — complete to unblock submission).
- [ ] Two-factor authentication enforced on the Apple ID.

### 2.2 Bundle IDs (Apple Developer portal → Identifiers)
- [ ] Register `com.cinemax.ios` (iOS App ID).
- [ ] Register `com.cinemax.tvos` (tvOS App ID).
- [ ] Capabilities: **none required** for v1.0 — no Push, HealthKit, iCloud, Sign In with Apple, etc. (Background Modes `audio`/`airplay` in `project.yml` don't need capabilities-portal entries — they're Info.plist-only.)

### 2.3 App Store Connect app records
Create **two** app records (one per bundle ID):
- [ ] **Cinemax (iOS)** — Platform: iOS, Bundle ID: `com.cinemax.ios`, Primary language: French.
- [ ] **Cinemax (tvOS)** — Platform: tvOS, Bundle ID: `com.cinemax.tvos`, Primary language: French.
- [ ] Decide SKU convention (e.g. `cinemax-ios-001`, `cinemax-tvos-001`).
- [ ] Pricing: Free (both).
- [ ] Availability: all regions unless we want to gate some.

---

## 3. Signing & provisioning

`project.yml` now sets `CODE_SIGN_STYLE: Automatic` at the root `settings.base`. The team ID is intentionally **not** committed (open-source-friendly) — set it locally in Xcode.

- [ ] Create **Apple Distribution** certificate in Xcode (Xcode → Settings → Accounts → Manage Certificates → +). Reuses your existing Apple Developer team's keychain.
- [ ] Open `Cinemax.xcodeproj` → select `Cinemax` target → **Signing & Capabilities** → set **Team** to your paid Apple Developer team. Repeat for `CinemaxTV`.
- [ ] Confirm "Automatically manage signing" is checked for both targets.
- [ ] Xcode will auto-create `iOS App Store` and `tvOS App Store` provisioning profiles on first archive.
- [ ] (Optional) If you regenerate `project.yml` and need the team to persist across regenerations on your machine only, drop a per-developer `.xcconfig` into `Configs/Local.xcconfig`, add it to `.gitignore`, and reference it from `project.yml`. Not required for v1.0.

---

## 4. Version & build numbers

- [ ] `MARKETING_VERSION` (in `project.yml` settings.base) — stays `1.0.0` for first submission. Bump to `1.0.1` etc. for subsequent releases.
- [ ] `CURRENT_PROJECT_VERSION` — must increment for every TestFlight / App Store upload (Apple rejects duplicate build numbers). Start at `1`, bump to `2`, `3`, … per upload.
- [ ] Establish convention: marketing version reflects user-visible release; build number increments per archive. Consider automating via `agvtool` or a script if uploads get frequent.

---

## 5. App Store metadata (per platform)

Both apps need their own metadata entries in App Store Connect. Keep copy in sync but formatted for each platform's UI.

### 5.1 Text fields (FR + EN for each platform)

- [ ] **Name** (30 chars): "Cinemax"
- [ ] **Subtitle** (30 chars): e.g. "Jellyfin Client for Apple" — needs a short tagline.
- [ ] **Promotional Text** (170 chars, editable without new submission).
- [ ] **Description** (4000 chars): what the app does, required Jellyfin server, key features (playback, transcoding, resume, chapters, skip intro, AirPlay/PiP on iOS). Mention Jellyfin server requirement **prominently in the first paragraph** — Apple has rejected client apps where this wasn't obvious.
- [ ] **Keywords** (100 chars, comma-separated, no spaces after commas): e.g. `jellyfin,media,streaming,video,movies,tv,player,home,server,library`.
- [ ] **Support URL**: required. Can be a GitHub Issues URL or a simple static page.
- [ ] **Marketing URL**: optional.
- [ ] **Privacy Policy URL**: **required**. Must be publicly accessible. Since we collect zero data, the policy can be short — but it must exist. Host on GitHub Pages, a personal site, or similar.
- [ ] **Copyright**: `© 2026 Bastien Raillard` (or company name if applicable).
- [ ] **Primary Category**: Entertainment. **Secondary**: Photo & Video (iOS) / Entertainment (tvOS — only one category allowed on tvOS).
- [ ] **Content Rights**: check "Does your app contain, show, or access third-party content?" — answer "No" (the app accesses the user's own Jellyfin server content, not third-party content Apple needs us to license).

### 5.2 Age rating
- [ ] Fill the age-rating questionnaire. Cinemax itself contains no content — but media from the user's server could be anything. The honest answer is usually: **17+** with "Unrestricted Web Access = Yes" *or* **12+** arguing the app itself is neutral. Look at how Infuse / VLC / Plex rate themselves — most settle on 12+ or 17+. Err on the side of the higher rating to avoid rejection.

### 5.3 App Privacy (Nutrition Labels) — App Store Connect → App Privacy
- [ ] Data Collection: **No**, we don't collect any data. (Confirm still true — no analytics SDK added.)
- [ ] Privacy Policy URL is still required even when collecting nothing.
- [ ] Should match `PrivacyInfo.xcprivacy` declarations.

### 5.4 Localization
- [ ] Primary language: **French**.
- [ ] Add **English** localization with translated description, keywords, subtitle, promo text.
- [ ] Screenshots can differ per localization (optional — English screenshots can reuse French UI if text is minimal).

---

## 6. Screenshots

Apple requires at least one screenshot per required device class. Use the simulator + `xcrun simctl` or Xcode's Debug menu. Frame-accurate screenshots from **actual app screens** (Home, MediaDetail, Player, Library, Search) are best — no marketing mockups needed for v1.0.

### 6.1 iOS — required device classes

Apple now accepts a single set of screenshots for the largest supported device and scales down, but providing one per class is safer.

- [ ] **6.9" iPhone** (iPhone 17 Pro Max, 1320 × 2868) — **required**.
- [ ] **6.5" iPhone** (iPhone 11 Pro Max / XS Max, 1242 × 2688) — required if deployment target includes older devices. With `iOS 18.0` minimum we *might* skip, but safer to include.
- [ ] **iPad 13"** (iPad Pro M4, 2064 × 2752) — **required** since the app supports iPad.
- [ ] 3–10 screenshots per class. Suggested set:
  1. Home screen with hero + Continue Watching
  2. Media detail screen (movie with backdrop, play button, quality badges)
  3. Library grid with filters open
  4. Video player (show transport bar, subtitles, or chapters)
  5. Search screen with results
  6. Settings with accent picker or theme

### 6.2 tvOS — required

- [ ] **Apple TV** (3840 × 2160 landscape) — **required**. 3–10 screenshots. Capture from Apple TV 4K simulator.
- [ ] Suggested set: home (with focus on hero), detail screen, library with filter bar, player with contextual action, settings with accent colors.

### 6.3 App Previews (video) — optional but recommended
- [ ] 15–30 second videos per device class, captured via `xcrun simctl io booted recordVideo` or a real device via QuickTime.
- [ ] Can meaningfully improve conversion — worth doing for tvOS (animated UI showcases well).

### 6.4 tvOS Top Shelf image
Already configured via `App Icon & Top Shelf Image.brandassets`. Confirm the static Top Shelf image renders correctly on a real Apple TV before submission.

---

## 7. Build, archive & upload

### 7.1 Pre-archive sanity
- [ ] `xcodegen generate` after any `project.yml` change.
- [ ] Clean build folder (⇧⌘K) + build once on both simulators.
- [ ] All `APP_STORE_AUDIT.md` "Must-Fix" items resolved (privacy manifest, licenses, signing, demo server, dead code).
- [ ] Release config has `SWIFT_OPTIMIZATION_LEVEL=-O` (default) and strips symbols.
- [ ] No `print()` statements in hot paths (video player, observers) under Release. The audit flagged the auth-token log already fixed — spot-check others.

### 7.2 Archive (per platform)
- [ ] Select **Any iOS Device (arm64)** → `Cinemax` scheme → Product → Archive.
- [ ] Select **Any tvOS Device (arm64)** → `CinemaxTV` scheme → Product → Archive.
- [ ] Organizer opens — verify both archives appear with correct version/build.

### 7.3 Upload to App Store Connect
- [ ] From Organizer: Distribute App → App Store Connect → Upload. Repeat for each archive.
- [ ] Wait for processing (5–30 min). Watch for email about missing compliance or invalid binary.
- [x] **Export compliance**: `ITSAppUsesNonExemptEncryption = NO` is now declared in both Info.plists (via `project.yml`). App Store Connect will auto-answer the encryption questionnaire on every TestFlight upload — no manual step needed.

---

## 8. TestFlight (strongly recommended before App Store submission)

- [ ] After upload processes, the build appears in TestFlight.
- [ ] Internal testing: add yourself + anyone else to an internal testing group — no review required, available immediately.
- [ ] Install via TestFlight app on iPhone and Apple TV.
- [ ] Run through critical flows against the demo server:
  - Login, server setup
  - Home → detail → play → pause → seek → resume
  - Episode navigation, skip intro/credits
  - AirPlay + PiP (iOS)
  - Sleep timer fires, "Still watching?" prompt works
  - Settings: switch accent, dark/light, language, sign out → log back in
  - Search (text + voice on iOS)
- [ ] Verify on **actual hardware** — simulator can't test AirPlay, PiP, or Siri Remote quirks.
- [ ] Fix anything that breaks, bump `CURRENT_PROJECT_VERSION`, re-archive, re-upload.
- [ ] Optional: external TestFlight review (24–48 hr) for a handful of friends before App Store — catches issues at lower stakes.

---

## 9. App Review submission

Per platform (iOS + tvOS, separately):

- [ ] Attach the processed TestFlight build to the App Store version (1.0.0) in App Store Connect.
- [ ] Fill **App Review Information**:
  - **Sign-in required**: YES.
  - **Demo account**: Jellyfin server URL + `reviewer@` username + password (from §1).
  - **Contact information**: your name, phone, email.
  - **Notes** (critical — make the reviewer's life easy):
    ```
    Cinemax is a client for Jellyfin — a self-hosted media server. To
    review the app you need to connect to a Jellyfin server.

    A demo server has been provisioned for you:

      Server URL: https://<your-demo-url>
      Username:   reviewer
      Password:   <password>

    Steps:
    1. Launch Cinemax.
    2. Enter the server URL above and tap "Connect".
    3. Enter the username and password above and tap "Sign in".
    4. You'll land on the Home screen with curated movies and series.

    All content on the demo server is either Creative Commons (Blender
    Foundation open movies) or US public domain (Internet Archive).

    Backup server (if the primary is unreachable):
      https://demo.jellyfin.org (guest login, credentials shown on page)
    ```
- [ ] **Version Release**: "Manually release this version" (safer — you control the go-live moment) or "Automatically release after approval".
- [ ] Submit for Review.

Expected timeline: **24–48 hours** typical, longer on weekends/Apple holidays. First submissions sometimes take 2–4 days.

---

## 10. Rejection playbook (if it happens)

Most common rejections for media-client apps, and how to respond:
- **4.2 Minimum Functionality / "we couldn't connect to the demo server"** → verify the server is reachable, reply in Resolution Center with step-by-step reproduction including a screen recording. Include the backup URL.
- **5.1.1 Privacy / missing or incomplete privacy manifest** → fix `PrivacyInfo.xcprivacy` and resubmit.
- **2.3.10 Accurate Metadata / "Jellyfin requirement not obvious"** → edit description so the first sentence says "Cinemax requires access to a Jellyfin media server."
- **4.3 Spam / "similar to Infuse/VLC"** → reply explaining the differentiators (Cinema Glass design system, tvOS-first UX, etc.). Not usually an issue since we're not copying any specific app.

Reply in Resolution Center rather than re-submitting blindly — communication resolves most rejections in one round.

---

## 11. Post-approval

- [ ] If "Manually release" was selected: hit "Release this Version" in App Store Connect.
- [ ] Verify the app appears on the App Store (search for "Cinemax" — may take a few hours to propagate).
- [ ] Test a download from the real App Store on a device not used during development.
- [ ] Monitor App Store Connect → App Analytics for the first week (impressions, crashes, ratings).
- [ ] Set up **App Store Connect crash reports** review — without a third-party crash SDK, Apple's built-in reports are the only signal.
- [ ] Respond to first reviews if any appear — App Store Connect → Ratings and Reviews.

---

## 12. Quick reference — one-page checklist

### Blocking (must-have before submit)
- [ ] All `APP_STORE_AUDIT.md` "Must-Fix" items resolved
- [ ] Demo Jellyfin server live with reviewer account
- [ ] Apple Distribution cert + App Store provisioning profiles (iOS + tvOS)
- [ ] Two app records in App Store Connect (`com.cinemax.ios`, `com.cinemax.tvos`)
- [ ] Privacy Policy URL hosted and reachable
- [ ] Screenshots for all required device classes (iPhone 6.9", iPad 13", Apple TV)
- [ ] App description mentions Jellyfin requirement in first paragraph (FR + EN)
- [ ] Age rating questionnaire filled
- [ ] App Privacy nutrition labels filled (zero collection)
- [ ] Export compliance declared (`ITSAppUsesNonExemptEncryption = NO`)
- [ ] Archived + uploaded both platforms
- [ ] Build tested on real iPhone + real Apple TV via TestFlight
- [ ] App Review Notes drafted with URL, credentials, login steps

### Strongly recommended
- [ ] External TestFlight round with friends before submitting
- [ ] App Preview videos for both platforms
- [ ] English localization of all metadata
- [ ] `APP_STORE_AUDIT.md` "Should-Fix" items resolved (Dynamic Type, force-unwrap cleanup)

### Nice-to-have
- [ ] SwiftLint / CI / Fastlane (see audit §7 roadmap)
- [ ] Crash analytics (TelemetryDeck for privacy-respecting option)
