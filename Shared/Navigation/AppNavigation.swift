import SwiftUI
import CinemaxKit
import Nuke
import OSLog
@preconcurrency import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "Servers")

@MainActor @Observable
final class AppState {
    /// Placeholder used before a real server is configured. `URL(string:)` is Optional
    /// so a force unwrap here would crash on a malformed literal — a static URL built
    /// from components is infallible and keeps the rest of the code crash-free.
    static let placeholderServerURL: URL = {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        return components.url ?? URL(fileURLWithPath: "/")
    }()

    var isAuthenticated = false
    var hasServer = false
    // Documented exemption from the "@Observable properties must NOT carry
    // didSet" RULE: that rule targets persistence side effects on collections
    // of Codable value types (lost re-renders). This didSet only re-derives a
    // sibling stored property from a scalar URL — no persistence, no
    // observation-delivery dependency.
    var serverURL: URL? {
        didSet { imageBuilder = ImageURLBuilder(serverURL: serverURL ?? Self.placeholderServerURL) }
    }
    var serverInfo: ServerInfo?
    var currentUserId: String?
    var accessToken: String?

    /// Full `UserDto` for the signed-in user. Hydrated by `refreshCurrentUser()`
    /// after session restore / login / user switch. Screens that need the
    /// policy or primary image tag read from here rather than re-fetching.
    var currentUser: UserDto?

    /// Cached admin flag — single source of truth for gating admin surfaces
    /// (Settings categories, "Edit metadata" button on MediaDetail). Always
    /// kept in sync with `currentUser?.policy?.isAdministrator`. Derived so
    /// that non-admins never *see* admin UI in the first place; the server
    /// still enforces authorization on every endpoint.
    private(set) var isAdministrator: Bool = false

    /// Re-entrancy guard for the confirm-before-logout cycle. MainActor-confined
    /// (no lock needed) — every trigger hops to MainActor before reading it, so
    /// concurrent 401s / a foreground revalidation collapse into one probe.
    private var sessionRevalidationInFlight = false

    /// Reachability probe injected from the view layer (`NetworkMonitor.isOnline`).
    /// Wired once in `AppNavigation.task`. Defaults to `true` so unit tests that
    /// don't set it still exercise the validate path. Never log out while this
    /// reports offline — turning the box off/on must not disconnect the user.
    var isOnlineProvider: @MainActor () -> Bool = { true }

    // MARK: - Multi-server state
    //
    // Plain stored properties with NO `didSet` (see the `@Observable` RULE):
    // every mutation goes through one of the methods in the "Multi-server"
    // section below, which mutate *and* persist.

    /// Every registered server, Keychain-backed. Hydrated by `restoreSession`.
    private(set) var servers: [ServerEntry] = []
    /// Id of the entry currently mirrored into the legacy Keychain items.
    private(set) var activeServerId: String?
    /// Snapshot of the entry to fall back to when an add / re-login flow is
    /// abandoned (the user backs out of `ServerSetupScreen` / `LoginScreen`).
    private(set) var pendingRollbackServer: ServerEntry?
    /// `true` while the pre-auth flow is being reused to ADD a server rather
    /// than to configure the first one — drives the cancel affordance.
    var isAddingServer = false

    /// Bumped synchronously by every server-transition entry point. A transition
    /// that awaits the network re-checks it before writing, so a slow one can
    /// never overwrite the state a newer one already committed — same pattern as
    /// `NowPlayingInfoController.generation`.
    private var serverTransitionGeneration = 0

    let apiClient: any APIClientProtocol
    let keychain: any SecureStorageProtocol

    init(
        apiClient: any APIClientProtocol = JellyfinAPIClient(),
        keychain: any SecureStorageProtocol = KeychainService()
    ) {
        self.apiClient = apiClient
        self.keychain = keychain

        // Wire lazy session-expiry recovery. The callback is `@Sendable` and
        // called from whatever actor the failing API call ran on, so it can
        // NOT capture `self` (a `@MainActor`-isolated reference). Bridge
        // through `NotificationCenter` — `AppNavigation` listens on MainActor
        // and runs `logout()` + the toast.
        apiClient.setOnUnauthorized {
            NotificationCenter.default.post(name: .cinemaxSessionExpired, object: nil)
        }
    }

    // Stored so it is only rebuilt when serverURL changes, not on every access.
    var imageBuilder = ImageURLBuilder(serverURL: AppState.placeholderServerURL)

    /// Hydrates auth state from the keychain. Network probes (server info,
    /// admin flag) are dispatched in the background so the UI doesn't wait
    /// on them — important when the user launches the app offline, where
    /// each probe would otherwise eat a request timeout before the launch
    /// screen disappears.
    func restoreSession() async {
        // Multi-server: seed the registry from the legacy single-server items
        // (idempotent, non-destructive) and hydrate the observable copy. Both
        // run BEFORE the guard below so a signed-out install still exposes its
        // registered servers. Everything after this point is byte-identical to
        // the single-server behavior — it still reads only the legacy trio, so
        // an offline cold launch stays non-blocking and a failed migration
        // cannot log anyone out.
        keychain.migrateToMultiServerIfNeeded()
        loadServersFromKeychain()

        guard let serverURL = keychain.getServerURL(),
              let session = keychain.getUserSession() else {
            return
        }

        self.serverURL = serverURL   // triggers imageBuilder didSet
        self.hasServer = true
        self.accessToken = session.accessToken
        self.currentUserId = session.userID
        self.isAuthenticated = true

        // The items just read back successfully, so it's safe to upgrade them
        // to the cold-boot-readable accessibility class (idempotent, one-shot).
        keychain.migrateAccessibilityIfNeeded()

        // Reconnect client with stored token
        apiClient.reconnect(url: serverURL, accessToken: session.accessToken)
        // Re-apply the user's Privacy & Security content-rating cap, since a
        // `reconnect` rebuilds the Jellyfin client and resets its in-memory state.
        let storedAge = UserDefaults.standard.integer(forKey: SettingsKey.privacyMaxContentAge)
        apiClient.applyContentRatingLimit(maxAge: storedAge)

        // Non-blocking: kick the server-info + admin-policy fetches behind the
        // launch transition. They populate `serverInfo` / `isAdministrator`
        // when (and if) they succeed; failures are non-fatal and leave the
        // user authenticated with last-known values.
        Task { [weak self] in
            guard let self else { return }
            if let info = try? await self.apiClient.fetchServerInfo() {
                self.serverInfo = info
            }
            await self.refreshCurrentUser()
        }
    }

