# Local Server Address Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** each server gets an optional LAN address, typed by hand once per device. Every path that talks to the server tries it first when the device may be at home, and falls back to the public URL.

**Architecture:** the public URL stays the server's IDENTITY everywhere it is today (registry, dedup, legacy mirror, pins, `ServerVersion`, `appState.serverURL`). Only the transport dials a separate DIAL URL:
- `JellyfinAPIClient` keeps a `dialURL` beside its identity URL.
- Nuke rewrites the base at load time.
- The socket hub is repointed, and `StreamTransportPolicy` is fed the dial URL.

One `@MainActor` owner, `ServerRouteController.shared`, probes (`GET /System/Info/Public`, no token, no redirects, `Id` match, private connected address), decides, and pushes the dial URL. The extensions and App Intents carry their own small probe.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI iOS 26 / tvOS 26, CinemaxKit (local SwiftPM), jellyfin-sdk-swift 3.2.0, Nuke 13.2, `Network` (`NWPathMonitor`, `NWConnection`), swift-testing.

**Spec:** `docs/superpowers/specs/2026-11-09-local-server-address-design.md` (validated 2026-11-09, mockup choice A). Read it in full before Task 1. The executor reads the spec and this plan; where they disagree, the spec wins and the plan is fixed.

## Global Constraints

- Branch `claude/local-server-address`. Commit per task. **Never push before Task 13's Release builds pass. Never merge.**
- Read before touching an area: root `CLAUDE.md`, `docs/rules/server-setup-and-multi-server.md`, `Packages/CinemaxKit/CLAUDE.md`, `Widgets/CLAUDE.md`, `Shared/Screens/VideoPlayer/CLAUDE.md`, `Shared/DesignSystem/CLAUDE.md` (UI).
- **No new modifier on `AppNavigation.body`** (it is at the Release type-checker limit). Hook into existing handlers only: `bootstrap()` (root `.task`, `AppNavigation.swift:706`), `onChange(of: scenePhase)` (`:806`), `onChange(of: appState.serverURL)` (`:747`). Views read `ServerRouteController.shared` directly; no `.environment(...)` is added.
- Every new `ServerEntry` field is **optional** and carried over by `ServerRegistry.upsert`. Every new field of the extension session blob is optional in all three copies.
- New files → `cd /Users/braillard/projets/perso/jellyfin/Cinemax && xcodegen generate` before building. Never edit `project.pbxproj`.
- Every user-visible string goes through `loc.localized`, in **fr, en and de** (`Resources/{fr,en,de}.lproj/Localizable.strings`); CI checks parity.
- No address in any log or diagnostics line: only the class `local` / `internet` and the reason.
- SwiftLint strict (`--strict` against `.swiftlint-baseline.json`); never re-baseline a new violation.
- Probe timeouts: launch **1.0 s**, runtime **1.5 s**, extensions **1.0 s**. Every probe session sets `allowsCellularAccess = false`, `waitsForConnectivity = false`, `urlCache = nil`, and is ephemeral.
- Local means: IPv4 `10/8`, `172.16/12`, `192.168/16`, `169.254/16`; IPv6 `fc00::/7`, `fe80::/10`. Not local: loopback, CGNAT `100.64/10`, everything else.
- Test command (`RUN_TESTS`), run in full (`-only-testing` runs 0 swift-testing tests):
  ```bash
  cd /Users/braillard/projets/perso/jellyfin/Cinemax && set -o pipefail && xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipPackagePluginValidation 2>&1 | tee /tmp/cinemax-test.log | tail -5; grep -E '✘|Test run with' /tmp/cinemax-test.log | tail -20
  ```
  Expected: `✔ Test run with N tests … passed`, no `✘`. To check a suite ran, `grep 'Suite "<name>"' /tmp/cinemax-test.log`.

## Review Focus

1. **A same-server account switch** (`applyActiveServer` → `reconnect`, `serverURL` unchanged): the dial URL is reset to identity and must be re-evaluated. Covered by `accountSwitchReevaluatesRoute` (Task 8).
2. **The launch race**: `StreamTransportPolicy.configure(serverURL:)` at `AppNavigation.swift:447` runs after `restoreSession` returns, while the probe may already have pushed the LAN URL. It must not put identity back. Covered by `transportURLKeepsDialForSameIdentity` (Task 8).
3. **A `.local` name that resolves to a public address**: refused at save (`refusedNotLocal`) and never used as a route. Covered by `probeRejectsPublicConnectedAddress` (Task 3) and `saveRefusesPublicConnectedAddress` (Task 9).
4. **An `https` LAN address with a self-signed certificate**: the probe fails through the normal trust path, the route stays internet, and no pin prompt appears. Covered by `failedProbeKeepsInternet` (Task 8, failure outcome). Checked on device in Task 13.
5. **Leaving home mid-stream on the native engine**: after a route change, `retryWithDirectURL` re-negotiates instead of reopening the dead host. Covered by `PlaybackRetryPolicy` route tests (Task 10) and checked on device (Task 13).

---

### Task 1: The local-address classifier

**Files:**
- Create: `Packages/CinemaxKit/Sources/CinemaxKit/Models/LocalNetworkAddress.swift` (Foundation + Darwin only; it is shared BY SOURCE with both extensions in Task 12, like `ContentRatingClassifier.swift`)
- Modify: `Shared/Diagnostics/VerboseDiagnostics.swift:102-127` (`localAddressClass`)
- Create: `Tests/CinemaxKitTests/LocalServerAddressTests.swift` (this file collects every pure suite of the feature)
- Modify: `Tests/CinemaxKitTests/VerboseDiagnosticsTests.swift:125-133`

**Interfaces:**
- Produces:
  ```swift
  public enum LocalNetworkAddress {
      public enum Kind: Equatable, Sendable {
          case privateIPv4, linkLocalIPv4, cgnatIPv4, loopbackIPv4, publicIPv4
          case uniqueLocalIPv6, linkLocalIPv6, loopbackIPv6, publicIPv6
          case notAnIPLiteral
      }
      public static func kind(ofLiteral: String) -> Kind   // accepts "[fd00::1]", "fe80::1%en0"
      public static func isLocal(_ literal: String) -> Bool  // privateIPv4, linkLocalIPv4, uniqueLocalIPv6, linkLocalIPv6
      public static func isMDNSName(_ host: String) -> Bool  // ends in ".local", at least one label before it
      public static func isEligibleHost(_ host: String) -> Bool  // isLocal(host) || isMDNSName(host)
  }
  ```

- [ ] **Step 1: Write the failing tests** — `@Suite("Adresse locale — classement")` in `LocalServerAddressTests.swift`:
  - `rangeBoundaries`: `kind("10.0.0.1") == .privateIPv4`, `"172.15.255.255" == .publicIPv4`, `"172.16.0.0" == .privateIPv4`, `"172.31.255.255" == .privateIPv4`, `"172.32.0.0" == .publicIPv4`, `"192.168.1.128" == .privateIPv4`, `"192.169.0.1" == .publicIPv4`, `"169.254.3.4" == .linkLocalIPv4`, `"100.64.0.1" == .cgnatIPv4`, `"100.127.255.255" == .cgnatIPv4`, `"100.128.0.1" == .publicIPv4`, `"127.0.0.1" == .loopbackIPv4`.
  - `ipv6Forms`: `"fd12:3456::1" == .uniqueLocalIPv6`, `"fc00::1" == .uniqueLocalIPv6`, `"fe80::1c2b" == .linkLocalIPv6`, `"fe80::1%en0" == .linkLocalIPv6`, `"[fd00::5]" == .uniqueLocalIPv6`, `"::1" == .loopbackIPv6`, `"2a01:cb00:1234::5" == .publicIPv6`.
  - `malformedAndHostnames`: `"999.1.1.1"`, `"192.168.1"`, `"nas.lan"`, `"movies.nivadax.net"` and `""` are all `.notAnIPLiteral`.
  - `eligibility`: `isEligibleHost("192.168.1.128") && isEligibleHost("nas.local") && isEligibleHost("NAS.LOCAL")`; `!isEligibleHost("nas.lan")`, `!isEligibleHost(".local")`, `!isEligibleHost("100.64.0.1")`, `!isEligibleHost("127.0.0.1")`, `!isEligibleHost("8.8.8.8")`.
