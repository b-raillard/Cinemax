# Security pass (adversarial)

Threat model for this app: the **session token is the crown jewel**. It grants full access to the user's Jellyfin account (and, for admins, the whole server). The Jellyfin server is *semi-trusted* — it can return hostile data (crafted item metadata, image URLs, error strings). The device may be shared (tvOS living-room), backed up to iCloud, or lost. Audit against those, not against a browser.

Delegate the **`AdminAPI` privilege boundary** and `JellyfinClient` lock/token discipline to the `jellyfin-api-reviewer` subagent. Everything below is yours.

## 1. Token / credential storage & exposure

- **Keychain accessibility.** All session items must use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (device-only, not in backups, readable on tvOS cold boot). Flag any Keychain write with a weaker class or `...WhenUnlocked` (breaks tvOS relaunch) or one that omits `ThisDeviceOnly` (lands in backups).
  ```bash
  grep -rn --include='*.swift' 'kSecAttrAccessible' Packages Shared
  ```
- **The UserDefaults token dual-write is a KNOWN, documented risk to remove** (`ExtensionSessionBridge.publish` writes the token to the App Group `UserDefaults` suite `group.com.cinemax.shared` as a transitional fallback). CLAUDE.md marks it "DROP next release". Verify it is *still* only a fallback and readers prefer Keychain — and flag it as a **High** finding that the release should finally drop it, since a plaintext token in a group suite is readable from backups / any group process.
  ```bash
  grep -rn --include='*.swift' 'group.com.cinemax.shared\|extension.session\|UserDefaults(suiteName' Packages Shared Widgets TopShelf
  ```