    /// Refreshes `currentUser` + `isAdministrator` from the server. Call on
    /// login success, user switch, and session restore. Failures leave the
    /// cached values untouched (we prefer a stale admin flag over kicking a
    /// real admin out of the admin UI during a blip). `isAdministrator` only
    /// flips to `false` on an explicit successful fetch that says so, or on
    /// logout.
    func refreshCurrentUser() async {
        // Single hook covering all three session-establishing paths (login,
        // user switch, restore): hand the session to the widget / Top Shelf
        // extensions via the App Group.
        ExtensionSessionBridge.publish(serverURL: serverURL, accessToken: accessToken, userId: currentUserId)
        guard let id = currentUserId else {
            currentUser = nil
            isAdministrator = false
            return
        }
        do {
            let user = try await apiClient.getUserByID(id: id)
            currentUser = user
            isAdministrator = user.policy?.isAdministrator ?? false
        } catch {
            // Network blip — keep last-known values.
        }
    }

    /// Users eligible for the quick-switch surfaces (`UserSwitchSheet` grid +
    /// tvOS Settings profile section). Single source of the visibility rule:
    /// `getUsers()` is admin-only (guaranteed 401 for regular accounts — skip
    /// it), accounts flagged "Hide from login screens" are filtered out, and
    /// when the filtered admin list is empty we fall through to
    /// `getPublicUsers()` rather than showing a misleading empty state.
    func fetchSwitchableUsers() async -> [UserDto] {
        if isAdministrator,
           let fetched = try? await apiClient.getUsers() {
            // The signed-in user stays visible even when their own account is
            // flagged hidden (admins commonly hide their account from login
            // screens — their profile tile must not vanish from Settings).
            let visible = fetched.filter { $0.policy?.isHidden != true || $0.id == currentUserId }
            if !visible.isEmpty { return visible }
        }
        return (try? await apiClient.getPublicUsers()) ?? []
    }

    /// Item id to navigate to — from a `cinemax://item/{id}` deep link (widget
    /// tap / Top Shelf selection), or set alongside `pendingIntentPlaybackItemId`
    /// by an intent / inbound remote-control command.
    ///
    /// Two consumers, split by `isPendingIntentPlayback(_:)`: a plain deep link
    /// goes to `HomeScreen`, which pushes the detail and clears it (`MainTabView`
    /// switches to the Home tab first); a playback request goes to
    /// `MainTabView`'s modal fallback instead, which is the only route that
    /// survives Home already having a detail pushed.
    var pendingDeepLinkItemId: String?
    /// Tab id from a `cinemax://home` deep link (widget "See all" tile).
    /// Consumed by `MainTabView`, which switches tabs and clears it.
    var pendingDeepLinkTabId: String?

    /// Item an App Intent asked to **play**, as opposed to merely open.
    ///
    /// Deliberately separate from `pendingDeepLinkItemId`, and written only
    /// in-process by an intent: the public `cinemax://` scheme has no play
    /// verb, so no URL can ever reach this. Adding one would turn an
    /// unauthenticated entry point into "start playing an arbitrary id".
    ///
    /// The intent sets BOTH this and `pendingDeepLinkItemId` — the latter
    /// navigates, this one tells the detail screen to start playback on
    /// arrival. Routing through the detail screen is what gives a
    /// Siri-initiated playback the same fidelity as a tap: series → next-up
    /// resolution, resume position, and the prev/next episode buttons.
    /// `MediaDetailScreen` consumes it once, and only on the matching item.
    var pendingIntentPlaybackItemId: String?

    /// True when `itemId` is the item a pending **playback** request names.
    ///
    /// The routing SSOT for that request: `MainTabView` sends these to its
    /// modal fallback and `HomeScreen.consumeDeepLink` skips them, so exactly
    /// one of the two acts on a given id whichever order SwiftUI delivers the
    /// two `onChange` handlers in. Both sides must keep asking THIS — an
    /// inlined `pendingIntentPlaybackItemId == id` in one of them is how the
    /// two drift apart into either a double navigation or a dropped command.
    func isPendingIntentPlayback(_ itemId: String) -> Bool {
        pendingIntentPlaybackItemId == itemId
    }