- [ ] **Step 2: Update `VerboseDiagnosticsTests` (`:125-133`)**: keep every existing expectation and add `localAddressClass("999.1.1.1") == "unknown"` and `localAddressClass("nas.local") == "unknown"` (they printed `public-ipv6`; the spec says that quirk must not survive).
- [ ] **Step 3: `xcodegen generate`, then `RUN_TESTS`.** Expected: compile failure, `cannot find 'LocalNetworkAddress'`.
- [ ] **Step 4: Implement `LocalNetworkAddress`** with `inet_pton(AF_INET / AF_INET6)` on the literal, after stripping `[...]` and any `%zone`. A 4-byte or 16-byte compare decides the range. Then rewrite `localAddressClass` on top of `kind(ofLiteral:)`:
  - privateIPv4 → `"a.b.c.0/24"`
  - cgnatIPv4 → `"cgnat"`
  - linkLocalIPv4 → `"link-local"`
  - loopback (IPv4 or IPv6) → `"loopback"`
  - publicIPv4 → `"public-ipv4"`
  - uniqueLocalIPv6 → `"ula-ipv6"`
  - linkLocalIPv6 → `"link-local-ipv6"`
  - publicIPv6 → `"public-ipv6"`
  - notAnIPLiteral → `"unknown"`
  - nil or empty input → `nil`
- [ ] **Step 5: `RUN_TESTS`.** Expected: all pass, and `Suite "Adresse locale — classement"` appears in the log.
- [ ] **Step 6: Commit** `feat(kit): local-address classifier, single source of truth`.

### Task 2: Storing the local address

**Files:**
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Models/ServerEntry.swift` (field and memberwise init, `:38-89`)
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Models/ServerRegistry.swift:117-154` (`upsert`)
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Models/ServerURLNormalizer.swift`
- Modify: `Shared/Navigation/AppState.swift`, next to `renameServer` (`:618-632`)
- Test: `LocalServerAddressTests.swift`, `ServerRegistryTests.swift`

**Interfaces:**
- Produces:
  - `ServerEntry.localURL: URL?` (normalized; `nil` = none). It is the last init parameter: `localURL: URL? = nil`.
  - In `ServerURLNormalizer`:
    ```swift
    public enum LocalAddressInputError: Error, Equatable, Sendable { case malformed, notLocal }
    public static func normalizeLocal(_ raw: String) -> Result<URL, LocalAddressInputError>
    ```
  - In `AppState`:
    - `@discardableResult func setLocalURL(id: String, to url: URL?) -> ServerEntry?` — the only writer of the field. Model it on `renameServer`: equality guard, then `persistRegistry()`.
    - `@discardableResult func adoptServerID(id: String, serverID: String) -> ServerEntry?` — writes `serverID` only when the entry has none.

- [ ] **Step 1: Write the failing tests.**
  - `@Suite("Adresse locale — saisie")`:
    - `bareHostDefaultsToHTTP`: `normalizeLocal("192.168.1.128:8899") == .success(URL(string: "http://192.168.1.128:8899")!)`.
    - `keepsHTTPSAndSubPath`: `normalizeLocal("https://192.168.1.128/jellyfin/")` gives `https://192.168.1.128/jellyfin`.
    - `acceptsMDNS`: `normalizeLocal("nas.local:8096")` gives `http://nas.local:8096`.
    - `acceptsBracketedIPv6`: `normalizeLocal("[fd00::5]:8096")` gives `http://[fd00::5]:8096`.
    - `refusals`:
      - `normalizeLocal("nas.lan") == .failure(.notLocal)`
      - `"movies.nivadax.net"`, `"http://8.8.8.8"` and `"100.64.1.2"` → `.notLocal`
      - `"ftp://192.168.1.2"`, `"   "` and `"http://"` → `.malformed`
  - In `ServerRegistryTests` (`@Suite("ServerRegistry")`):
    - `upsertKeepsLocalURL`: the stored entry has `localURL = http://192.168.1.128:8899`, the incoming one has `nil` → the result keeps the stored value.
    - `legacyRegistryDecodesWithoutLocalURL`: a JSON `[ServerEntry]` without the key decodes, with `localURL == nil`.
    - `localURLRoundTrips`: encode then decode keeps it.
  - In `@Suite("Multi-server AppState")`:
    - `setLocalURLPersists`: `setLocalURL` then `keychain.getServers()` carries it.
    - `adoptServerIDDoesNotOverwrite`: an entry with `serverID "A"` keeps `"A"` after `adoptServerID(…, "B")`; one with `nil` gets `"B"`.
- [ ] **Step 2: `RUN_TESTS`.** Expected: compile failure on `localURL` / `normalizeLocal`.
- [ ] **Step 3: Implement.**
  - `normalizeLocal`: trim; if there is no `"://"`, prepend `http://` (never `https://`); run `normalize(URL)`; `nil` → `.malformed`; a host outside `LocalNetworkAddress.isEligibleHost` → `.notLocal`.
  - `upsert`: add `localURL: existing.localURL` to the rebuild. Doc comment: user-owned, like `displayNameOverride`.
  - Extend the RULE comment above `upsert` and the field's doc in `ServerEntry` (optional; written only by `AppState.setLocalURL`).
- [ ] **Step 4: `RUN_TESTS`.** Expected: pass.
- [ ] **Step 5: Commit** `feat(kit): optional ServerEntry.localURL, carried by upsert`.

### Task 3: Route policy and probe

**Files:**
- Create: `Packages/CinemaxKit/Sources/CinemaxKit/Models/ServerRoute.swift`
- Create: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/LocalRouteProbe.swift`
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/ServerReachability.swift:7-12, 63-71` (`PingResult`, `PublicSystemInfoLite`)
- Modify: `Shared/Screens/ServersScreen.swift:95-103` (`apply`: the new associated value)
- Test: `LocalServerAddressTests.swift`

**Interfaces:**
- Produces, in `ServerRoute.swift`:
  ```swift
  public enum ServerRouteKind: String, Sendable { case local, internet }
  public enum NetworkReach: Sendable, Equatable { case lanCapable, cellularOnly, offline }
  public enum LocalProbeOutcome: Equatable, Sendable {
      case answered(serverID: String, connectedAddressIsLocal: Bool)
      case failed(localNetworkDenied: Bool)
  }
  public enum ServerRoutePolicy {
      public static func shouldProbe(localURL: URL?, reach: NetworkReach) -> Bool
      /// nil = dial the public URL.
      public static func decide(localURL: URL?, reach: NetworkReach, expectedServerID: String?, probe: LocalProbeOutcome?) -> URL?
      public static func kind(ofDialURL: URL) -> ServerRouteKind   // host classified by LocalNetworkAddress; ".local" → local
      /// Swaps identity base → dial base; nil when `url` is not under the identity base.
      public static func rewrite(_ url: URL, identityBase: URL, dialBase: URL) -> URL?
      public static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool   // scheme + host + effective port
  }
  ```
- Produces, in `LocalRouteProbe.swift`:
  ```swift
  public enum LocalRouteProbe {
      public static let launchTimeout: TimeInterval = 1.0
      public static let runtimeTimeout: TimeInterval = 1.5
      public static func probe(_ localURL: URL, timeout: TimeInterval, session: URLSession? = nil) async -> LocalProbeOutcome
      static func evaluate(statusCode: Int, body: Data, connectedAddress: String?) -> LocalProbeOutcome  // pure
  }
  ```
  - Request: `GET <local>/System/Info/Public` built with `setEndpointPath(_:preservingBasePathOf:)`, `Accept: application/json`, **no Authorization header**.
  - Session: ephemeral, the global-constraint settings, session delegate `ServerTrustDelegate.shared`.
  - Per-task delegate (`session.data(for:delegate:)`): refuses every redirect (`completionHandler(nil)`) and records `URLSessionTaskTransactionMetrics.remoteAddress` from `didFinishCollecting`.
  - `connectedAddress` is that metric, else the host when it is an IP literal.
  - `localNetworkDenied` is `false` here; Task 9 detects it.
