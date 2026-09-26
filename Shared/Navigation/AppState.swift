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
    /// The server this client talks to. A plain stored property: `imageBuilder`
    /// below is DERIVED from it on read instead of being rewritten by a
    /// `didSet`, which the `@Observable` RULE forbids (audit 2026-09-22, Q8).
    var serverURL: URL?
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
    /// Validates a token against a server WITHOUT repointing the shared client
    /// (`ServerSessionValidator`). A seam like `isOnlineProvider`: the switch
    /// tests route it to their mock client's `validateSession()`.
    var sessionValidator: @MainActor (URL, String) async -> SessionValidity = { url, token in
        await ServerSessionValidator.validate(
            url: url, accessToken: token, deviceId: KeychainService.getOrCreateDeviceID()
        )
    }

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

    /// Image URLs for the current server. Derived from `serverURL` — reading it
    /// reads `serverURL`, so observation follows the server exactly as the old
    /// `didSet` did — and cached per URL, so it is still rebuilt only when the
    /// server changes, not on every card that asks for a poster.
    var imageBuilder: ImageURLBuilder {
        let url = serverURL ?? Self.placeholderServerURL
        if let cached = imageBuilderCache, cached.url == url { return cached.builder }
        let builder = ImageURLBuilder(serverURL: url)
        imageBuilderCache = (url, builder)
        return builder
    }
    @ObservationIgnored private var imageBuilderCache: (url: URL, builder: ImageURLBuilder)?

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
        // First of all: take the app-private items out of the group the
        // extensions can read (one-shot, a move — nothing is deleted).
        keychain.migrateToPrivateAccessGroupIfNeeded()
        keychain.migrateToMultiServerIfNeeded()
        loadServersFromKeychain()

        guard let serverURL = keychain.getServerURL(),
              let session = keychain.getUserSession() else {
            return
        }

        self.serverURL = serverURL   // imageBuilder follows (derived)
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
        // The parental cap travels with the session: it lives in app-private
        // `UserDefaults`, which the extensions cannot read, so without this the
        // widget and the Top Shelf display titles the app itself hides (#230).
        ExtensionSessionBridge.publish(
            serverURL: serverURL,
            accessToken: accessToken,
            userId: currentUserId,
            maxContentAge: UserDefaults.standard.integer(forKey: SettingsKey.privacyMaxContentAge)
        )
        guard let id = currentUserId else {
            if currentUser != nil { currentUser = nil }
            if isAdministrator { isAdministrator = false }
            return
        }
        do {
            let user = try await apiClient.getUserByID(id: id)
            // Equality-guarded: this runs on EVERY return to the foreground and
            // on every `UserUpdated` socket frame, and `@Observable` fires
            // `withMutation` even for an identical value — which invalidated
            // every view reading either property (each library card reads
            // `isAdministrator` on iOS) for an answer that almost never changes.
            // Compared on what the UI reads, not the whole DTO: `UserDto`
            // carries `lastActivityDate`, which the server moves every minute
            // of activity, so a plain `!=` let nearly every refresh through.
            if !Self.sameVisibleUser(user, currentUser) { currentUser = user }
            let admin = user.policy?.isAdministrator ?? false
            if admin != isAdministrator { isAdministrator = admin }
        } catch {
            // Network blip — keep last-known values.
        }
    }

    /// The fields of the signed-in user the UI actually reads (name, avatar,
    /// policy), plus its id. `nonisolated` + static: a pure comparison.
    nonisolated static func sameVisibleUser(_ fresh: UserDto, _ current: UserDto?) -> Bool {
        guard let current else { return false }
        return fresh.id == current.id
            && fresh.name == current.name
            && fresh.primaryImageTag == current.primaryImageTag
            && fresh.policy == current.policy
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
    /// **ONE consumer**: `MainTabView`, which presents the detail modally from
    /// the tab root and clears this. Home used to push it instead when a Home
    /// tab existed, and that route drops the link whenever a fiche is already
    /// pushed there — see the one-route RULE on that observer (#171).
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

    /// The position the request must open at, in Jellyfin ticks, when it came
    /// from a Watch Together queue. `nil` — and only `nil` — means "no group
    /// position given, use the fiche's own resume".
    ///
    /// Set alongside `pendingIntentPlaybackItemId` and cleared by the same
    /// consumer. It exists because in a session the GROUP's position is
    /// authoritative: without it the joiner opened at its own resume point and
    /// two people watched different parts of the same film with no signal. See
    /// `SyncPlayJoinStart` for the rule and the measurement.
    var pendingIntentPlaybackStartTicks: Int?

    // NOTE — `isPendingIntentPlayback(_:)` lived here as the routing SSOT that
    // kept two deep-link observers in step: `MainTabView` sent playback
    // requests to its modal and `HomeScreen.consumeDeepLink` skipped them. Both
    // callers are gone (#171) — every item deep link now takes the one modal
    // route — so the predicate had nothing left to arbitrate and was deleted
    // rather than left as a second, unread opinion on where a link should go.

    /// Search term raised by an App Intent. `SearchScreen` consumes it once and
    /// runs the search; `pendingDeepLinkTabId` gets the user to that tab.
    var pendingIntentSearchQuery: String?

    /// Both carriers — the custom scheme the app's own extensions emit and the
    /// Universal Links form (`https://<host>/item/{id}`, delivered by iOS only
    /// after the host's AASA verified this app) — read through the one pure
    /// `DeepLinkRoute.parse`, which also applies `isValidItemId`: a malformed
    /// link is dropped before it can drive a lookup with attacker-controlled
    /// path text. `onOpenURL` receives Universal Links as well as scheme URLs.
    func handleDeepLink(_ url: URL) {
        switch DeepLinkRoute.parse(url, isValidItemId: Self.isValidItemId) {
        case .item(let id):
            pendingDeepLinkItemId = id
        case .home:
            pendingDeepLinkTabId = "home"
        case nil:
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
        // `isASCII` too: `Character.isHexDigit` also answers yes for the
        // FULL-WIDTH digits and letters (`０`…`９`, `ａ`…`ｆ`), which no
        // Jellyfin id contains (audit 2026-09-22, S11).
        if id.count == 32, id.allSatisfy({ $0.isASCII && $0.isHexDigit }) { return true }
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

    /// The user's own label for the server the app is ON, when they gave one.
    /// Keyed on `activeServerId`, never `currentActiveEntry` — its MRU fallback
    /// names a server the app isn't on while signed out. Note it does NOT name
    /// a re-login target either (`beginReLogin` leaves `activeServerId` on the
    /// previous server), which is why `LoginScreen` keeps the server's own name.
    var activeServerNameOverride: String? {
        guard let activeServerId else { return nil }
        return servers.first { $0.id == activeServerId }?.displayNameOverride
    }

    /// The name the chrome shows for the server the app is ON: the user's label,
    /// else the name stored on the registry entry, else the live `serverInfo`.
    /// The entry comes first because `serverInfo` is nil'd on every switch and
    /// only refilled by a background fetch — reading it alone printed the
    /// placeholder, then the name, on every switch. Keyed on `activeServerId`
    /// for the same reason as `activeServerNameOverride`.
    var activeServerDisplayName: String {
        if let activeServerId, let entry = servers.first(where: { $0.id == activeServerId }) {
            if let override = entry.displayNameOverride, !override.isEmpty { return override }
            if !entry.name.isEmpty, entry.name != ServerEntry.fallbackName { return entry.name }
        }
        return serverInfo?.name ?? ServerEntry.fallbackName
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

    /// Gives a registered server the user's own label (local to this device).
    /// Empty input — or input identical to the server's own name — clears the
    /// label, so the entry follows the server's name again
    /// (`ServerEntry.normalizedDisplayNameOverride`). One of the two writers of
    /// the user-owned fields `ServerRegistry.upsert` preserves.
    @discardableResult
    func renameServer(id: String, to raw: String) -> ServerEntry? {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return nil }
        var entry = servers[index]
        entry.displayNameOverride = ServerEntry.normalizedDisplayNameOverride(raw, serverName: entry.name)
        guard entry != servers[index] else { return entry }   // no spurious Observation cycle
        servers[index] = entry
        persistRegistry()
        return entry
    }

    /// Stores a manual order for the servers list — `orderedIds` is the
    /// COMPLETE list as displayed after the user's move (see
    /// `ServerRegistry.applyingOrder`). The other writer of the user-owned
    /// fields `ServerRegistry.upsert` preserves.
    func reorderServers(orderedIds: [String]) {
        let reordered = ServerRegistry.applyingOrder(orderedIds, to: servers)
        guard reordered != servers else { return }
        servers = reordered
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

        // Validated OFF the shared client: it stays on the working server until
        // the target is known good, so nothing on screen can reach the target
        // with the wrong user id, and a refusal has nothing to undo (B4/B10).
        switch await sessionValidator(entry.url, token) {
        case .valid:
            await applyActiveServer(entry)       // the one repoint of a switch
            return .commit
        case .invalid:
            // Server-confirmed revocation — drop THIS entry's credentials only.
            clearSession(of: entry)
            await beginReLogin(for: entry)
            return .needsLogin
        case .indeterminate:
            // Unprovable failure: KEEP the target's token (the "never destroy
            // on indeterminate" rule). The client was never repointed, so the
            // working server — its screens, its learned version — is untouched.
            return .unreachable
        }
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
    /// Re-publishes the extension session snapshot so the widget and the Top
    /// Shelf pick up a changed parental cap.
    ///
    /// Needed because `refreshCurrentUser()` — the only publisher — runs on
    /// session-establishing paths and on foreground, NOT when the user edits the
    /// cap. Without this the extensions would keep the old ceiling until the next
    /// login or app foreground, i.e. the setting would look applied and not be.
    /// `publish` is already idempotent (in-process memo + field-wise Keychain
    /// compare), and the cap is part of `Session`, so an unchanged cap costs
    /// nothing and a changed one is written and pokes both extensions.
    func republishExtensionSession() {
        ExtensionSessionBridge.publish(
            serverURL: serverURL,
            accessToken: accessToken,
            userId: currentUserId,
            maxContentAge: UserDefaults.standard.integer(forKey: SettingsKey.privacyMaxContentAge)
        )
    }

    func removeServer(_ entry: ServerEntry) async {
        guard entry.id != activeServerId else { return }
        revokeSessionInBackground(for: entry)
        servers.removeAll { $0.id == entry.id }
        persistRegistry()
        // Its search history goes with it. Nothing could ever read it again —
        // a re-added server mints a fresh id — so keeping it would only leave
        // that library's queries on the device.
        SearchHistoryStore.clear(serverId: entry.id)
        // Its certificate approval goes with it: a pin outliving its server
        // would silently pre-approve whatever answers on that host:port later.
        if let key = ServerCertificateTrust.trustKey(for: entry.url) {
            ServerTrustDelegate.shared.forget(trustKey: key)
        }
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
        ExtensionSessionBridge.publish(serverURL: nil, accessToken: nil, userId: nil, maxContentAge: nil)
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
                // already routed to the candidate's login, `.unreachable` never
                // touched the client — it validated off-client). Known, and
                // shared with the `.sessionExpired` path: the shared client keeps
                // the revoked token until LoginScreen's sign-in replaces it.
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