    /// Search term raised by an App Intent. `SearchScreen` consumes it once and
    /// runs the search; `pendingDeepLinkTabId` gets the user to that tab.
    var pendingIntentSearchQuery: String?

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "cinemax" else { return }
        switch url.host() {
        case "item":
            let id = url.lastPathComponent
            // Defense-in-depth: only dispatch a well-formed Jellyfin item id
            // (32-char undashed hex OR a canonical dashed GUID) so a malformed
            // deep link can't drive a lookup with attacker-controlled path text.
            guard Self.isValidItemId(id) else { return }
            pendingDeepLinkItemId = id
        case "home":
            pendingDeepLinkTabId = "home"
        default:
            break
        }
    }

    /// Accepts the two Jellyfin item-id forms only: a 32-character undashed hex
    /// string (`a1b2…`) or a canonical dashed GUID (`UUID(uuidString:)`).
    /// Everything else is rejected.
    ///
    /// `nonisolated` (pure `String` in, `Bool` out — the documented escape hatch
    /// for Sendable-in/Sendable-out statics on a `@MainActor` type) so this stays
    /// the ONE definition of a well-formed item id. `MediaEntityID` validates
    /// persisted shortcut identities against it from a non-isolated context;
    /// a second copy would be free to drift from the deep-link check.
    nonisolated static func isValidItemId(_ id: String) -> Bool {
        if id.count == 32, id.allSatisfy(\.isHexDigit) { return true }
        return UUID(uuidString: id) != nil
    }

    /// Returns the user from `LoginScreen` to `ServerSetupScreen` so they can pick a different
    /// server. Only clears server-side state — auth state is already empty at that point in
    /// the flow, so there's nothing user-related to wipe.
    func disconnectServer() {
        // Multi-server: this is now reachable concurrently with a switch / an
        // add (the `LoginScreen` escape hatch sits next to them), so it counts
        // as a server transition — an in-flight `beginReLogin` handshake must
        // not resurrect `hasServer` after the user backed out. Every method
        // that mutates `hasServer` / `serverURL` bumps this.
        serverTransitionGeneration &+= 1
        keychain.deleteServerURL()
        hasServer = false
        serverURL = nil
        serverInfo = nil
    }

    // MARK: - Multi-server

    /// Why the session is being torn down — the two reasons behave differently
    /// on purpose. See `logout(reason:)`.
    enum LogoutReason: Sendable {
        /// The user tapped "Log out": revoke server-side, then hop to another
        /// registered server if one still holds a token.
        case userInitiated
        /// `handlePossibleSessionExpiry` confirmed the token is revoked: no
        /// revoke call (it would just 401) and **no auto-hop** — the user stays
        /// on this server's `LoginScreen` behind the "session expired" toast.
        case sessionExpired
    }

    /// What `logout(reason:)` ended up doing, so the calling screen can toast
    /// without re-deriving the decision.
    enum LogoutOutcome: Sendable, Equatable {
        /// Signed out and switched to another registered server.
        case switchedTo(ServerEntry)
        /// Signed out; the app is now on `LoginScreen` (same server) or
        /// `ServerSetupScreen` (nothing left to hop to).
        case signedOut
    }

    /// The entry whose session is mirrored into the legacy Keychain items.
    var currentActiveEntry: ServerEntry? {
        ServerRegistry.activeEntry(in: servers, activeId: activeServerId)
    }

    /// Hydrates the observable registry from the Keychain. Called once from
    /// `restoreSession`; every later change goes through a mutator here.
    func loadServersFromKeychain() {
        servers = keychain.getServers()
        activeServerId = keychain.getActiveServerId()
    }

    private func persistRegistry() {
        do {
            try keychain.saveServers(servers)
        } catch {
            // In-memory state stays correct for this session; the next mutation
            // retries. Logged because a silent failure here means the server
            // list quietly reverts on relaunch.
            logger.error("Persisting the server registry failed: \(error.localizedDescription, privacy: .public)")
        }
        keychain.saveActiveServerId(activeServerId)
    }

    /// **The single writer of the legacy Keychain mirror** (`server_url` /
    /// `access_token` / `user_session`) — see the RULE on `KeychainService`.
    /// Makes `entry` the active server end to end: mirror, registry, API
    /// client, observable state, extensions, catalogue refresh.
    func applyActiveServer(_ entry: ServerEntry) async {
        // A usable session needs BOTH a token and a user id. A token-without-user
        // entry is reachable (a migrated install whose `access_token` survived but
        // whose `user_session` didn't) and applying it would persist a
        // `UserSession(userID: "")` mirror and flip `isAuthenticated` with a nil
        // `currentUserId` — a signed-in shell that can't load anything. Both
        // incomplete shapes fall through to a real login instead.
        guard let token = entry.accessToken, !token.isEmpty,
              let userId = entry.userId, !userId.isEmpty else {
            await beginReLogin(for: entry)
            return
        }
        serverTransitionGeneration &+= 1

        // 1. Legacy mirror. Every existing read path (`restoreSession`,
        //    `SettingsScreen`, `ExtensionSessionBridge`) keeps working unchanged.
        do {
            try keychain.saveServerURL(entry.url)
            try keychain.saveAccessToken(token)
            try keychain.saveUserSession(UserSession(
                userID: userId,
                username: entry.username ?? "",
                accessToken: token,
                serverID: entry.serverID ?? ""
            ))
        } catch {
            // The in-memory session below still works for this launch; the next
            // relaunch would fall back to the previously mirrored server.
            logger.error("Writing the active-session mirror failed: \(error.localizedDescription, privacy: .public)")
        }

        // 2. Registry: bump `lastUsedAt`, mark active, persist.
        var used = entry
        used.lastUsedAt = Date()
        servers = ServerRegistry.upsert(used, into: servers)
        activeServerId = used.id
        persistRegistry()

        // 3. API client. `reconnect` rebuilds the Jellyfin client and resets its
        //    in-memory state, so the Privacy & Security rating cap MUST be
        //    re-applied after it — same sequence as `restoreSession`, and easy
        //    to forget. (`reconnect` already clears the cache; the explicit call
        //    keeps the intent visible at this call site.)
        apiClient.reconnect(url: used.url, accessToken: token)
        apiClient.clearCache()
        let storedAge = UserDefaults.standard.integer(forKey: SettingsKey.privacyMaxContentAge)
        apiClient.applyContentRatingLimit(maxAge: storedAge)

        // 4. Observable state. `serverURL` FIRST, `currentUserId` LAST: a switch
        //    changes both in the same transaction and `AppNavigation` depends on
        //    its `serverURL` observer (invalidate) being delivered before its
        //    `currentUserId` observer (refresh) — see the ordering comment there.
        serverURL = used.url
        serverInfo = nil
        hasServer = true
        accessToken = token
        currentUserId = userId
        isAuthenticated = true

        // The switch committed — nothing left to roll back to.
        pendingRollbackServer = nil
        isAddingServer = false

        // 5. Republish the session to the widget / Top Shelf + refresh the admin
        //    flag for the new server's user.
        await refreshCurrentUser()

        // 6. Tier-1: every mounted screen reloads against the new server.
        NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)

        // 7. Background: the real name / version, written back into the entry so
        //    the servers list stops showing the placeholder.
        Task { [weak self] in
            guard let self else { return }
            guard let info = try? await self.apiClient.fetchServerInfo() else { return }
            // Race guard: a slow fetch for server A must never land after a
            // switch to B — it would paint A's name in B's chrome and, through
            // `upsertActiveEntry`, persist A's identity onto B's entry.
            guard self.activeServerId == used.id else { return }
            self.serverInfo = info
            self.updateServerMetadata(id: used.id, name: info.name, version: info.version, serverID: info.serverID)
        }
    }

    /// Write-back for metadata discovered about a registered server — the
    /// `fetchServerInfo` after a switch, or the servers list's reachability
    /// ping. Empty / nil values never overwrite a known one.
    func updateServerMetadata(id: String, name: String? = nil, version: String? = nil, serverID: String? = nil) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        var entry = servers[index]
        if let name, !name.isEmpty { entry.name = name }
        if let version, !version.isEmpty { entry.serverVersion = version }
        if let serverID, !serverID.isEmpty { entry.serverID = serverID }
        guard entry != servers[index] else { return }   // no spurious Observation cycle
        servers[index] = entry
        persistRegistry()
    }

    /// Switches the app to `entry`.
    ///
    /// Two-phase by design: a pre-flight `decideSwitch` short-circuits the cases
    /// that must never reach the network (offline, no stored token), then the
    /// token is validated against that server before anything is committed.
    @discardableResult
    func switchTo(_ entry: ServerEntry) async -> SwitchDecision {
        guard entry.id != activeServerId else { return .commit }

        // Captured BEFORE the client is repointed, and used explicitly on the
        // rollback path. Resolving the previous server lazily via
        // `currentActiveEntry` is unsafe here: its most-recently-used fallback
        // (for a nil / stale `activeServerId`) can resolve to `entry` itself, so
        // a refused switch would "roll back" onto the very server it just refused.
        let previous = currentActiveEntry

        switch ServerRegistry.decideSwitch(entry: entry, isOnline: isOnlineProvider(), validity: nil) {
        case .offline:
            return .offline                     // caller toasts; nothing mutated
        case .needsLogin:
            await beginReLogin(for: entry)
            return .needsLogin
        default:
            break
        }
        guard let token = entry.accessToken else {
            await beginReLogin(for: entry)
            return .needsLogin
        }

        apiClient.reconnect(url: entry.url, accessToken: token)
        switch await apiClient.validateSession() {
        case .valid:
            await applyActiveServer(entry)
            return .commit
        case .invalid:
            // Server-confirmed revocation — drop THIS entry's credentials only.
            clearSession(of: entry)
            await beginReLogin(for: entry)
            return .needsLogin
        case .indeterminate:
            // Unprovable failure: restore the previous client and KEEP the
            // target's token (the "never destroy on indeterminate" rule).
            await rollBackFailedSwitch(to: previous)
            return .unreachable
        }
    }

    /// Undoes the `reconnect` a refused switch performed, without any of the
    /// side effects of a real switch.
    ///
    /// Deliberately NOT `applyActiveServer`: nothing about the current server
    /// actually changed, so re-running the full path would post a tier-1 refresh,
    /// re-fetch the user and bump `lastUsedAt` — i.e. a flaky network would blow
    /// away the working server's loaded screens. Only the client is repointed
    /// (and the rating cap re-applied, since `reconnect` drops it).
    private func rollBackFailedSwitch(to previous: ServerEntry?) async {
        guard let previous, let token = previous.accessToken, !token.isEmpty else {
            // No usable server to fall back to — take the full path, which knows
            // how to land on LoginScreen / ServerSetupScreen.
            await restorePreviousServer()
            return
        }
        apiClient.reconnect(url: previous.url, accessToken: token)
        let storedAge = UserDefaults.standard.integer(forKey: SettingsKey.privacyMaxContentAge)
        apiClient.applyContentRatingLimit(maxAge: storedAge)
    }

    /// Points the shared client at `entry` without a token and leaves the app in
    /// the `hasServer && !isAuthenticated` state, which `AppNavigation` already
    /// renders as `LoginScreen` — password and Quick Connect both scoped to that
    /// server for free. A successful login commits the entry through
    /// `upsertActiveEntry(session:)`.
    func beginReLogin(for entry: ServerEntry) async {
        if pendingRollbackServer == nil, let current = currentActiveEntry, current.id != entry.id {
            pendingRollbackServer = current
        }
        serverTransitionGeneration &+= 1
        let generation = serverTransitionGeneration
        let info = try? await apiClient.connectToServer(url: entry.url)
        // Race guard: a newer transition (another switch, an add, a logout)
        // started while this handshake was in flight — its state has already been
        // committed and must not be overwritten by this stale one.
        guard generation == serverTransitionGeneration else { return }
        serverURL = entry.url
        serverInfo = info
        hasServer = true
        isAuthenticated = false
        currentUserId = nil
        accessToken = nil
    }

    /// Reuses the pre-auth flow (`ServerSetupScreen` → `LoginScreen`) to add a
    /// server. Deliberately does NOT call `keychain.deleteServerURL()` /
    /// `clearAll()`: the registry and the legacy mirror must both survive a
    /// cancelled add, which `restorePreviousServer()` then replays.
    func beginAddServer() {
        serverTransitionGeneration &+= 1
        pendingRollbackServer = currentActiveEntry
        isAddingServer = true
        hasServer = false
        isAuthenticated = false
        serverURL = nil
        serverInfo = nil
        currentUserId = nil
        accessToken = nil
    }

    /// Abandons an add / re-login and returns to the server the user came from.
    /// Falls back to today's `disconnectServer()` behavior when there is no
    /// previous server at all.
    func restorePreviousServer() async {
        serverTransitionGeneration &+= 1
        let snapshot = pendingRollbackServer ?? currentActiveEntry
        pendingRollbackServer = nil
        isAddingServer = false
        guard let snapshot else {
            disconnectServer()
            return
        }
        await applyActiveServer(snapshot)
    }

    /// Records a freshly authenticated session against the registry and marks it
    /// active. One method, every login path: first-ever login, add-server login,
    /// re-login after expiry (`LoginViewModel.completeSession`) and the quick
    /// user switch (`UserSwitchSheet.performAuth`).
    ///
    /// Does NOT write the legacy mirror — those call sites already saved it,
    /// which is exactly why they needed no other change.
    func upsertActiveEntry(session: UserSession) {
        guard let url = serverURL else { return }
        let normalized = ServerURLNormalizer.normalize(url) ?? url
        let existing = ServerRegistry.contains(url: normalized, in: servers)
        // The id must match the one `upsert` will keep, otherwise `activeServerId`
        // would point at nothing and resolution would silently fall back to MRU.
        let entry = ServerEntry(
            id: existing?.id ?? UUID().uuidString,
            name: Self.firstNonEmpty(serverInfo?.name, existing?.name) ?? ServerEntry.fallbackName,
            url: normalized,
            serverID: Self.firstNonEmpty(session.serverID, serverInfo?.serverID, existing?.serverID),
            accessToken: session.accessToken,
            userId: session.userID,
            username: session.username,
            serverVersion: Self.firstNonEmpty(serverInfo?.version, existing?.serverVersion),
            lastUsedAt: Date()
        )
        servers = ServerRegistry.upsert(entry, into: servers)
        activeServerId = entry.id
        persistRegistry()
        pendingRollbackServer = nil
        isAddingServer = false
    }

    /// Removes a NON-active server. The active one is never deletable — the user
    /// has to switch away first (mirrors the "THIS DEVICE" rule in the connected
    /// devices list).
    func removeServer(_ entry: ServerEntry) async {
        guard entry.id != activeServerId else { return }
        revokeSessionInBackground(for: entry)
        servers.removeAll { $0.id == entry.id }
        persistRegistry()
    }

    /// Signs out of the ACTIVE server. See `LogoutReason` for the two behaviors.
    @discardableResult
    func logout(reason: LogoutReason = .userInitiated) async -> LogoutOutcome {
        let active = currentActiveEntry

        if reason == .userInitiated, let active {
            revokeSessionInBackground(for: active)
        }

        // Keep the entry, drop its credentials: the card stays in the list ready
        // for a re-login. ONLY the active entry is touched, so a confirmed-invalid
        // session can never reach another server's token.
        if let active { clearSession(of: active) }

        keychain.clearAll()     // legacy mirror only — the registry survives (RULE)
        ExtensionSessionBridge.publish(serverURL: nil, accessToken: nil, userId: nil)
        serverTransitionGeneration &+= 1
        isAuthenticated = false
        currentUserId = nil
        accessToken = nil
        currentUser = nil
        isAdministrator = false
        // A logout ends whatever add / re-login flow was pending: a stale
        // snapshot would otherwise drive the LoginScreen's "go back to the
        // server you came from" affordance toward a session that no longer exists.
        pendingRollbackServer = nil
        isAddingServer = false

        switch reason {
        case .userInitiated:
            if let active, let candidate = ServerRegistry.nextCandidate(after: active.id, in: servers) {
                if await switchTo(candidate) == .commit {
                    return .switchedTo(candidate)
                }
                // The hop didn't commit. `hasServer` / `serverURL` are left
                // pointing at the server we just signed out of, so the user
                // lands on its `LoginScreen` — the same place a session-expiry
                // logout leaves them, and the one screen that is correct for
                // every failure here (`.offline` mutates nothing, `.needsLogin`
                // already routed to the candidate's login, `.unreachable` only
                // repointed the client back).
                return .signedOut
            }
            // Nothing left to hop to → `ServerSetupScreen`. The tokenless entry
            // stays in the registry so re-adding that server dedups onto it.
            activeServerId = nil
            persistRegistry()
            hasServer = false
            serverURL = nil
            serverInfo = nil
            return .signedOut
        case .sessionExpired:
            // `hasServer` + `serverURL` deliberately preserved so the user lands
            // on `LoginScreen` for the SAME server behind the "session expired"
            // toast instead of being bounced back to server setup. Other entries
            // are untouched.
            return .signedOut
        }
    }

    /// Strips credentials from one entry, keeping the entry itself.
    private func clearSession(of entry: ServerEntry) {
        guard let index = servers.firstIndex(where: { $0.id == entry.id }) else { return }
        servers[index].accessToken = nil
        servers[index].userId = nil
        servers[index].username = nil
        persistRegistry()
    }

    /// Fire-and-forget server-side revocation. Deliberately not awaited: the
    /// local entry is dropped either way, and a dead server must not freeze the
    /// UI for the request timeout. Standalone helper — never the shared client.
    private func revokeSessionInBackground(for entry: ServerEntry) {
        guard let token = entry.accessToken, !token.isEmpty, isOnlineProvider() else { return }
        let url = entry.url
        let deviceId = KeychainService.getOrCreateDeviceID()
        Task.detached(priority: .utility) {
            await ServerSessionRevoker.revoke(url: url, accessToken: token, deviceId: deviceId)
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Confirm-before-logout. A single ambiguous 401 from a hot path (or a
    /// cold-wake socket) no longer tears the session down: we silently re-check
    /// the token against the server (`validateSession` → `GET /Users/Me`) with a
    /// small bounded retry, and only `logout()` on a server-CONFIRMED `.invalid`.
    /// This is a pure app↔server network check — no popup, no user question.
    ///
    /// Invoked from the lazy `.cinemaxSessionExpired` notification AND the
    /// foreground re-validation (scenePhase `.active` after a long background).
    /// Debounced so concurrent triggers collapse into one probe.
    func handlePossibleSessionExpiry() async {
        guard isAuthenticated else { return }
        guard !sessionRevalidationInFlight else { return }
        sessionRevalidationInFlight = true
        defer { sessionRevalidationInFlight = false }

        // Offline → never log out. We can't prove the token is bad, and the
        // user has every right to turn their box/network off.
        guard isOnlineProvider() else { return }

        // A cold-wake network stack often needs a beat: retry briefly before
        // trusting an `.indeterminate`. 3 attempts at 0 / 0.4s / 0.8s.
        let backoffMs: [UInt64] = [0, 400, 800]
        for (attempt, delay) in backoffMs.enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000) }
            guard isAuthenticated, isOnlineProvider() else { return }
            switch await apiClient.validateSession() {
            case .valid:
                // Token still good — the 401 was spurious (cold-wake socket,
                // race). Opportunistically refresh the user + extension session.
                await refreshCurrentUser()
                return
            case .invalid:
                // Server-confirmed revocation — the one correct logout path.
                // `.sessionExpired` keeps `hasServer`/`serverURL` so the user
                // lands on this server's LoginScreen, never auto-hops to another
                // server, and never touches another entry's token.
                await logout(reason: .sessionExpired)
                NotificationCenter.default.post(name: .cinemaxSessionConfirmedInvalid, object: nil)
                return
            case .indeterminate:
                if attempt == backoffMs.count - 1 { return }   // out of retries → keep session
                continue
            }
        }
    }
}