- Produces: `PingResult.online(name: String?, version: String?, serverID: String?)`, with `PublicSystemInfoLite` decoding `"Id"`.

- [ ] **Step 1: Write the failing tests.**
  - `@Suite("Adresse locale — décision de route")`:
    - `noLocalAddressIsInternet`: `decide(localURL: nil, reach: .lanCapable, expectedServerID: "S", probe: nil) == nil`.
    - `cellularNeverProbes`: `!shouldProbe(localURL: lan, reach: .cellularOnly)`, `!shouldProbe(localURL: lan, reach: .offline)`, `shouldProbe(localURL: lan, reach: .lanCapable)`.
    - `probeOKIsLocal`: `.answered(serverID: "S", connectedAddressIsLocal: true)` with expected `"S"` → `lan`.
    - `failedProbeIsInternet`: `.failed(localNetworkDenied: false)` → `nil`.
    - `idMismatchIsInternet`: `.answered("OTHER", true)` with expected `"S"` → `nil`.
    - `publicConnectedAddressIsInternet`: `.answered("S", false)` → `nil`.
    - `unknownExpectedIdIsInternet`: expected `nil`, `.answered("S", true)` → `nil`. The token never goes to an unproven machine.
  - `@Suite("Adresse locale — sonde")`:
    - `probeAcceptsMatchingBody`: `evaluate(statusCode: 200, body: #"{"Id":"S","ServerName":"NAS"}"#, connectedAddress: "192.168.1.128") == .answered(serverID: "S", connectedAddressIsLocal: true)`.
    - `probeRejectsPublicConnectedAddress`: the same body with `connectedAddress: "86.245.10.3"` → `.answered("S", false)`.
    - `probeRejectsNon200`: statuses 301, 401 and 500 → `.failed(localNetworkDenied: false)`.
    - `probeRejectsBodyWithoutId`: `#"{"ServerName":"NAS"}"#` → `.failed(localNetworkDenied: false)`.
  - `@Suite("Adresse locale — réécriture d'URL")`:
    - `rewriteNoBasePaths`: `rewrite("https://movies.nivadax.net/Items/1/Images/Primary?tag=t", identityBase: "https://movies.nivadax.net", dialBase: "http://192.168.1.128:8899")` gives `http://192.168.1.128:8899/Items/1/Images/Primary?tag=t`.
    - `rewriteIdentityBasePathToRoot`: identity `https://box.example.org/jellyfin`, dial `http://192.168.1.128:8096`. `https://box.example.org/jellyfin/Items/1/Images/Primary` gives `http://192.168.1.128:8096/Items/1/Images/Primary`.
    - `rewriteRootToDialBasePath`: identity `https://movies.nivadax.net`, dial `http://nas.local/jellyfin`. `/Items/1` gives `http://nas.local/jellyfin/Items/1`.
    - `rewriteLeavesForeignURL`: a URL on another host gives `nil`.
    - `kindOfDialURL`: `kind(ofDialURL: "http://192.168.1.128:8899") == .local`, `"http://nas.local" == .local`, `"https://movies.nivadax.net" == .internet`.
- [ ] **Step 2: `xcodegen generate`, then `RUN_TESTS`.** Expected: compile failure.
- [ ] **Step 3: Implement** `ServerRoute.swift` and `LocalRouteProbe.swift`, and the `PingResult` change. Update the one pattern match in `ServersScreen.apply`, which passes the id through `updateServerMetadata(id:name:version:serverID:)` (`AppState.swift:607`). This also fills a missing `serverID` from the public URL.
- [ ] **Step 4: `RUN_TESTS`.** Expected: pass.
- [ ] **Step 5: Commit** `feat(kit): route policy, unauthenticated local probe, Id in the public ping`.

### Task 4: The API client dials a separate URL

**Files:**
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient.swift`:
  - `ClientState` `:46-89`
  - accessors `:119-143`
  - `setPreferredLanguage` `:153-166`
  - `makeClient` `:189-204`
  - `connectToServer` `:306-330`
  - `fetchServerInfo` `:333-371`
  - `authenticate` `:373`, `authenticateWithQuickConnect` `:430`
  - `reconnect` `:483-507`
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift:12-92` (`ServerAPI` and its defaults)
- Modify: `Tests/CinemaxKitTests/MockAPIClient.swift`
- Test: `ServerCompatibilityTests.swift` (`@Suite("JellyfinAPIClient — état de connexion")`, `:177`), `AcceptLanguageTests.swift`

**Interfaces:**
- Produces (`ServerAPI`; each has a default so other conformers compile):
  - `func setDialURL(_ dialURL: URL?)` — default no-op. `nil` = dial the identity URL.
  - `func currentDialURL() -> URL?` — default `nil`. The base the client dials now.
  - `func connectToServer(url: URL, dialURL: URL?) async throws -> ServerInfo` — default forwards to `connectToServer(url:)`.
- Internal changes:
  - `ClientState.dialURL: URL?`.
  - `install(_ client:, url identity: URL, dialURL: URL?, accessToken:, ifGeneration:)`.
  - `getServerURL()` stays IDENTITY. New `getDialURL()` returns `dialURL ?? serverURL`.
  - `getConnection()` returns the DIAL URL. Its callers (`+Playback.swift:23`, `+RemoteControl.swift:194`, `+Diagnostics.swift:45`) all want it.
  - `connectionWithGeneration()` returns `(client, identity, dial, generation)`.
- `MockAPIClient` records `dialURLs: [URL?]` in `setDialURL` and returns the last one from `currentDialURL()`. Its `reconnect` resets it to `nil`.

- [ ] **Step 1: Write the failing tests** in `JellyfinClientStateTests`:
  - `dialURLRebuildsInPlace`: `reconnect(identity, "tok")`, `setServerVersion("12.0.0")`, `setDialURL(lan)`. Then `getServerURL() == identity`, `getDialURL() == lan`, `getConnection()?.serverURL == lan`, the SDK client's configuration URL `== lan`, `knownServerVersion() == 12.0.0`, and the token is kept.
  - `reconnectResetsDialURL`: `setDialURL(lan)`, then `reconnect(identity, "tok")`. `getDialURL() == identity`.
  - `languageChangeKeepsDial`: `setDialURL(lan)`, then `setPreferredLanguage("de")`. `getDialURL() == lan`, `getServerURL() == identity`.
  - `staleDialWriteRefused`: a `reconnect(otherServer, …)` that lands between the snapshot and the install of `setDialURL`. The dial stays the other server's identity. Hold the race with `TestLatch`, or test `install(…ifGeneration:)` directly as the existing suite does.
  - `connectWithDialInstallsIdentity`: against an `URLProtocol` stub answering `/System/Info/Public` on `lan` only, `connectToServer(url: identity, dialURL: lan)` returns `info.url == identity`, then `getServerURL() == identity` and `getDialURL() == lan`.
  - `fetchServerInfoKeepsVersionAcrossDial` (if a stub seam exists; otherwise assert through `install` + the `isSameServer` compare): the version-write guard compares IDENTITY.
- [ ] **Step 2: `RUN_TESTS`.** Expected: compile failure on `setDialURL`.
- [ ] **Step 3: Implement.**
  - `makeClient(url:)` is called with the dial URL everywhere.
  - `setDialURL` copies `setPreferredLanguage`'s shape: snapshot under the lock, build, `install(ifGeneration:)`. No `cache.clear()`: `APICache` keys carry no URL. A no-op when unchanged.
  - `reconnect` and `connectToServer(url:)` set `dialURL = nil`.
  - `authenticate` / `authenticateWithQuickConnect` / `setPreferredLanguage` carry both URLs through `install`.
  - `fetchServerInfo` returns and compares identity.
  - Also update the `ClientState` RULE in `Packages/CinemaxKit/CLAUDE.md`: identity and dial live under the one lock; `getConnection` is the dial.
