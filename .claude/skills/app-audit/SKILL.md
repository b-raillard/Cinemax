---
name: app-audit
description: Comprehensive read-only audit of Cinemax across security, concurrency/race conditions, reliability, accessibility, and UI/visual consistency. Traces real user flows end-to-end (login, playback, downloads, admin, custom menus) rather than reviewing files in isolation. Run before a release or a large merge. Produces a severity-ranked findings report + remediation plan + release recommendation. Does not modify code.
---

# app-audit

A structured, adversarial audit of Cinemax — a **native SwiftUI iOS 26 / tvOS 26 Jellyfin client** (no web frontend, no server-side code in this repo). The audit is scoped to what this codebase actually is: a client app talking to a Jellyfin server over HTTPS, with a VLC/AVPlayer playback stack, an on-device loopback stream proxy, offline downloads, and admin surfaces.

**This skill is read-only.** Produce the complete findings report first. Do not edit code during the audit. Fixes are a separate, later step the user authorizes.

## Before you start — read these

Ground every finding in the project's own rules. The most common failure mode of an audit is flagging an intentional, documented pattern as a bug.

1. `CLAUDE.md` — the RULE lines are load-bearing. Many "issues" you might flag (401 never logs out on first failure; `?static=true` avoided for downloads; api_key in query param because libVLC can't inject headers; UserDefaults token dual-write is a *documented* transitional risk; single-writer `@Observable` mutators instead of `didSet`) are deliberate. Cite the RULE when you clear something, and cite it when you find something that **violates** it.
2. `docs/design-system/conventions.md` — the authoritative UI rejection checklist.
3. The three specialized subagents already in this repo — **delegate to them, don't re-derive their expertise**:
   - `swift6-concurrency-reviewer` — Sendable / `@MainActor` / actor-crossing (concurrency domain)
   - `tvos-focus-reviewer` — focus engine, `AVPlayerViewController`, player transport (accessibility + reliability on tvOS)
   - `jellyfin-api-reviewer` — `AdminAPI` privilege boundary, `JellyfinClient` lock discipline, DeviceProfile/PlaybackInfo (security + reliability)
4. Two existing skills overlap this audit's UI/copy domains — **run them, cite them, don't duplicate them**:
   - `design-system-review` → visual/token consistency
   - `localize-check` → copy consistency + FR/EN parity

## How to run the audit

Trace flows, don't sweep files. The grep heuristics in the reference files are *entry points* to find candidate sites — a finding is only real once you've read the surrounding code and the flow it sits in.

### 1. Establish scope

Default scope is the whole app. If the user passes a path or a flow name (e.g. "just downloads", "the login flow"), narrow to it.

```bash
cd "$CLAUDE_PROJECT_DIR"
git log --oneline -5          # what changed recently — weight the audit toward it
git diff --stat HEAD~10 2>/dev/null | tail -1
```

### 2. Trace the critical flows end-to-end

Read these paths as flows, entry → network → state → UI, not as isolated files. For each, ask the domain questions in `references/*.md`.

| Flow | Entry points |
|------|-------------|
| **Auth & session** | `ServerSetupScreen` → `LoginScreen` / `QuickConnectSheet` → `AppState.restoreSession` / `reconnect` → `AppNavigation.handlePossibleSessionExpiry` → `KeychainService` |
| **Playback (online)** | `PlayLink` → `VideoPlayerCoordinator` / `VideoPlayerView` → `getPlaybackInfo(engine:)` → `VLCStreamPresenter` / `NativeVideoPresenter` → `CinemaxStreamProxy` |
| **Playback (offline)** | `VideoPlayerView.startIOSPlayback` → `downloads.item(for:)` → `VLCStreamPresenter.presentOffline` |
| **Downloads** | `DownloadButton` → `DownloadManager` → `JellyfinAPIClient+Downloads` → `DownloadStorage` |
| **Admin** | `SettingsCategory.visibleCases` → `Admin/*` → `AdminAPI` slice (privilege boundary) |
| **Custom menu / tabs** | `MenuConfigStore` → `MainTabView` → `MenuSettingsScreen` |
| **Extensions / deep links** | `ExtensionSessionBridge` → Widget / TopShelf; `AppNavigation.onOpenURL` → `handleDeepLink` |

### 3. Run each domain pass

Load the matching reference file, work its checklist, and delegate to the specialized subagent where noted. Launch the three subagents **in parallel** (independent), then do the domain passes that have no subagent (accessibility, UI) yourself while they run.

- `references/security.md` — adversarial. Assume the token is the crown jewel and the Jellyfin server is semi-trusted. Delegate the `AdminAPI` boundary to `jellyfin-api-reviewer`.
- `references/concurrency.md` — race conditions, duplicate submissions, timer/task/observer cleanup. Delegate Sendable/isolation to `swift6-concurrency-reviewer`.
- `references/reliability.md` — error handling, loading/empty/error/offline states, nullability, retry/rollback.
- `references/accessibility.md` — VoiceOver, Dynamic Type, tvOS focus, reduced motion, contrast, touch targets. Delegate tvOS focus to `tvos-focus-reviewer`.
- `references/ui-consistency.md` — run `design-system-review` + `localize-check`, then the cross-component/state-coverage checks those skills don't cover.

### 4. Write the report

Use `references/report-template.md`. Every finding carries all nine fields (Severity, Category, Location, Issue, Impact, Evidence, Reproduction, Recommended fix, Confidence). Rank by real-world impact × exploitability. Separate **Confirmed** from **Needs Verification** — do not pad the report with speculative findings.

End with the four required sections: prioritised remediation plan, quick wins (low regression risk), issues needing architectural change, and a one-line release recommendation (**Safe to ship** / **Ship with known risks** / **Do not ship**) with justification.

## What this app is NOT — do not report these

The source prompt for this skill was written for web apps. The following are **out of scope** because the surface does not exist here; do not manufacture findings for them:

- XSS, CSRF, DOM/HTML/script/template injection, source maps, cookies, `localStorage`/`sessionStorage`, CORS, service-worker caches — **no web frontend or WKWebView content rendering** exists.
- SQL injection, database rules, storage-bucket ACLs, server-side endpoint authz — **the Jellyfin server is a separate codebase not in this repo**. Client-side admin gating is UX only; note where the client *assumes* server enforcement, but the server's own authz is not auditable from here.
- Semantic HTML, ARIA roles, landmarks, keyboard tab-order — **not the Apple accessibility model**. Translate to VoiceOver / `accessibilityLabel` / the tvOS focus engine / Dynamic Type instead (see `references/accessibility.md`).

If you genuinely find one of these (e.g. a `WKWebView` gets added, or a trailer opens untrusted HTML), report it — but do not invent them to fill a category.

## Adjustments made vs the original request (be critical)

This skill deliberately diverges from the literal prompt. Surface these to the user so they can push back:

- **Reframed the whole thing from web → native Apple.** ~40% of the original checklist (XSS/CSRF/SSRF-via-redirect/cookies/CORS/DB-rules/ARIA/semantic-HTML) has no surface here and would produce noise. Kept the *intent* (trust boundaries, injection, authz, focus/announcements) and mapped it to Swift/SwiftUI reality.
- **SSRF is kept but narrowed** — it *does* have a real surface: `CinemaxStreamProxy` is an on-device HTTP→URLSession proxy and deep links (`cinemax://item/{id}`) feed IDs into API calls. That's the injection/SSRF-shaped risk worth tracing, not web SSRF.
- **Delegated to existing skills/agents instead of duplicating.** UI consistency and localization already have skills; concurrency, tvOS focus, and the API boundary already have subagents. The audit orchestrates them rather than re-implementing.
- **Elevated concurrency to a first-class domain.** For a Swift 6 strict-concurrency app this is where the real, non-theoretical bugs live (race guards, coalesced seeks, timer/task cleanup) — the original buried it mid-list.
- **Anchored everything to CLAUDE.md RULEs** so the audit doesn't "find" intentional design as bugs — the single biggest waste in an automated audit.