struct AppNavigation: View {
    /// SwiftUI may recreate the root `AppNavigation` struct on scene events,
    /// and every recreation re-evaluates the `@State` initial-value
    /// expressions — then discards the results (`@State` keeps the first
    /// instance). For these three stores that's not just wasted work:
    /// `NetworkMonitor` starts a long-lived `NWPathMonitor` (a throwaway
    /// second one would leak a system-level path monitor), `MenuConfigStore`
    /// synchronously reads + decodes the persisted menu entries on the main
    /// thread, and `AppState` owns the shared API client + auth state. Guarded
    /// statics make the initial values process-singletons (same rationale as
    /// `configurePipeline`). The cheap stores (`ThemeManager`, etc.) stay
    /// inline — rebuilding them costs nothing.
    ///
    /// `sharedAppState` is deliberately not `private`: an App Intent runs
    /// outside the view hierarchy and has no environment to read from, so it
    /// reaches this instance directly to post its pending navigation. Any other
    /// access point would be a *second* `AppState` — a separate API client and
    /// auth state that the UI would never observe.
    static let sharedAppState = AppState()
    private static let sharedNetworkMonitor = NetworkMonitor()
    private static let sharedMenuConfig = MenuConfigStore()
    /// Owns the inbound remote-control socket. A process singleton for the same
    /// reason as the three above — scene-event struct recreation must not open a
    /// second `/socket` connection, which the server would treat as the same
    /// session and feed duplicate commands.
    private static let sharedRemoteControl = RemoteControlListener()