- [ ] **Step 4: `RUN_TESTS`** (the `Accept-Language` suite included, since `rebuildKeepsSession` reads `getServerURL`). Expected: pass.
- [ ] **Step 5: Commit** `feat(kit): JellyfinAPIClient dial URL beside the identity URL`.

### Task 5: Images load from the route

**Files:**
- Create: `Shared/Navigation/RoutedImageDataLoader.swift`
- Modify: `Shared/Navigation/AppNavigation.swift:147-165` (`configurePipeline`)
- Modify: `Packages/CinemaxKit/CLAUDE.md:31` (the Nuke `DataLoader` RULE)
- Test: `LocalServerAddressTests.swift`

**Interfaces:**
- Consumes: `ServerRoutePolicy.rewrite(_:identityBase:dialBase:)` (Task 3).
- Produces:
  ```swift
  final class ImageRouteTable: @unchecked Sendable {   // NSLock-protected
      static let shared: ImageRouteTable
      func set(identity: URL?, dial: URL?)   // dial nil or == identity → no rewrite
      func rewrite(_ request: URLRequest) -> URLRequest
  }
  final class RoutedImageDataLoader: DataLoading {
      init(wrapping base: any DataLoading, table: ImageRouteTable = .shared)
  }
  ```
  `RoutedImageDataLoader` forwards `loadData(with: table.rewrite(request), …)` to `base`.

- [ ] **Step 1: Write the failing tests** — `@Suite("Adresse locale — images")`:
  - `tableRewritesUnderIdentity`: `set(identity: https://movies.nivadax.net, dial: http://192.168.1.128:8899)`. A request for `https://movies.nivadax.net/Items/1/Images/Primary` becomes `http://192.168.1.128:8899/Items/1/Images/Primary`, keeping every header (`Authorization` included).
  - `tableNoDialIsIdentity`: `set(identity:, dial: nil)` leaves the request unchanged.
  - `loaderForwardsRewrittenRequest`: a spy `DataLoading` records the URL it receives. It is the dial one.
  - `cacheKeyStaysIdentity`: `ImageRequest(url: identityURL).imageId == identityURL.absoluteString` with the table set to a dial base. Nuke computes the key before the loader runs.
- [ ] **Step 2: `xcodegen generate`, then `RUN_TESTS`.** Expected: compile failure.
- [ ] **Step 3: Implement.** In `configurePipeline`, keep `(config.dataLoader as? DataLoader)?.delegate = ServerTrustDelegate.shared`, then `config.dataLoader = RoutedImageDataLoader(wrapping: config.dataLoader)`. The configured loader and its session survive; only the request URL changes. Amend the CinemaxKit RULE: « mutated and WRAPPED, never rebuilt ».
- [ ] **Step 4: `RUN_TESTS`.** Expected: pass.
- [ ] **Step 5: Commit** `feat: images load from the current route, cache keyed on identity`.

### Task 6: The socket follows the route

**Files:**
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinSocket.swift:370-431` (`JellyfinSocketHub`)
- Test: `Tests/CinemaxKitTests/JellyfinSocketHubTests.swift`

**Interfaces:**
- Produces: `public func repoint(endpoint: RealtimeSocketEndpoint)` on `JellyfinSocketHub`. When a socket is active and `!activeEndpoint.isSameConnection(as: endpoint)`, it runs `ensureSocket(endpoint:)`; subscribers are kept. With no subscriber or no socket, it does nothing (the next `subscribe` builds on the endpoint it is handed).

- [ ] **Step 1: Write the failing tests**, with the suite's existing seams:
  - `repointRebuildsActiveSocket`: subscribe with endpoint A, `repoint(B)` → the active endpoint is B and the subscriber count is unchanged.
  - `repointWithoutSubscribersIsNoop`: `repoint(B)` with nothing subscribed → no socket.
  - `repointSameEndpointIsNoop`: `repoint(A)` while on A → the same socket instance.
- [ ] **Step 2: `RUN_TESTS`.** Expected: compile failure.
- [ ] **Step 3: Implement** `repoint`.
- [ ] **Step 4: `RUN_TESTS`.** Expected: pass.
- [ ] **Step 5: Commit** `feat(kit): socket hub repoint on a route change`.

### Task 7: Network path awareness

**Files:**
- Modify: `Shared/ViewModels/NetworkMonitor.swift`
- Test: `LocalServerAddressTests.swift`

**Interfaces:**
- Consumes: `NetworkReach` (Task 3).
- Produces:
  - `private(set) var reach: NetworkReach` (plain stored, no `didSet`; root RULE).
  - `@ObservationIgnored var onPathChange: (@MainActor () -> Void)?` — called on the main actor when the path SIGNATURE changes. The signature is status, the Wi-Fi/wired/cellular use flags and `path.gateways` described; a Wi-Fi⇄Wi-Fi move changes the gateways.
  - `nonisolated static func reach(isSatisfied: Bool, usesWiFiOrWired: Bool) -> NetworkReach` (pure).
  - `nonisolated static func signature(of path: NWPath) -> String`.
  - `isOnline` is unchanged.

- [ ] **Step 1: Write the failing test** — `@Suite("Adresse locale — réseau")` `reachMapping`:
  - `(true, true) → .lanCapable`
  - `(true, false) → .cellularOnly`
  - `(false, true) → .offline`
  - `(false, false) → .offline`
- [ ] **Step 2: `RUN_TESTS`.** Expected: compile failure.
- [ ] **Step 3: Implement.** Seed `reach` from `monitor.currentPath` in `init`, like `isOnline`. Call `onPathChange` only when the signature differs from the last one, never on the seed.
- [ ] **Step 4: `RUN_TESTS`.** Expected: pass.
- [ ] **Step 5: Commit** `feat: NetworkMonitor reports LAN capability and path changes`.

### Task 8: The route owner

**Files:**
- Create: `Shared/Navigation/ServerRouteController.swift`
- Modify: `Shared/Navigation/AppState.swift`:
  - seams near `:52-65`
  - `restoreSession` `:169-221`
  - `applyActiveServer` `:506-602` (after `reconnect`, `:563`)
- Modify: `Shared/Navigation/AppNavigation.swift`:
  - `bootstrap()` `:245-462`: wiring before `restoreSession` (`:311`); the transport line `:447`
  - `onChange(of: appState.serverURL)` `:747-749`
  - `onChange(of: scenePhase)`, `.active` branch `:840-881`
- Modify: `Shared/Diagnostics/DiagnosticsReport.swift:45-122`, `Shared/Screens/Settings/DiagnosticsExportRows.swift:130`, `Shared/Diagnostics/DiagnosticsUploader.swift:105-114`
- Test: create `Tests/CinemaxKitTests/ServerRouteControllerTests.swift`; extend `DiagnosticsTests.swift:202-229`

**Interfaces:**
- Consumes:
  - `ServerRoutePolicy`, `LocalRouteProbe`, `NetworkReach` (Task 3)
  - `setDialURL` / `currentDialURL` (Task 4)
  - `ImageRouteTable.shared.set` (Task 5)
  - `JellyfinSocketHub.shared.repoint` + `apiClient.makeRealtimeSocketEndpoint()` (Task 6)
  - `NetworkMonitor.reach` / `onPathChange` (Task 7)
- Produces:
  ```swift
  enum ServerRouteReason: String, Sendable { case launch, foreground, pathChange, serverChange, addressChanged }
  @MainActor @Observable final class ServerRouteController {
      static let shared: ServerRouteController
      private(set) var route: ServerRouteKind            // the ACTIVE server's route, read by ServersScreen / Settings / diagnostics
      private(set) var dialURL: URL?                     // nil = identity
      init(probe: @escaping @Sendable (URL, TimeInterval) async -> LocalProbeOutcome = LocalRouteProbe.probe(_:timeout:))
      func attach(appState: AppState, reach: @escaping @MainActor () -> NetworkReach)
      func evaluate(_ reason: ServerRouteReason) async
      func pathChanged()                                 // applies identity AT ONCE, then evaluate(.pathChange)
      func dialURL(for entry: ServerEntry) async -> URL  // decides for any entry (switch target, re-login); never pushes
      func transportURL(identity: URL?) -> URL?          // dialURL when it belongs to `identity`, else identity
      func awaitPendingProbe() async                     // bounded by the probe's own timeout
  }
  ```
  - `evaluate`: reads the active entry (`appState.servers` + `activeServerId`) and `reach()`.
    - Probe or not per `shouldProbe`. The timeout is `launchTimeout` for `.launch`, else `runtimeTimeout`.
    - Decide with `expectedServerID: entry.serverID`.
    - Drop the result when `activeServerId` changed or a newer evaluation started (generation counter).
    - Then `apply`.
  - `apply(dial:)`:
    - `apiClient.setDialURL(dial)`
    - `ImageRouteTable.shared.set(identity: entry.url, dial: dial)`
    - `StreamTransportPolicy.shared.configure(serverURL: dial ?? entry.url)`
    - `JellyfinSocketHub.shared.repoint(…)` with a fresh endpoint
    - update `route` / `dialURL`
    - one `Logger(subsystem: "com.cinemax", category: "Servers")` notice `route → local|internet (reason: <reason>)`, no address
    - when the reason is `.launch` and the result is local, post `.cinemaxShouldRefreshCatalogue`: Home's first load may have gone to a dead public URL with the tunnel down.
  - **AppState seams** (closure vars beside `sessionValidator`, defaulted so tests and intents need nothing):
    - `var prepareRoute: @MainActor () async -> Void = {}` — awaited FIRST inside `restoreSession`'s background Task (before `fetchServerInfo`), never on the awaited path, so `hasCheckedSession` is not delayed.
    - `var onClientRepointed: @MainActor () -> Void = {}` — called right after `apiClient.reconnect` in `applyActiveServer`. This is the same-server account switch too.
    - `var routeURL: @MainActor (ServerEntry) async -> URL = { $0.url }` — used in Task 9.
  - **Wiring in `bootstrap()`**, before `restoreSession` (`:311`):
    - `serverRoute.attach(appState:reach:)` with `{ [network] in network.reach }`
    - `network.onPathChange = { serverRoute.pathChanged() }`
    - `appState.prepareRoute = { await serverRoute.evaluate(.launch) }`
    - `appState.onClientRepointed = { Task { await serverRoute.evaluate(.serverChange) } }`
    - `appState.routeURL = { await serverRoute.dialURL(for: $0) }`
    
    `serverRoute` is `ServerRouteController.shared`, held as a `private let` capture, not `@State`: no environment injection.
  - **Transport sites:** `:447` and `:749` become `StreamTransportPolicy.shared.configure(serverURL: ServerRouteController.shared.transportURL(identity: appState.serverURL))`.
  - **Foreground:** inside the existing `.active` branch, add `Task { await ServerRouteController.shared.evaluate(.foreground) }`.
  - **Diagnostics:**
    - `DiagnosticsFacts.serverRoute: String? = nil` (a memberwise default).
    - `header` appends `server_route: <value>` LAST, after `network`, only when non-nil.
    - Both callers set `facts.serverRoute = ServerRouteController.shared.route.rawValue`.

- [ ] **Step 1: Write the failing tests** in `ServerRouteControllerTests.swift` — `@Suite("Adresse locale — route active")`, `@MainActor`. Use `MockAPIClient` + `MockKeychain` + a stub probe closure; the active entry has `url = https://movies.nivadax.net`, `serverID = "S"`, `localURL = http://192.168.1.128:8899`:
  - `launchAtHomeGoesLocal`: reach `.lanCapable`, probe `.answered("S", true)` → `api.dialURLs.last == lan`, `route == .local`, and one `.cinemaxShouldRefreshCatalogue` posted.
  - `cellularSkipsProbe`: reach `.cellularOnly` → the probe closure is never called; `route == .internet`; `api.dialURLs.last == nil` (or none).
  - `failedProbeKeepsInternet`: `.failed(false)` → `route == .internet`.
  - `pathChangeFallsBackFirst`: on local, then `pathChanged()` with the probe held open by `TestLatch` → before release, `api.dialURLs.last == nil` and `route == .internet`; after release with `.answered("S", true)` → local again.
  - `staleProbeDropped`: switch the active entry while the probe is held → after release, nothing is applied for the old entry.
  - `accountSwitchReevaluatesRoute`: `AppState.applyActiveServer` on the same server (`reconnect` → `onClientRepointed`) → `evaluate(.serverChange)` runs and the dial returns to the LAN.
  - `transportURLKeepsDialForSameIdentity`: on local, `transportURL(identity: entryURL) == lan`, `transportURL(identity: otherURL) == otherURL`, `transportURL(identity: nil) == nil`.
  - `noServerIDNeverLocal`: entry `serverID = nil` → internet whatever the probe says.
