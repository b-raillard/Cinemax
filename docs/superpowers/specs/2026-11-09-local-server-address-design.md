# Local server address — use the LAN at home, the public URL elsewhere (2026-11-09)

Decided with the product owner on 2026-11-09, after two playback cuts the same day (memory `project_wife_iphone_cut_20261109`). Branch `claude/local-server-address`, rebased on `main` at `d7901afb`. File references below were taken at `07630196`, before Seerr (#330→#333) landed; Seerr reworked `AppNavigation.swift` (~500 lines) and touched `AppState.swift`, so re-locate line numbers there.

## Why

Both cuts of 2026-11-09 happened **at home**, and both had the same cause: Cloudflare (the tunnel in front of `https://movies.nivadax.net`) cancelled a long HTTP/2 download on the visitor side, while the tunnel kept the origin request open ~30 s longer.
- The iPhone of the owner's wife gave up after several retries, and she quit the app.
- The Apple TV recovered in a few seconds through the feed-stall guard.

At home the server is one hop away (`http://192.168.1.128:8899`), so going through Cloudflare there is pure loss: cuts, extra latency, and tunnel traffic. The owner also wants the home traffic off the tunnel.

Family members watch from outside, so the public URL stays. Tailscale was rejected: too many people would need it. Opening the server directly on the internet is not wanted.

## Decisions (product owner)

| Question | Answer |
|---|---|
| How the app learns the local address | **Typed by hand, once per device**, next to the public URL. No auto-discovery: the NAS's Jellyfin runs in Docker and reports `LocalAddress = http://172.17.0.3:8096`, unreachable from the LAN (checked 2026-11-09 on `/System/Info/Public`). The app's UDP discovery would see the same address. |
| « Local » vs « Internet » indication | **Derived from the IP address itself** (private ranges are standardised), never a stored flag or a user setting. |
| Addresses per server | **Two at most**: the public URL and one optional local address. |
| Written spec first | Yes (this file). Validated by the owner on 2026-11-09, the seven builder calls included. |
| How far the local route goes | **« Si tu détectes que je suis en local, on passe en local en priorité »**: everywhere the app talks to this server, the local address is tried first when the device may be at home, and the public URL is the fallback. The local address is a failover too: with the home internet or the tunnel down, the app keeps working at home (see *Where the route applies*). |

## What the user sees

- **Where to type it.** In « Mes serveurs » (`ServersScreen`), the server's existing actions gain « Adresse locale… » next to « Renommer ».
  - iOS: in the context menu / leading swipe, an alert with one URL field, like the rename alert.
  - tvOS: in the card's context menu.
  - Clearing the field removes the local address.
- **When saving**, the app probes the address at once (see *Choosing the route*):
  - Same server answers → saved, toast « Adresse locale joignable ».
  - Nothing answers (typed away from home) → saved anyway, toast « Enregistrée — utilisée quand cet appareil est sur le même réseau ».
  - **A different server answers** (Jellyfin `Id` differs) → **refused**, « Ce n'est pas ce serveur ».
  - Not a local address (see *Eligible addresses*) → refused, with a message saying it must be an address of the home network.
- **The indication.**
  - The active server's card, and the server page in Settings, print « Local » or « Internet » for the address **currently in use**.
  - It is derived from that address's host: a server whose only URL is already `http://192.168.x.y` shows « Local » with no local address configured.
  - Purely informative: no badge on Home, nothing in the player.
  - **Form (owner's choice, mockup variant A, https://claude.ai/artifact/TygAqSnDNfoZaBk6tMpf7j)**: on the card, a small pill right of the name (after « Actuel » on the active card), with a house icon + « Local » or a globe icon + « Internet ». The address line keeps the public URL. Settings → Serveur adds one line under the address: « Local · <local address> » or « Internet ». The mockup's tvOS rendering is broken: design the tvOS card and text entry properly during implementation (owner's note).
- **Nothing else changes.** Same server entry, same accounts, same Continue Watching. Images already on disk are not downloaded again.

## Choosing the route

A **route** is the base URL the app dials: the public URL (the entry's `url`, unchanged) or the local address.

**Decision** (a pure policy, unit-tested):

1. No local address on the active entry → public.
2. The network path has no Wi-Fi or wired interface (cellular only, or offline) → public, with no probe.
3. Otherwise probe the local address. Use it only if **all** of these hold:
   - `GET <local>/System/Info/Public` answers 200 within **~1.5 s**;
   - **no auth header** is sent, and redirects are not followed;
   - the body's `Id` equals the entry's Jellyfin `serverID`;
   - the address actually connected to is in a private range (*Eligible addresses*).

   Otherwise public.

**When it is re-evaluated:**
- after the session is restored at launch;
- on return to the foreground;
- on every network path change.

On a path change the app **falls back to public immediately**, then probes, then switches back to local if the probe passes. That way, moving to another Wi-Fi (a friend's house, a hotel) never leaves the app dialling a dead LAN address during the probe timeout.

**At launch**, local comes first.
- On Wi-Fi or wired with a local address, the route is decided **before** the session is restored over the network: probe the local address first, then restore on whichever route won.
- At home the probe answers in a few ms. On a foreign Wi-Fi it costs at most the launch timeout, **~1 s**, shorter than the runtime one, while the cached Home snapshot is already on screen.
- On cellular the probe is skipped.

**Opening a playback waits for a probe already in flight** (after a path change, for instance), bounded by its timeout, so that a playback never starts on a route about to be abandoned.

**Mid-playback:**
- A route change never restarts a playing stream by itself.
- Leaving home kills the local stream. The existing recovery (feed-stall guard → re-resolve) must then reopen it **on the current route**.
- Today the error retry reuses the stored `PlaybackInfo` URL (`VLCStreamPresenter` ~`:5610`, `streamOpenURL(for: self.info…)`), so it would keep the dead host. A retry after a route change must re-resolve instead.
- Arriving home mid-playback does not switch the running stream. The next open is local.
- **The native engine (AVPlayer, opt-in) follows the same rule** (my call). Its opens already go through `getPlaybackInfo`, so they get the dial URL. But its failure path, `retryWithDirectURL` (`NativeVideoPresenter.swift:414`), reopens the same `info.url` and then shows the error alert. After a route change it must re-resolve on the current route before reopening, so that leaving home mid-playback is no worse than today on the public URL. This matters on iPhone and iPad only: an Apple TV never leaves home.

## Where the route applies (local first)

Every path that talks to the active server, or to a registered one, tries the local address first under the decision above, and falls back to the public URL:

- **Session restore at launch**, and every API call, image, stream and socket of the session (*Architecture*).
- **Re-login of a known entry**: password and Quick Connect, from `LoginScreen` after `beginReLogin`. Adding a **new** server has no local address yet, so it uses the typed URL as today.
- **Server and account switches**: the token check of `AppState.switchTo` (`sessionValidator(entry.url, token)`) validates against the target's route, decided for the target's own entry. The two-phase RULE is unchanged: the token is still checked off the shared client, and `.indeterminate` still never destroys it.
- **« Mes serveurs » status** (`ServerReachability.ping`): local first, then public. A card counts as reachable when either answers. Each card can then print « Local » or « Internet » for the address that answered.
- **Widget and Top Shelf**: local first, with the same `Id` check before any token is sent, then public.
  - Their own code (no CinemaxKit — `Widgets/CLAUDE.md`), sharing the probe by **source** like `ExtensionServerTrust.swift`.
  - `ExtensionSessionBridge` publishes the local address and `serverID` beside the public URL.
  - Probe timeout ~1 s, so a timeline refresh away from home stays quick.
- **App Intents** (`IntentSessionProvider`, in-app, headless): the same CinemaxKit route helper.

So with the home internet or the tunnel down, a device at home still launches, browses, plays, signs in to a known server, switches, and feeds its widget / Top Shelf. Seerr has its own URL and is out of scope.

## Eligible addresses

One classifier, a **single source of truth in CinemaxKit**, says whether an IP is local. Local means:
- IPv4 private ranges: `10/8`, `172.16/12`, `192.168/16`;
- IPv4 link-local: `169.254/16`;
- IPv6 ULA: `fc00::/7`;
- IPv6 link-local: `fe80::/10`.

Not local: loopback, CGNAT `100.64/10` (shared ISP space, not a LAN), and everything else.

It replaces `VerboseDiagnostics.localAddressClass` (`Shared/Diagnostics/VerboseDiagnostics.swift:108`), which keeps its output format. Two of its quirks must not survive: a hostname, or a malformed IPv4 such as `999.1.1.1`, currently classifies as `public-ipv6`.

**What the field accepts:**
- `http` or `https`;
- a host that is either a private IP literal or a `.local` (mDNS) name.

For a `.local` name, the probe classifies the address it actually connected to (`URLSessionTaskMetrics`). A qualified non-`.local` name such as `nas.lan` is refused: plain-http to it is blocked by ATS for API calls, and it cannot be classified before resolution.

The field goes through `ServerURLNormalizer`, sub-path preserved. That normaliser defaults a bare host to `https://`, but a LAN Jellyfin is almost always `http`: **default a bare local host to `http://`**.

## Architecture — identity URL vs dial URL (my call)

A second URL for one server collides with many places that treat the URL as the server's identity. Swapping `AppState.serverURL` would trigger every one of these:
- a duplicate registry entry, because `upsertActiveEntry` / `ServerRegistry.upsert` match by normalised URL (`AppState.swift:743`, `ServerRegistry.swift:118`);
- a lost `ServerVersion`, because `reconnect` drops it when the URL differs (`JellyfinAPIClient.swift:504`);
- a LAN URL published to the widget and Top Shelf, which do no probing and would break away from home;
- a LAN URL in the legacy Keychain mirror read at restore (`AppState.swift:513`, `:174-190`);
- certificate pins keyed by `host:port`;
- `LoginScreen().id(appState.serverURL)` discarding typed input.

So:

- **Identity stays the public URL, everywhere it is today.** That covers:
  - `AppState.serverURL`, the registry entry's `url` and dedup;
  - the legacy Keychain mirror;
  - the URL `ExtensionSessionBridge` publishes as the server's URL (the local address travels beside it, never instead of it);
  - the registry `url` that `IntentSessionProvider` reads;
  - certificate pins;
  - `reconnect(url:)` callers.

  The dial URL is chosen per path (*Where the route applies*); the identity never changes.

  `serverVersion` therefore survives a route change, and no duplicate entry can appear.
- **Only the transport dials the route.**
  - **API**: `JellyfinAPIClient`'s `ClientState` gains a dial URL beside the identity URL, under the same lock. A route change rebuilds the SDK client **in place** on the dial URL, keeping the token and `serverVersion`. Model: `setPreferredLanguage` (`:153-166`), with the same generation check.
    - Do **not** clear `APICache` on a route change: its keys carry no URL, and the responses are the same server's.
    - Every reader that builds a URL to dial (`getServerURL`/`getConnection` users: playback `+Playback.swift:23` and the raw PlaybackInfo POST `:360-403`, the socket `+RemoteControl.swift:194`, diagnostics `:45`) must get the dial URL.
    - `isSameServer` keeps comparing identity.
  - **Images**: keep building image URLs on the identity URL (`ImageURLBuilder`, and the 12 stored `imageBuilder` copies stay valid). **Rewrite the base at load time** in the Nuke pipeline (`AppNavigation.swift:140-157`), through a data loader that swaps the identity base prefix for the dial base prefix.
    - Cache keys therefore stay identity-based: no re-download, no second disk copy.
    - `AuthenticatedImageFetch` (chapters, trickplay, now-playing artwork) goes through the same pipeline.
    - The swap must respect **both** base paths: identity `/jellyfin` vs local `/`, and the reverse (the `URLComponents+ServerPath` RULE).
    - The builder sweeps for any image GET that does not go through Nuke.
  - **Realtime socket**: after a route change, the single socket (`JellyfinSocketHub`, `JellyfinSocket.swift:405-430`, endpoint fixed per connection `:118-120`) must reconnect on the new route within a few seconds. That covers remote control (« Lire sur… » receive side) and SyncPlay.
    - Today only a subscriber asking with a different URL rebuilds it.
    - `AppNavigation`'s `onChange(of: serverURL)` will not fire, since identity does not change.
  - **Playback transport**: `StreamTransportPolicy.configure` is fed the dial URL on every route change (`CinemaxStreamProxy.swift:49-62`), which also resets the sticky-proxy flag. An IPv4 literal never prefers the proxy, so a LAN stream goes direct.
- **Switches reset the route.** A server or account switch, and every `reconnect(url:)`, sets the dial URL back to the identity URL, then re-evaluates for the new active entry. Otherwise the previous server's LAN address could receive the new server's token.
- **The registry keeps the field.** `ServerRegistry.upsert` rebuilds every field by hand, so the new optional field (the local address) must be carried over from the stored entry, like `displayNameOverride` / `sortIndex`. No login, switch or reachability write may drop it.
- **Missing `serverID`** (product owner, 2026-11-09). The probe compares against `entry.serverID`, which is optional, and the « Mes serveurs » ping does not record it (`ServersScreen.swift:99`). If it is missing when the user saves a local address:
  1. learn it first from `/System/Info/Public` on the public URL;
  2. if the public URL does not answer (home internet or tunnel down) but the local address does, **adopt the local `Id` as the entry's `serverID`** and save. This is the owner's decision: nothing then proves that the local machine is the same server, which is accepted for a one-time, hand-typed setup;
  3. if neither answers, refuse with « Connectez-vous d'abord à ce serveur ».

  Once learned, the `serverID` is written to the entry through `ServerRegistry.upsert` and every later probe compares against it.
- **Route owner.** One `@MainActor` owner of the current route: the probe, the decision, and pushing the dial URL into the client / image loader / socket / transport policy.
  - It must get network path changes **without a new modifier on `AppNavigation.body`**, which sits at the type-checker limit (memory `project_appnavigation_body_typecheck_limit`).
  - `NetworkMonitor` only exposes `isOnline` (`NetworkMonitor.swift:14`), so a Wi-Fi⇄cellular change with both up is invisible to it today. Extend it, e.g. with the interface kinds, or a callback the owner subscribes to.
  - Of the two `onChange(of: network.isOnline)` handlers, only the early-adopter one (`AppNavigation.swift:775`) is under `#if !DEBUG`. The one at `:762` (`StreamTransportPolicy.refresh()`) always runs, but it does not see a Wi-Fi⇄cellular change either.

## Security

- The probe sends **no token**. The token goes to the local address only after the Jellyfin `Id` matched and the connected address is private.
- At home the token and the traffic then travel in **plain HTTP on the LAN**, as any http LAN Jellyfin setup does. This is accepted.
- **Residual risk, accepted**: the server `Id` is public. To be impersonated, a machine would need that `Id`, the **same address and port** on the network the device is on, and to answer as Jellyfin.
- An `https` local address must pass the normal trust path. No pin-approval UI is offered for the local address. A self-signed LAN certificate makes the probe fail → public.

## Diagnostics

- The report header always carries `server_route: local|internet`. It is a class, never an address, so it is not verbose-only.
- Each route change logs one `[Servers]` notice: the new class and the reason (launch / foreground / path change / probe failed / id mismatch). Same privacy rule: no address in the log.
- The verbose lines from PR #337 are unchanged.

## Platforms and permissions

- **iOS / iPadOS**: the first probe triggers the system « Réseau local » permission prompt. `NSLocalNetworkUsageDescription` already exists, but check that its text covers this use. The save action is the first probe, so the prompt appears right after the user typed the address, in context.
  - If permission is denied, the probe fails → public. The field's status should say so: the builder decides how to detect that error.
- **tvOS**: same feature, same UI path (card context menu → text entry).
- **ATS**: `NSAllowsLocalNetworking` + `NSAllowsArbitraryLoadsForMedia` are set on all four targets (`project.yml:147/294/368/411`). Plain http to a private IP literal is expected to work under them, since http LAN servers are already supported as the main URL. **Confirm early on a device** for both API calls and streaming.
- **Free, not Pro** (my call): it is playback reliability, and playback is never gated (`Shared/Entitlements/CLAUDE.md`).

## Goals

- At home, every request — API, images, streams, socket — goes to the LAN address. After a home playback, `docker logs cloudflared` shows no `/Videos/` request for it, and Jellyfin logs the client as `192.168.1.x`.
- Away from home, nothing changes from today.
- With the home internet or the Cloudflare tunnel down, a device at home keeps working: launch, browsing, playback, re-login, switches, widget, Top Shelf.
- Moving between Wi-Fi and cellular is seamless outside playback, and a playback in progress recovers through the existing guard.

## Non-goals

- Auto-discovery of the local address (Docker reports an unusable one).
- More than one local address, or a free-form list of addresses.
- Syncing the local address across devices or Apple IDs: typed per device.
- The local route for Seerr (its own URL).
- Switching a running stream to the LAN when arriving home.
- Pin approval for an https LAN certificate.

## Anti-goals (failure even if it "works")

- The token reaching a machine that has not proven the server `Id`.
- A duplicate server card, a lost `ServerVersion`, or a widget broken away from home.
- A launch or a screen visibly slower away from home, because a dead LAN address is being waited on.
- Every image downloading again, or a second image cache on disk.

## Tests (swift-testing; new files need `xcodegen generate`)

- **Classifier**: every range boundary, IPv6 forms, malformed literals, hostnames.
- **Route decision table**: no local address, cellular only, probe OK, probe timeout, `Id` mismatch, non-private connected address.
- **`ServerEntry`**: a registry written before the field decodes unchanged. The new field is **optional** (the decode RULE in `ServerEntry.swift`).
- **Normalisation of the local field**: bare host → `http://`, sub-path kept, `.local`, refusals.
- **Base-prefix swap** for image URLs, with and without base paths on either side. Cache key unchanged.
- **Retry after a route change** re-resolves instead of reusing the old host.

## Left to the builder

- Type and file names, and where the route owner lives (`AppState`, or a root singleton like `SeerrSession`).
- How `NetworkMonitor` exposes interface changes.
- How the socket learns about a route change.
- Localised strings (FR / EN / DE, parity checked by CI), and the exact toast and refusal wording, consistent with the existing pre-auth tone.
- Detecting the iOS local-network denial.
- The probe timeout, around 1.5 s, tuned on a device.
- The rule files to update: `docs/rules/server-setup-and-multi-server.md`, `Packages/CinemaxKit/CLAUDE.md`, `Shared/Screens/VideoPlayer/CLAUDE.md`, `Widgets/CLAUDE.md` (the « extensions stay on identity » invariant).