    @State private var appState = AppNavigation.sharedAppState
    @State private var themeManager = ThemeManager()
    @State private var loc = LocalizationManager()
    @State private var toasts = ToastCenter()
    @State private var network = AppNavigation.sharedNetworkMonitor
    @State private var menuConfig = AppNavigation.sharedMenuConfig
    /// Read straight off the static rather than through `@State`: nothing here
    /// observes it (it publishes into `AppState` / `ToastCenter` instead), so a
    /// property wrapper would only add semantics without a purpose.
    private var remoteControl: RemoteControlListener { Self.sharedRemoteControl }
    @State private var playlistPresenter = AddToPlaylistPresenter()
    @State private var cardActions = CardActionPresenter()
    @State private var settingsNav = SettingsNavCoordinator()
    @State private var hasCheckedSession = false
    /// When the app last entered the background — drives Part E foreground
    /// re-validation (only after a long gap, e.g. overnight standby).
    @State private var lastBackgroundedAt: Date?
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(SettingsKey.motionEffects) private var motionEffects: Bool = SettingsKey.Default.motionEffects
    /// Drives `RemoteControlListener`. Read here rather than inside the listener
    /// so flipping the toggle in Settings re-runs `onChange` and withdraws (or
    /// re-publishes) the capability declaration immediately.
    @AppStorage(SettingsKey.remoteControlEnabled) private var remoteControlEnabled: Bool = SettingsKey.Default.remoteControlEnabled