- [ ] **Step 2: Write the failing test** in `DiagnosticsTests`: `headerCarriesServerRoute` — `DiagnosticsFacts(…, serverRoute: "local")` → the last header line is `"server_route: local"`. The existing `headerLines` test stays byte-identical.
- [ ] **Step 3: `xcodegen generate`, then `RUN_TESTS`.** Expected: compile failure.
- [ ] **Step 4: Implement** the controller, the seams, the wiring and the diagnostics field. Check that `AppNavigation.body` gains no modifier: the diff only touches lines inside `bootstrap()`, `:747-749` and the scenePhase closure.
- [ ] **Step 5: `RUN_TESTS`.** Expected: pass.
- [ ] **Step 6: Release type-check of the root view** — `set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -configuration Release -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation 2>&1 | tail -3`. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 7: Commit** `feat: ServerRouteController — local first at launch, foreground, path change, switches`.

### Task 9: Switches, re-login and saving the address

**Files:**
- Modify: `Shared/Navigation/AppState.swift`:
  - `switchTo` `:650-692` (validator `:677`)
  - `switchAccount` `:1061-1092` (validator `:1080`)
  - `beginReLogin` `:699-716` (`:705`)
  - new `setLocalAddress`
- Create: `Packages/CinemaxKit/Sources/CinemaxKit/Models/LocalAddressSavePolicy.swift`
- Create: `Shared/Navigation/LocalNetworkPermission.swift` (iOS; tvOS returns `false`)
- Test: `LocalServerAddressTests.swift`, `ServerRegistryTests.swift` (`@Suite("Multi-server AppState")`)