- **Token in URLs.** `api_key` is intentionally a query param on VLC/image/download URLs (libVLC can't inject headers — documented RULE). The real risk is **where those URLs get logged, toasted, or surfaced in an error**. Trace: does any `Logger`/error path print a full stream/download URL with `api_key=` in it? Does `DownloadItem` persist a URL containing the token to `index.json`? (CLAUDE.md says download URLs strip `api_key`/`token` query items — verify the strip actually runs before persistence.)
  ```bash
  grep -rn --include='*.swift' 'api_key\|apikey' Shared Packages | grep -iv 'strip\|removeAll\|filter\|guard\|//' 
  grep -rn --include='*.swift' 'logger\.\|Logger\|os_log\|\.error(\|\.info(' Shared/Screens/VideoPlayer Shared/Screens/Downloads
  ```
- **Never log or share key values.** API keys admin screen: masked, `.privacySensitive()`, Copy is the only export, never logged (RULE). Verify no `Logger`/analytics call takes a token, api key, or password. Confirm `revokeApiKey` forgets the value on return.
- **`error.localizedDescription` must never reach the user** (leaks `unacceptableStatusCode(401)` etc. — RULE). Every user-facing error must route through `LocalizationManager.userFacingMessage(for:)`. Flag raw `.localizedDescription` in any `Text`, toast, or alert.
  ```bash
  grep -rn --include='*.swift' 'localizedDescription' Shared | grep -viE 'logger|log\.|userFacingMessage|print|//'
  ```

## 2. Authorization & IDOR

- Client-side admin gating (`AppState.isAdministrator`, `SettingsCategory.visibleCases`) is **UX, not a security boundary** — the server enforces. That's correct and documented. What to actually check: is there any place the client acts on admin data it fetched *without* the gate (e.g. `/Sessions` leaking every user's session to non-admins — CLAUDE.md flags jellyfin#5210; Watching Now row + fetch must be gated on `isAdministrator`). Verify the gate wraps the **fetch**, not just the view.
  ```bash
  grep -rn --include='*.swift' 'getActiveSessions\|/Sessions\|isAdministrator' Shared
  ```
- **Self-protection** (can't delete/demote/disable self; can't revoke current device) is client-side convenience; note it but don't rate it as a vuln (server enforces).
- **IDOR-shaped surface: `parentId` / item IDs from deep links and menu config.** `cinemax://item/{id}` and library-tab `parentId` flow into API queries. These are scoped to the authenticated user server-side, so cross-tenant access isn't reachable from the client — but verify the deep-link ID is validated/sanitized before use (see §4) and that a malformed ID degrades gracefully rather than crashing.

## 3. The loopback stream proxy (`CinemaxStreamProxy`) — the real SSRF-shaped surface

This is an on-device HTTP server on `127.0.0.1` that re-fetches from the real HTTPS origin via URLSession. Audit it as a proxy, not a browser SSRF:

- **Origin pinning.** Each loopback URL carries a `/s/<id>` that must resolve to *its own* pre-registered target (CLAUDE.md: "each loopback URL carries a unique `/s/<id>` resolving to its own target so a retry/episode swap can't read the wrong stream"). Verify the proxy only ever fetches the registered origin for that id and never an attacker-influenced host from the request path/headers. A request for an unknown `/s/<id>` must 404, not fetch something derived from the request.
- **Binding.** Confirm the listener binds `127.0.0.1` / loopback only, never `0.0.0.0` (would expose the token-bearing proxy to the LAN).
- **`Connection: close` / one-request-per-connection** and the reconnect budget (`reconnectsLeft`, `progressRenewBytes`) — these bound resource use; a missing bound is a DoS-on-self, worth a Low/Medium note.
  ```bash
  grep -rn --include='*.swift' '127.0.0.1\|0.0.0.0\|NWListener\|bind\|localhost\|/s/' Shared/Screens/VideoPlayer/CinemaxStreamProxy.swift
  ```

## 4. Input validation at trust boundaries

The Jellyfin server response and deep links are the untrusted inputs. Client-side validation is *all there is* here — there's no server to fall back on for the client's own safety.

- **Deep link parsing** (`AppState.handleDeepLink`): `cinemax://item/{id}` — verify the host/path are checked and the id is non-empty/sane before it becomes `pendingDeepLinkItemId`. A malformed or hostile URL must be dropped, not force-unwrapped.
  ```bash
  grep -rn --include='*.swift' 'onOpenURL\|handleDeepLink\|cinemax://\|URLComponents\|url.host\|pathComponents' Shared
  ```
- **Server-supplied strings rendered as text** are safe in SwiftUI `Text` (no markup interpretation) — but check for `AttributedString(markdown:)`, `Text(verbatim:)` misuse, or any string interpolated into a URL without percent-encoding.
- **Search term** (`SearchViewModel.sanitize` / `fetchRanked`) — verify `maxQueryLength` cap and normalization actually run; no unbounded fan-out `TaskGroup` from a pathological multi-word query.
- **Force-unwraps and force-`try` on external data** are a crash/DoS surface. Flag `!` / `try!` on anything derived from a network response, URL, or deep link.
  ```bash
  grep -rn --include='*.swift' 'try!\|as!\| \.first!\|]!' Shared/Screens Packages | grep -viE '//|test'
  ```

## 5. Transport & network policy

- Confirm no `NSAllowsArbitraryLoads` / ATS exceptions beyond what a self-hosted-server client legitimately needs, and that any HTTP (non-TLS) path is a deliberate, user-configured server URL — never a hardcoded cleartext endpoint. The loopback proxy speaks `http://127.0.0.1` (fine — loopback), but the *upstream* leg must stay HTTPS.
  ```bash
  grep -rn 'NSAllowsArbitraryLoads\|NSAppTransportSecurity\|http://' iOS tvOS Shared Packages | grep -v '127.0.0.1\|localhost'
  ```
- No hardcoded secrets/hosts/test tokens in source.
  ```bash
  grep -rniE --include='*.swift' 'password *= *"|token *= *"[A-Za-z0-9]|secret|apikey *= *"|Bearer ' Shared Packages | grep -viE 'SettingsKey|placeholder|SecureField|kSec|//'
  ```

## Severity guidance for this domain

- **Critical/High**: token recoverable from backups or logs; token in a persisted file; a non-admin able to read other users' data the client actually consumes; the loopback proxy fetching an attacker-controlled origin; a crash reachable from a crafted deep link or server response.
- **Medium**: `localizedDescription` leaking SDK internals to users; unbounded retry/fan-out; the documented UserDefaults dual-write still shipping.
- **Low/Info**: masking/`.privacySensitive` gaps on already-Keychain'd data; client-side self-protection nits (server enforces).