    /// SwiftUI may recreate the root `AppNavigation` struct on scene events;
    /// guard the one-time `ImagePipeline.shared` replacement so we don't throw
    /// away the in-memory `ImageCache` (and orphan in-flight decodes) on every
    /// recreation.
    ///
    /// The in-memory cost limit is bumped from Nuke's ~100 MB default to 256 MB
    /// because tvOS 4K backdrops decode to 4–8 MB each — the default evicts
    /// mid-render when scrolling library / detail screens.
    private static let configurePipeline: Void = {
        var config = ImagePipeline.Configuration.withDataCache(
            name: "com.cinemax.images",
            sizeLimit: 500 * 1024 * 1024 // 500 MB disk cache
        )
        let memoryCache = ImageCache()
        memoryCache.costLimit = 256 * 1024 * 1024 // 256 MB decoded images
        config.imageCache = memoryCache
        ImagePipeline.shared = ImagePipeline(configuration: config)
    }()

    #if os(iOS)
    /// One-shot cleanup for installs that used the removed (1.0.5, App Review
    /// 5.2.3) offline-downloads feature — the media tree can hold multiple GB
    /// and no UI remains to clear it. Cheap existence check; safe to re-run.
    private static func purgeLegacyDownloads() {
        UserDefaults.standard.removeObject(forKey: "downloads.userFlagCache")
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let appSupport = fm.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first else { return }
            let legacyRoot = appSupport.appendingPathComponent("Cinemax/Downloads",
                                                               isDirectory: true)
            if fm.fileExists(atPath: legacyRoot.path) {
                try? fm.removeItem(at: legacyRoot)
            }
        }
    }
    #endif

    init() {
        _ = Self.configurePipeline
    }

    var body: some View {
        ZStack {
            Group {
                if !hasCheckedSession {
                    launchScreen
                } else if !appState.hasServer {
                    ServerSetupScreen()
                } else if !appState.isAuthenticated {
                    // Keyed on the target server so retargeting the pre-auth
                    // flow at a DIFFERENT server (Servers sheet → "add", or
                    // "Change server" from the login screen) rebuilds the view
                    // instead of reusing it. `LoginViewModel` is owned by
                    // `LoginScreen`'s own `@State`, so a new identity is what
                    // discards the previous server's typed username/password,
                    // its stale error message and its Quick Connect code — and
                    // it re-fires `.task { checkQuickConnect }`, which is the
                    // only thing that re-probes whether THIS server has Quick
                    // Connect enabled (otherwise the CTA keeps the old
                    // server's answer).
                    LoginScreen()
                        .id(appState.serverURL)
                } else {
                    MainTabView()
                }
            }

            // Toasts overlay the entire app chrome (above tab bar / modals).
            ToastOverlay()
                .allowsHitTesting(toasts.current != nil)
        }
        .environment(appState)
        .environment(themeManager)
        .environment(loc)
        .environment(toasts)
        .environment(network)
        .environment(menuConfig)
        .environment(settingsNav)
        .environment(playlistPresenter)
        // "Add to a playlist" is raised from poster context menus inside lazy
        // grids, where a presentation attached to the cell dies when it scrolls
        // out. Hosting it once at the root also lets every grid, the search
        // results and the detail screen share one sheet with no plumbing.
        .modifier(AddToPlaylistPresentation(
            request: $playlistPresenter.request,
            appState: appState,
            themeManager: themeManager,
            loc: loc,
            toast: toasts
        ))
        .environment(cardActions)
        // Same reason as the playlist sheet: playback is launched from context
        // menus inside lazy grids, where a presentation attached to the cell
        // dies with it. Nothing to host here on tvOS — the menu calls
        // `VideoPlayerCoordinator` directly.
        #if os(iOS)
        .modifier(CardPlaybackPresentation(
            request: $cardActions.playback,
            appState: appState,
            themeManager: themeManager,
            loc: loc,
            toast: toasts
        ))
        #endif
        // "Play on…" is now also raised from context menus, so the sheet is
        // hosted here rather than by the detail screen. The modifier already
        // takes a binding: this is a relocation, not a rewrite.
        .modifier(RemotePlayPresentation(
            sheet: $cardActions.remotePlay,
            appState: appState,
            themeManager: themeManager,
            loc: loc,
            toast: toasts
        ))
        .environment(\.motionEffectsEnabled, motionEffects)
        // Respect the user's OS Dynamic Type setting while capping at a size
        // that won't collapse layouts (hero titles, tab bar). The app also has
        // its own `uiScale` in Settings > Interface > Font Size for finer control.
        .dynamicTypeSize(.xSmall ... .accessibility2)
        .preferredColorScheme(themeManager.colorScheme)
        // Widget / Top Shelf deep links (cinemax://item/{id}). Routed through
        // AppState — MainTabView switches to Home, HomeScreen pushes detail.
        .onOpenURL { url in
            appState.handleDeepLink(url)
        }
        .task {
            // Let the confirm-before-logout coordinator see real connectivity
            // (captured weakly so the closure can't extend NetworkMonitor's life).
            appState.isOnlineProvider = { [weak network] in network?.isOnline ?? true }
            await appState.restoreSession()
            hasCheckedSession = true
            // Baseline attach so the menu editor has an API client even with
            // no session. The library-mode view refresh is NOT triggered here:
            // `onChange(of: appState.currentUserId)` below owns it for every
            // session-establishing transition (restore, fresh login, user
            // switch) — `restoreSession` has already set `currentUserId` by
            // now, so the cold-restore case fires through that observer.
            menuConfig.attach(apiClient: appState.apiClient, userId: appState.currentUserId)
            // Load the restored server's menu profile in the SAME main-actor
            // slice as `hasCheckedSession = true` above — there is no `await`
            // between the two, so SwiftUI coalesces them into one render and
            // `MainTabView` never paints a menu the user hasn't configured.
            // RULE: keep it that way. Inserting an `await` between them makes
            // the tab bar visible before its profile is loaded.
            // `restoreSession` has already hydrated the registry, so both the
            // active id and the known ids are available here.
            menuConfig.activate(serverId: appState.activeServerId,
                                knownServerIds: Set(appState.servers.map(\.id)))
            #if os(iOS)
            // One-shot cleanup for installs that used the removed offline-
            // downloads feature — purge the (potentially multi-GB) media tree
            // that no longer has any UI to clear it.
            Self.purgeLegacyDownloads()

            // A joined group learns WHAT to watch only from the socket's
            // `PlayQueue` update — `GET /SyncPlay/List` carries no item. Route
            // it through the same in-process pair an App Intent and a remote
            // « Lire sur… » use, so a session join inherits the full fidelity of
            // a tap: series → next-up, resume position, version pick, prev/next.
            SyncPlayController.shared.onQueueChanged = { itemId, _ in
                guard AppState.isValidItemId(itemId) else { return }
                appState.pendingIntentPlaybackItemId = itemId
                appState.pendingDeepLinkItemId = itemId
            }
            // A crash / force-quit mid-playback leaves the playback Live
            // Activity pinned to the Lock Screen with a timer that keeps
            // running. Sweep any orphan at launch (the player also sweeps on
            // every attach).
            PlaybackLiveActivityController.endStaleActivities()
            #endif
            // Decide once, in the background, whether this server needs the
            // loopback stream proxy (dual-stack host with a black-holed IPv6
            // that libVLC would stall on). Non-blocking; cached for the session.
            StreamTransportPolicy.shared.configure(serverURL: appState.serverURL)
            // Advertise this device as a remote-control target and start
            // listening. Idempotent — `apply` no-ops when nothing changed, so
            // the observers below can call it freely.
            remoteControl.apply(appState: appState, toasts: toasts, enabled: remoteControlEnabled)
        }
        // RULE — DECLARATION ORDER IS LOAD-BEARING: `activeServerId` must be
        // observed BEFORE `currentUserId`. A server switch mutates both (and
        // `serverURL`) in one transaction, and SwiftUI delivers
        // same-transaction `onChange` handlers in declaration order. This one
        // swaps the menu profile; the `currentUserId` one below is the single
        // owner of `refreshAvailableViews()`, which merges the fetched
        // libraries into `libraryEntries` and persists them. Refreshing before
        // the swap would merge the NEW server's libraries into the PREVIOUS
        // server's profile and save them there. Do not reorder these, and do
        // not add a second refresh owner.
        .onChange(of: appState.activeServerId) { _, newId in
            // Menu configuration is per-server (mode, kind, order, enabled
            // flags, cached views). Nothing to invalidate on a switch — the
            // target server's own profile is loaded wholesale.
            menuConfig.activate(serverId: newId,
                                knownServerIds: Set(appState.servers.map(\.id)))
        }
        .onChange(of: appState.serverURL) { _, new in
            // Re-decide stream transport for the new server (or clear on logout).
            StreamTransportPolicy.shared.configure(serverURL: new)
            // The "Play on…" poll result is per-server (a different server has
            // different — possibly zero — controllable sessions). A stale
            // non-zero count from the server we just left would keep the entry
            // visible against the new one's sessions, and a stale zero would
            // hide it after switching to a server that DOES have a target;
            // both read as fresh even though neither is. Back to "unknown"
            // until a real probe runs again (`MediaDetailViewModel.loadRemoteTargets`).
            cardActions.knownRemoteTargetCount = nil
        }
        .onChange(of: appState.currentUserId) { oldId, newId in
            menuConfig.attach(apiClient: appState.apiClient, userId: newId)
            // Single owner of the library-mode view refresh: fires on EVERY
            // transition that establishes or changes the signed-in user —
            // cold-launch session restore (`restoreSession` sets the id from
            // inside `.task`), fresh login (`completeSession`), and user
            // switch. The fresh-login case is load-bearing: a server the user
            // has never signed into carries no cached views, and `.task` ran
            // pre-login with a nil userId, so skipping `nil → some` here meant
            // nothing ever fetched the views — the tab bar resolved to zero
            // tabs and the app came up as a black screen until the next full
            // relaunch.
            if newId != nil, oldId != newId,
               menuConfig.mode == .custom && menuConfig.customKind == .library {
                Task { await menuConfig.refreshAvailableViews() }
            }
            // A Watch Together group belongs to the session that opened it. On
            // a logout / user switch the hub rebuilds its socket for whoever is
            // signed in now, and a still-subscribed controller would apply the
            // NEW session's transport commands to a group on the OLD one.
            SyncPlayController.shared.sessionDidEnd()
            // Capabilities are per-session, so a login / user switch has to
            // re-declare them; a logout tears the socket down (`apply` sees
            // `isAuthenticated == false`).
            remoteControl.apply(appState: appState, toasts: toasts, enabled: remoteControlEnabled)
            // Same rationale as the `serverURL` reset above: a different
            // signed-in user (switch, or logout → nil) may see a different
            // controllable-session landscape, so the last poll's count can't
            // be trusted for them either.
            cardActions.knownRemoteTargetCount = nil
        }
        .onChange(of: remoteControlEnabled) { _, enabled in
            // Withdrawing re-posts with `supportsMediaControl: false`, which is
            // what actually removes this device from other clients' pickers —
            // just closing the socket would leave the stale declaration standing.
            remoteControl.apply(appState: appState, toasts: toasts, enabled: enabled)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                lastBackgroundedAt = Date()
                NotificationCenter.default.post(name: .cinemaxDidEnterBackground, object: nil)
                // Drop the remote-control socket: a backgrounded app can't act
                // on a play command anyway, and holding a WebSocket open is a
                // standing battery / radio-wake cost. Re-established on `.active`.
                remoteControl.stop()
            } else if newPhase == .active {
                // Network conditions may have changed while backgrounded —
                // re-evaluate whether the proxy is needed for this server.
                StreamTransportPolicy.shared.refresh()
                // Part E — proactive re-validation after a MEANINGFUL background
                // gap (overnight standby is the bug; ignore quick app-switcher
                // peeks). Reuses the same coordinator: it gates on connectivity,
                // debounces against a concurrent lazy-401 cycle, refreshes the
                // user on `.valid`, and only logs out on a confirmed `.invalid`.
                if appState.isAuthenticated,
                   let since = lastBackgroundedAt,
                   Date().timeIntervalSince(since) > 60 {
                    lastBackgroundedAt = nil
                    Task { await appState.handlePossibleSessionExpiry() }
                }
                // Re-open the socket dropped on background and re-declare the
                // capabilities, since the session may have been reaped while away.
                remoteControl.apply(appState: appState, toasts: toasts, enabled: remoteControlEnabled)
            }
        }
        .onChange(of: network.isOnline) { _, online in
            // Connectivity flipped (e.g. Wi-Fi ⇄ cellular) — IPv6 reachability
            // is per-network, so re-run the transport probe.
            if online {
                StreamTransportPolicy.shared.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxSessionExpired)) { _ in
            // Lazy 401 recovery — fired by any API call that surfaces an HTTP
            // 401. We do NOT log out immediately: a single ambiguous 401 (cold
            // wake, transient server hiccup) would wrongly disconnect a user
            // whose token is still valid. Instead, silently re-validate against
            // the server first; logout happens only on a confirmed `.invalid`
            // (which posts `.cinemaxSessionConfirmedInvalid` below).
            guard appState.isAuthenticated else { return }
            Task { await appState.handlePossibleSessionExpiry() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxSessionConfirmedInvalid)) { _ in
            // The session was authoritatively confirmed invalid — `logout()`
            // already ran inside the coordinator. Surface the toast here (only
            // on the View, which owns `toasts`/`loc`). The queue collapses
            // concurrent fires to a single visible pill.
            toasts.error(loc.localized("session.expired"))
        }
        .onChange(of: motionEffects) { _, _ in
            // Restart/stop the rainbow accent animation task when the user
            // toggles Motion Effects — the task otherwise only re-checks the
            // flag on each tick.
            themeManager.motionEffectsDidChange()
        }
    }

}