**Interfaces:**
- Consumes: `AppState.routeURL` (Task 8), `connectToServer(url:dialURL:)` (Task 4), `normalizeLocal` / `setLocalURL` / `adoptServerID` (Task 2), `LocalRouteProbe` and `PingResult.online(…serverID:)` (Task 3).
- Produces:
  ```swift
  public enum LocalAddressSaveOutcome: Equatable, Sendable {
      case removed, reachable, savedUnreachable, savedLocalNetworkDenied
      case refusedNotLocal, refusedOtherServer, needsSignIn
  }
  public struct LocalAddressSaveDecision: Equatable, Sendable {
      public let outcome: LocalAddressSaveOutcome
      public let saves: Bool
      public let serverIDToAdopt: String?
  }
  public enum LocalAddressSavePolicy {
      public static func decide(knownServerID: String?, publicServerID: String?, probe: LocalProbeOutcome) -> LocalAddressSaveDecision
  }
  ```
  - The decision table is the owner's decision in the spec's « Missing `serverID` ». `expected = knownServerID ?? publicServerID`.
    - `.answered(_, connectedAddressIsLocal: false)` → `refusedNotLocal`, no save.
    - `.answered(id, true)` with `expected == nil` → `reachable`, saves, adopts `id`.
    - `.answered(id, true)` with `id == expected` → `reachable`, saves, adopts `publicServerID` when `knownServerID == nil`.
    - `.answered(id, true)` with `id != expected` → `refusedOtherServer`, no save.
    - `.failed` with `expected == nil` → `needsSignIn`, no save.
    - `.failed(localNetworkDenied: true)` → `savedLocalNetworkDenied`, saves.
    - `.failed(false)` → `savedUnreachable`, saves, adopts `publicServerID` when it was unknown.
  - Wiring: in `bootstrap()`, beside the Task 8 seams, `appState.onLocalAddressChanged = { Task { await serverRoute.evaluate(.addressChanged) } }`.
  - In `AppState`:
    - `func setLocalAddress(id: String, raw: String) async -> LocalAddressSaveOutcome`:
      1. Blank → `setLocalURL(nil)`, `.removed`.
      2. `normalizeLocal` failure → `.refusedNotLocal`.
      3. If the entry has no `serverID`, read it from `ServerReachability.ping(url: entry.url)`.
      4. Probe the local URL with `runtimeTimeout`.
      5. On `.failed`, ask `LocalNetworkPermission.isDenied(url)`.
      6. Run `decide`, then write via `setLocalURL` / `adoptServerID`.
      7. When the entry is the active one, call `ServerRouteController.shared.evaluate(.addressChanged)` through the `onClientRepointed`-style seam `var onLocalAddressChanged: @MainActor () -> Void = {}`.
    - Seams for tests: `var localProbe: @Sendable (URL, TimeInterval) async -> LocalProbeOutcome = LocalRouteProbe.probe(_:timeout:)` and `var publicPing: @Sendable (URL) async -> PingResult = { await ServerReachability.ping(url: $0) }`.
    - `enum LocalNetworkPermission { static func isDenied(_ url: URL) async -> Bool }`: an `NWConnection` to host:port. `true` when it enters `.waiting` with `currentPath?.unsatisfiedReason == .localNetworkDenied`, bounded at 1 s. Verify on device in Task 13.
  - Switches and re-login:
    - `switchTo` and `switchAccount` validate with `sessionValidator(await routeURL(entry), token)`.
    - `beginReLogin` calls `apiClient.connectToServer(url: entry.url, dialURL: await routeURL(entry))`, dial passed only when it differs from `entry.url`.
    - The two-phase RULE is unchanged: still off the shared client, and `.indeterminate` still destroys nothing.

- [ ] **Step 1: Write the failing tests.**
  - `@Suite("Adresse locale — enregistrement")`: one `@Test` per row of the table above, with literal ids `"S"` / `"OTHER"`, plus `saveRefusesPublicConnectedAddress`.
  - `@Suite("Multi-server AppState")`:
    - `switchValidatesOnRoute`: `routeURL` returns `lan` → `sessionValidator` receives `lan`.
    - `reLoginConnectsOnRoute`: the mock records `connectToServer(url:dialURL:)` with `(identity, lan)`.
    - `setLocalAddressAdoptsLocalIdWhenPublicDown`: entry with no `serverID`, `publicPing` returns `.offline`, `localProbe` returns `.answered("S", true)` → outcome `.reachable`, and the entry gets `serverID == "S"` and its `localURL`.
    - `setLocalAddressOtherServerSavesNothing`: entry `serverID "S"`, probe `.answered("OTHER", true)` → `.refusedOtherServer`, `localURL` unchanged.
    - `setLocalAddressBlankRemoves`: → `.removed`, `localURL == nil`.
- [ ] **Step 2: `xcodegen generate`, then `RUN_TESTS`.** Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: `RUN_TESTS`.** Expected: pass, `SessionResilienceTests` and `MultiAccountTests` included.
- [ ] **Step 5: Commit** `feat: switches and re-login on the target's route; saving the local address`.

### Task 10: Playback follows the route

**Files:**
- Modify: `Shared/Screens/VideoPlayer/PlaybackEndDecision.swift:130-178` (`PlaybackRetryPolicy`)
- Modify: `Shared/Screens/VideoPlayer/VLCStreamPresenter.swift`:
  - `handlePlaybackError` `:5562-5678`
  - `reResolveAndResume` `:5821` (before `getPlaybackInfo`, `:5860`)
- Modify: `Shared/Screens/NativeVideoPresenter.swift:414-464` (`retryWithDirectURL`)
- Modify: `Shared/ViewModels/VideoPlayerCoordinator.swift:72-83` (tvOS open), `Shared/Screens/VideoPlayerView.swift:187-200` (`negotiate`, iOS open)
- Test: `Tests/CinemaxKitTests/PlaybackEndDecisionTests.swift` (`PlaybackRetryPolicyTests`, `:270`)

**Interfaces:**
- Consumes: `ServerRoutePolicy.isSameOrigin` (Task 3), `apiClient.currentDialURL()` (Task 4), `ServerRouteController.shared.awaitPendingProbe()` (Task 8).
- Produces:
  - `PlaybackRetryDecision.rebuildOnCurrentRoute`.
  - `PlaybackRetryPolicy.decide(didRetry:errorAlertShowing:retryPending:usingProxy:routeChanged: Bool = false)`. When `!didRetry && routeChanged` it returns `.rebuildOnCurrentRoute`; every other row is unchanged.
  - `static func routeChanged(negotiated: URL, currentDial: URL?) -> Bool`: `false` when `currentDial` is nil, else `!isSameOrigin`.

- [ ] **Step 1: Write the failing tests** in `PlaybackRetryPolicyTests`:
  - `routeChangeRebuilds`: `decide(didRetry: false, …, usingProxy: false, routeChanged: true) == .rebuildOnCurrentRoute`.
  - `routeChangeAfterRetryGivesUp`: `didRetry: true, routeChanged: true` → `.giveUp(releaseStickyProxy: false)`.
  - `routeChangedCompare`:
    - `routeChanged(negotiated: "http://192.168.1.128:8899/Videos/1/stream", currentDial: "https://movies.nivadax.net")` is true
    - the same host and port → false
    - `currentDial: nil` → false
  - The existing rows stay green (default `routeChanged: false`).
- [ ] **Step 2: `RUN_TESTS`.** Expected: compile failure.
- [ ] **Step 3: Implement the policy, then the presenters.**
  - **VLC `handlePlaybackError`**: compute `routeChanged` from `info.url` and `apiClient.currentDialURL()`. On `.rebuildOnCurrentRoute`: set `didRetry = true`, then `if !rebuildSpendingRecovery(from: lastKnownPositionMs)` fall through to the give-up tail. The shared rebuild budget bounds any loop: never call `reResolveAndResume` directly here, since it resets `didRetry` (CLAUDE.md « only `noteMediaOpened()` renews `didRetry` »).
  - **VLC `reResolveAndResume`**: `await ServerRouteController.shared.awaitPendingProbe()` before `getPlaybackInfo`.
  - **Native `retryWithDirectURL`** (iOS): if `routeChanged(negotiated: info.url, currentDial: apiClient.currentDialURL())`, re-negotiate `getPlaybackInfo(itemId:userId:maxBitrate:engine: .native, mediaSourceId: info.mediaSourceId)` (fields as `switchTracks`, `:555`). Release the replaced session the way `switchTracks` does, set `playbackInfo = fresh`, and build the item from `fresh`. A failed re-negotiation goes to `showPlaybackErrorAlert`. `hasRetriedDirectURL` still bounds it to once.
  - **Opens**: `await ServerRouteController.shared.awaitPendingProbe()` before `getPlaybackInfo` in `VideoPlayerCoordinator.play` and in `VideoPlayerView.negotiate`, inside the existing uncancellable Task.
  - Add one RULE line to `Shared/Screens/VideoPlayer/CLAUDE.md`, under the retry RULE: a retry after a route change re-negotiates through the rebuild budget.
- [ ] **Step 4: `RUN_TESTS`.** Expected: pass.
- [ ] **Step 5: Commit** `feat: playback waits for the route probe and re-negotiates after a route change`.

### Task 11: « Mes serveurs », Réglages, strings

**Files:**
- Modify: `Shared/Screens/ServersScreen.swift`:
  - `ServersViewModel` `:32-109`
  - alerts `:251-266`
  - `rowContent` `:369-403`
  - `renameAction` `:614`
  - `iOSRow` `:622-676`
  - `tvRow` `:753-811`
- Modify: `Shared/Screens/Settings/SettingsScreen+iOS.swift:805-822` (`IOSActiveServerLabel`), `Shared/Screens/Settings/SettingsScreen+tvOS.swift:653-662`
- Modify: `Resources/{fr,en,de}.lproj/Localizable.strings` (next to `servers.rename*`), `Resources/{fr,en,de}.lproj/InfoPlist.strings`, `project.yml:176` and `:302` (`NSLocalNetworkUsageDescription`)
- Test: `LocalServerAddressTests.swift`

**Interfaces:**
- Consumes:
  - `AppState.setLocalAddress(id:raw:) -> LocalAddressSaveOutcome` (Task 9)
  - `ServerRouteController.shared.route` / `.dialURL` (Task 8)
  - `LocalRouteProbe`, `ServerRoutePolicy` (Task 3)
- Produces:
  - `ServersViewModel.route(for id: String) -> ServerRouteKind?`. The ping tries `entry.localURL` first (`LocalRouteProbe.probe(_, runtimeTimeout)` + `decide`, expected `entry.serverID`) → `.online` and `.local`; else `ServerReachability.ping(url:)` → `.internet`. A card is online when either answers.
  - `static func message(for outcome: LocalAddressSaveOutcome) -> (key: String, style: ToastStyle)`, pure, in `ServersScreen.swift` (an `internal` helper type `LocalAddressToast`), so the mapping is tested.
- Strings (fr; en and de equivalents with the same keys and specifiers):

  | Key | fr |
  |---|---|
  | `servers.localAddress` | `Adresse locale…` |
  | `servers.localAddress.title` | `Adresse locale` |
  | `servers.localAddress.message` | `L'adresse de ce serveur sur le réseau de la maison. JellyGlass l'utilise en priorité quand cet appareil est sur ce réseau. Laissez vide pour la retirer.` |
  | `servers.localAddress.placeholder` | `192.168.1.128:8899` |
  | `servers.localAddress.reachable` | `Adresse locale joignable` |
  | `servers.localAddress.savedUnreachable` | `Enregistrée — utilisée quand cet appareil est sur le même réseau` |
  | `servers.localAddress.denied` | `Accès au réseau local refusé — autorisez-le dans Réglages › JellyGlass` |
  | `servers.localAddress.otherServer` | `Ce n'est pas ce serveur` |
  | `servers.localAddress.notLocal` | `Saisissez une adresse du réseau de la maison (ex. 192.168.1.128)` |
  | `servers.localAddress.signInFirst` | `Connectez-vous d'abord à ce serveur` |
  | `servers.localAddress.removed` | `Adresse locale retirée` |
  | `servers.route.local` | `Local` |
  | `servers.route.internet` | `Internet` |
  | `settings.server.route.local` | `Local · %@` |

  - en: `Local address…`, `Local address`, `This server's address on your home network. JellyGlass uses it first when this device is on that network. Leave empty to remove it.`, `Local address reachable`, `Saved — used when this device is on the same network`, `Local network access denied — allow it in Settings › JellyGlass`, `That's not this server`, `Enter an address on your home network (e.g. 192.168.1.128)`, `Sign in to this server first`, `Local address removed`, `Local`, `Internet`, `Local · %@`.
  - de: `Lokale Adresse…`, `Lokale Adresse`, `Die Adresse dieses Servers in deinem Heimnetz. JellyGlass nutzt sie zuerst, wenn dieses Gerät in diesem Netz ist. Leer lassen, um sie zu entfernen.`, `Lokale Adresse erreichbar`, `Gespeichert — wird genutzt, wenn dieses Gerät im selben Netz ist`, `Zugriff aufs lokale Netzwerk verweigert — erlaube ihn in Einstellungen › JellyGlass`, `Das ist nicht dieser Server`, `Gib eine Adresse aus deinem Heimnetz ein (z. B. 192.168.1.128)`, `Melde dich zuerst bei diesem Server an`, `Lokale Adresse entfernt`, `Lokal`, `Internet`, `Lokal · %@`.
  - `NSLocalNetworkUsageDescription`, widened, in `project.yml` base (English) and the three `InfoPlist.strings`:
    - fr: `JellyGlass utilise votre réseau local pour trouver les serveurs Jellyfin de votre Wi-Fi et s'y connecter directement à la maison.`
    - en: `JellyGlass uses your local network to find Jellyfin servers on your Wi-Fi and connect to them directly at home.`
    - de: `JellyGlass nutzt dein lokales Netzwerk, um Jellyfin-Server in deinem WLAN zu finden und dich zu Hause direkt mit ihnen zu verbinden.`

**UI decisions** (mockup variant A, the owner's choice):
- **Action.** `localAddressAction(_:)` (SF Symbol `house`) sits right after `renameAction` in the iOS context menu and the leading swipe, and after « Renommer » in the tvOS context menu.
- **Alert.** A second `.alert` modelled on the rename one, with `@State pendingLocalAddressId: String?` and `@State localAddressText`.
  - Pre-filled with the stored local URL's `absoluteString`, or empty.
  - The `TextField` placeholder is `servers.localAddress.placeholder`, with `.textInputAutocapitalization(.never)`, `.autocorrectionDisabled()`, and `.keyboardType(.URL)` on iOS.
  - « Sauvegarder » starts `Task { toast(await appState.setLocalAddress(id:raw:)) }`. The pending action holds an id and re-resolves from `appState.servers` (ServersScreen RULE b).
- **Pill.** `routePill(_:)` sits right of the name, after `currentPill`:
  - SF Symbol `house.fill` + `servers.route.local`, or `globe` + `servers.route.internet`.
  - `CinemaFont.label(.small)`, `CinemaColor.onSurfaceVariant` on a `CinemaColor.surfaceContainerHigh` capsule, the same padding as `currentPill`.
  - The active entry reads `ServerRouteController.shared.route`; the other entries read `viewModel.route(for:)`, shown only when online.
  - The address line keeps the public URL.
- **Réglages → Serveur.** A third line under the address in `IOSActiveServerLabel` and in the tvOS `tvServerDetail`:
  - local: `settings.server.route.local` with the dial URL's `host[:port]`
  - internet: `servers.route.internet`
  - same font as the address line, `CinemaColor.onSurfaceMuted`, SF Symbol prefix as the pill
- **tvOS.** The mockup's tvOS rendering was broken (owner's note): check the card with the pill at 1× and the system text entry in the simulator. Fix spacing so the pill never truncates the name (memory `feedback_short_label_over_truncation`: `ViewThatFits`, icon only as the short form).

- [ ] **Step 1: Write the failing test** — `@Suite("Adresse locale — messages")` `toastMapping`:
  - `.reachable → ("servers.localAddress.reachable", .success)`
  - `.savedUnreachable → (…savedUnreachable, .info)`
  - `.savedLocalNetworkDenied → (…denied, .error)`
  - `.refusedOtherServer → (…otherServer, .error)`
  - `.refusedNotLocal → (…notLocal, .error)`
  - `.needsSignIn → (…signInFirst, .error)`
  - `.removed → (…removed, .info)`
  
  Also `everyKeyExistsInAllLanguages`: each key above resolves in fr, en and de — follow the pattern `PluralRuleTests` / `OnboardingPolicyTests` use to load a table.
- [ ] **Step 2: `RUN_TESTS`.** Expected: compile failure.
- [ ] **Step 3: Implement** the UI, strings and plist text. Run `python3 scripts/check-localization-parity.py`. Expected: no error.
- [ ] **Step 4: `RUN_TESTS`.** Expected: pass.
- [ ] **Step 5: Simulator check, iOS and tvOS.**
  1. Open « Mes serveurs »: the pill shows and the action is in the menu.
  2. Type `192.168.1.128:8899` on the bench: the toast matches.
  3. Réglages → Serveur shows the third line.
  4. Check tvOS focus in the text entry.
  
  Screenshot the card on both platforms and send them with `SendUserFile`.
- [ ] **Step 6: Commit** `feat: « Adresse locale… » in Mes serveurs, Local / Internet pill, Réglages line`.