extension Notification.Name {
    static let cinemaxDidEnterBackground = Notification.Name("cinemaxDidEnterBackground")
    /// Posted by `AppState.handlePossibleSessionExpiry` ONLY when the server
    /// authoritatively confirms the token is revoked/expired. `logout()` has
    /// already run; `AppNavigation` surfaces the "session expired" toast.
    static let cinemaxSessionConfirmedInvalid = Notification.Name("cinemaxSessionConfirmedInvalid")
    /// Tier-1 refresh: catalogue *content* changed or the cache was cleared —
    /// a FULL reload is warranted. Fired by Settings → Server "Refresh
    /// Catalogue", the parental-controls rating limit, and Admin metadata /
    /// identify / delete flows. Home + every mounted Library tab full-reload,
    /// deferred until next visible for hidden screens.
    static let cinemaxShouldRefreshCatalogue = Notification.Name("cinemaxShouldRefreshCatalogue")
    /// Tier-2 refresh: ONE item's watched / resume-position userData changed via
    /// a per-item toggle (card context menu, detail / episode / season watched
    /// toggle, Continue Watching menu, "clear Continue Watching"). The lighter
    /// sibling of `cinemaxShouldRefreshCatalogue`: Home refreshes only its
    /// userData rails (resume / next-up / favorites), never the genre fan-out;
    /// Library tabs reload only while visible (so an unwatched-only filter
    /// reflects the toggle) and defer otherwise. Favorite hearts stay on the
    /// separate `.cinemaxFavoritesChanged` fast path (cards carry no heart badge).
    static let cinemaxItemUserDataChanged = Notification.Name("cinemaxItemUserDataChanged")
    /// Posted after a favorite heart toggle succeeds. Home observes it and
    /// refreshes just its Favorites row (the full-reload notification above
    /// would re-shuffle genre rows and clear caches — overkill for a heart).
    static let cinemaxFavoritesChanged = Notification.Name("cinemaxFavoritesChanged")

    /// A playlist was created, or an item was added to one. Its own fast path,
    /// like `cinemaxFavoritesChanged`: nothing about an item's userData changed,
    /// so neither refresh tier applies — what changed is the set of playlists
    /// and their item counts. Home's Playlists rail is the consumer, and it
    /// matters that it listens: that rail is the only route to a playlist on the
    /// default menu, so without this the surface that exists to make playlists
    /// findable would be the last place to hear about a new one.
    static let cinemaxPlaylistsChanged = Notification.Name("cinemaxPlaylistsChanged")
    /// Posted by the API client when any session-scoped call returns HTTP 401.
    /// `AppNavigation` observes this on MainActor and runs the logout + toast.
    /// Cross-actor bridge: the API callback runs from a non-MainActor context
    /// and cannot capture MainActor state directly.
    static let cinemaxSessionExpired = Notification.Name("cinemaxSessionExpired")
}

private extension AppNavigation {
    var launchScreen: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            LoadingStateView()
        }
    }
}