### Task 12: Widget, Top Shelf, App Intents

**Files:**
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Persistence/ExtensionSessionBridge.swift`:
  - `Session` `:32-72`
  - `publish` `:82-160`
  - `retryFailedClear` `:225`
- Modify: `Shared/Navigation/AppState.swift:238`, `:804` and `:863` (the publish calls)
- Create: `Widgets/CinemaxWidget/ExtensionServerRoute.swift` (shared by source)
- Modify:
  - `Widgets/CinemaxWidget/JellyfinLite.swift` (`Session` `:11-22`; a new `dialing(_:)`)
  - `Widgets/CinemaxWidget/CinemaxWidget.swift:168` (`loadEntry`)
  - `TopShelf/CinemaxTopShelf/ContentProvider.swift` (`Session` `:28-39`, `run` `:78`)
- Modify: `project.yml`. Share `ExtensionServerRoute.swift` and `Packages/CinemaxKit/Sources/CinemaxKit/Models/LocalNetworkAddress.swift` by source:
  - Widget sources `:344-348`: add `LocalNetworkAddress.swift`.
  - Top Shelf sources `:385-390`: add both files.
  - Cinemax `:68-71` and CinemaxTV `:234-236`: add `ExtensionServerRoute.swift`, so the app test bundles can test it.
- Modify: `Shared/Intents/IntentSessionProvider.swift:91-106` (`makeSession`) and its callers
- Test: `Tests/CinemaxKitTests/ExtensionSessionContractTests.swift`, `LocalServerAddressTests.swift`

**Interfaces:**
- Produces:
  - `ExtensionSessionBridge.Session.localServerURL: URL?` and `.serverID: String?`, both optional, in all THREE copies (bridge, `JellyfinLite.Session`, `ContentProvider.Session`).
  - `publish(serverURL:accessToken:userId:maxContentAge:pinnedCertificateSHA256:localServerURL:serverID:)` — the two new parameters have **no default**, like the cap. The app passes `activeEntryIfAny?.localURL` / `activeEntryIfAny?.serverID`; logout and `retryFailedClear` pass `nil`.
  - In `ExtensionServerRoute.swift`:
    ```swift
    enum ExtensionServerRoute {
        static let probeTimeout: TimeInterval = 1.0
        static func dialURL(publicURL: URL, localURL: URL?, serverID: String?, trust: URLSessionTaskDelegate) async -> URL
        static func accepts(statusCode: Int, body: Data, serverID: String, connectedAddress: String?) -> Bool   // pure
    }
    ```
    - The same rules as `LocalRouteProbe`: no token, no redirect, `Id == serverID`, connected address `LocalNetworkAddress.isLocal`.
    - Its own ephemeral session with `allowsCellularAccess = false`, which makes « no probe on 4G » structural.
    - `nil` `localURL` or `serverID` → `publicURL` at once.
    - Its own `endpointPath` copy for the base path.
  - `JellyfinLite.dialing(_ session: Session) async -> Session` and the Top Shelf equivalent: a copy whose `serverURL` is the dial URL. Every fetch already derives from `session.serverURL`.
  - `IntentSessionProvider.makeSession(...) async -> IntentSession?`: after `reconnect`, `api.setDialURL(…)` with `LocalRouteProbe.probe(entry.localURL, timeout: LocalRouteProbe.launchTimeout)` + `ServerRoutePolicy.decide` (reach `.lanCapable`; the probe session's no-cellular flag covers 4G). Update every caller (`grep -rn "makeSession(" Shared/Intents`); intent `perform()`s are already async.

- [ ] **Step 1: Write the failing tests.**
  - `ExtensionSessionContractTests`:
    - `blobCarriesLocalAddress`: encode a `Session` with both new fields → decode with the JSON shape the extensions use, and they are kept.
    - `oldBlobDecodes`: a blob without the keys decodes with both `nil`.
  - `@Suite("Adresse locale — extensions")`:
    - `extensionAcceptsMatchingLocal`: `accepts(200, #"{"Id":"S"}"#, "S", "192.168.1.128")` is true.
    - `extensionRejectsMismatch`: `"OTHER"` → false.
    - `extensionRejectsPublicAddress`: `"86.245.10.3"` → false.
    - `extensionNoLocalAddressIsPublic`: `await dialURL(publicURL: pub, localURL: nil, serverID: "S", …) == pub`.
- [ ] **Step 2: `xcodegen generate`, then `RUN_TESTS`.** Expected: compile failure.
- [ ] **Step 3: Implement.** In the widget, `loadEntry` resolves once per timeline: `let session = await JellyfinLite.dialing(stored)`. The Top Shelf `run` does the same. `ExtensionServerTrust`'s pin stays keyed on the public URL (an https LAN address with a self-signed certificate fails → public, as in the app).
- [ ] **Step 4: `RUN_TESTS`.** Then build both extensions' schemes (the widget comes with `Cinemax`, the Top Shelf with `CinemaxTV`) in Debug. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit** `feat: widget, Top Shelf and App Intents try the local address first`.

### Task 13: Rules, full verification, device checks

**Files:**
- Modify: `docs/rules/server-setup-and-multi-server.md`, add a « Local address » subsection under Multi-server:
  - identity vs dial;
  - `localURL` user-owned and kept by `upsert`;
  - `setLocalAddress` is the only writer;
  - switches and re-login on the target's route;
  - the missing-`serverID` adoption decision;
  - no address in logs.
- Modify: `Packages/CinemaxKit/CLAUDE.md` (if Tasks 4–5 have not already): `dialURL` in `ClientState`; `LocalRouteProbe` in « Network awareness »; the wrapped Nuke loader.
- Modify: `Widgets/CLAUDE.md`: the blob carries `localServerURL` / `serverID` (optional, no default on publish); `ExtensionServerRoute` shared by source; « the extensions keep the public URL as identity ».
- Modify: `Shared/Screens/VideoPlayer/CLAUDE.md` (if Task 10 has not): the route-change retry.

- [ ] **Step 1: Write the rule changes above.**
- [ ] **Step 2: Full tests, iOS** — `RUN_TESTS`. Expected: pass, with every `Adresse locale —` suite present.
- [ ] **Step 3: Full tests, tvOS** — `set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -skipPackagePluginValidation 2>&1 | tee /tmp/cinemax-tv.log | tail -3; grep -E '✘|Test run with' /tmp/cinemax-tv.log | tail`. Expected: pass. Wrap any iOS-only test (`LocalNetworkPermission`, the native retry) in `#if os(iOS)`.
- [ ] **Step 4: SwiftLint (pinned version, strict, with baseline)**, run as CI does from `ci.yml`. Expected: 0 new violations.
- [ ] **Step 5: Release builds, one after the other** (never in parallel):
  - `set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -configuration Release -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation 2>&1 | tail -3`
  - the same with `-scheme CinemaxTV -destination 'generic/platform=tvOS Simulator'`
  
  Expected: `** BUILD SUCCEEDED **` twice.
- [ ] **Step 6: Device checks** (owner's iPhone + Apple TV, at home on `http://192.168.1.128:8899`). List each as passed or failed in the report:
  1. API calls and a stream work over plain http to the LAN IP (ATS).
  2. The « Réseau local » prompt appears on the first save, and denying it gives the `denied` toast.
  3. After a home playback, `docker logs cloudflared` shows no `/Videos/` request, and Jellyfin logs the client as `192.168.1.x`.
  4. With the router's WAN unplugged: launch, browse, play, switch, widget and Top Shelf still work.
  5. On 4G: behaviour as before, and launch is not slower.
  6. On iPhone, leaving the Wi-Fi mid-playback: VLC and the native engine (opt-in) recover on the public URL.
  7. The widget reaches the LAN: it inherits the app's local-network grant (no usage description on the extension).
  8. An https LAN address with a self-signed certificate falls back silently.
  9. The tvOS card and text entry are legible (the owner's note).
- [ ] **Step 7: Commit** `docs: local server address rules`. Report to the owner: what passed, what is blocked. **Do not push or open a PR without the owner's go.**
