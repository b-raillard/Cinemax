import Foundation
import Observation
import OSLog
import CinemaxKit
import JellyfinAPI

/// States and transitions only: never a cookie, a key, a Quick Connect code or
/// secret, an address or a response body.
private let logger = Logger(subsystem: "com.cinemax", category: "Seerr")

/// The ACTIVE account's Seerr identity — one root store, a process singleton
/// (`AppNavigation.sharedSeerrSession`), read at render by every Seerr surface.
///
/// Four invariants, in order of importance:
/// 1. **Fail closed.** An account whose policy is not known yet (or carries
///    none), or that is capped by age (server policy OR this device's
///    `privacy.maxContentAge`, the latter re-read live), or without Pro, makes
///    no Seerr call at all — not from `reload`, not through `perform`, not
///    through `signIn`.
/// 2. **No answer crosses accounts.** Everything is keyed to `accountKey`, a
///    `generation` bumped by `reset()` — synchronously, on the account change,
///    and again at the head of `reload` before its first `await` — and the
///    account the app is on RIGHT NOW (`activeAccountKeyProvider`), which
///    closes the window between `applyActiveServer` and the reset. A write
///    after an `await` is dropped once the generation moved; `perform` turns a
///    late answer into a `CancellationError`.
/// 3. **A secret only goes where it was issued.** A cookie and a device key
///    are stored with the Seerr address they belong to (`SeerrBoundSecret`):
///    a configuration pointing elsewhere makes them unusable, never sent.
/// 4. **A 403 is probed before it is believed** (spec, § Spike findings 2):
///    Seerr answers a dead session, a refused key and a genuine refusal alike.
@MainActor @Observable
final class SeerrSession {
    enum Connection: Equatable {
        /// Not known, or not applicable (capped, disabled, no Pro, no address,
        /// offline before the first answer). Nothing Seerr renders.
        case unavailable
        /// Account mode without a (live) session: « Se connecter à Seerr ».
        case notConnected
        case connected(SeerrUser)
        /// Key mode: Seerr has no user for this Jellyfin user.
        case notLinked
        /// Key mode: Seerr refuses this device's API key.
        case keyRefused
    }

    /// What a screen captures before a Seerr load and checks before writing
    /// the answer (`isCurrent`).
    struct Snapshot: Equatable, Sendable {
        let accountKey: String
        let generation: Int
    }

    // MARK: Observed state

    private(set) var config: SeerrUserConfig?
    private(set) var connection: Connection = .unavailable
    private(set) var publicSettings: SeerrPublicSettings?
    /// This device holds an API key for the active server AND its address: every
    /// profile goes through it (`X-API-User`), the account mode's cookie is not
    /// used.
    private(set) var usesDeviceKey = false
    /// The server half of the cap, as of the last `reload` (`true` until the
    /// policy is known).
    private var policyCapped = true
    /// How many requests wait, as last read — the raw number behind the
    /// Réglages bubble. Read it through `pendingBadgeCount`, which hides it
    /// from anyone who may not manage requests.
    private(set) var pendingCount: Int?
    /// Bumped by every write of `pendingCount`: a read that started before a
    /// fresher number landed (an approval, « À valider »'s listing) drops its
    /// older answer.
    @ObservationIgnored private var pendingCountWrites = 0

    /// Capped by age — the server policy, or this device's setting read LIVE.
    var isAgeCapped: Bool {
        policyCapped || defaults.integer(forKey: SettingsKey.privacyMaxContentAge) > 0
    }

    // MARK: Providers (wired at the root)

    /// Whether the Pro allows requests — `ProFeatureAccess.allows(.requests)`,
    /// wired by `AppNavigation` before the first reload (and the session is
    /// reloaded when the tier moves); `false` ⇒ no Seerr call anywhere.
    /// Unwired, it answers `false`: fail closed.
    @ObservationIgnored var proAllowsProvider: @MainActor () -> Bool = { false }
    /// The account the app is on (`AppState.activeAccountKey`), wired by
    /// `AppNavigation`. Unwired (`nil`) serves nothing: fail closed.
    @ObservationIgnored var activeAccountKeyProvider: @MainActor () -> String? = { nil }

    // MARK: Identity (not observed)

    @ObservationIgnored private(set) var client: SeerrClient?
    @ObservationIgnored private var generation = 0
    /// Bumped by every `reload`, never by `reset`: two reloads of the SAME
    /// account (foreground + a `UserUpdated` frame) cannot leave the older
    /// answer last. Invisible to `Snapshot`, so screens are not disturbed.
    @ObservationIgnored private var reloadPass = 0
    @ObservationIgnored private var accountKey: String?
    @ObservationIgnored private var jellyfinUserId: String?
    /// The Jellyfin server the approvals go to, as of the last `reload`: from
    /// an HTTPS one, a plain-HTTP Seerr gets no silent sign-in.
    @ObservationIgnored private var jellyfinURL: URL?
    /// As stored — `credential()` uses each only toward its own address.
    @ObservationIgnored private var cookie: SeerrBoundSecret?
    @ObservationIgnored private var deviceKey: SeerrBoundSecret?
    @ObservationIgnored private var approve: (@Sendable (String) async throws -> Bool)?
    @ObservationIgnored private var languageCode: String?

    /// One silent sign-in: who started it, for which account and address, and
    /// which cookie it replaces.
    private struct ReSignInTicket: Sendable {
        let id: Int
        let generation: Int
        let accountKey: String
        let origin: URL
        let deadCookie: String
    }
    /// The silent sign-in in flight, shared by every caller of its generation.
    private struct PendingReSignIn {
        let ticket: ReSignInTicket
        let task: Task<ReSignIn, Never>
    }
    private enum ReSignIn: Sendable {
        case renewed(String)
        case failed
        case stale
    }
    @ObservationIgnored private var pendingReSignIn: PendingReSignIn?
    @ObservationIgnored private var reSignInCount = 0

    @ObservationIgnored private let storage: any SeerrSecretStorage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: any SeerrTransport
    @ObservationIgnored private let signInPause: @Sendable () async throws -> Void

    init(
        storage: any SeerrSecretStorage = KeychainService(),
        defaults: UserDefaults = .standard,
        transport: (any SeerrTransport)? = nil,
        signInPause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    ) {
        self.storage = storage
        self.defaults = defaults
        self.transport = transport ?? SeerrClient.makeDefaultTransport()
        self.signInPause = signInPause
    }

    // MARK: Account lifecycle

    /// Forgets the identity — never the stored secrets, which are keyed per
    /// account precisely so that they survive a switch. Synchronous. A silent
    /// sign-in in flight is cancelled with it.
    func reset() {
        generation &+= 1
        pendingReSignIn?.task.cancel()
        pendingReSignIn = nil
        accountKey = nil
        jellyfinUserId = nil
        jellyfinURL = nil
        cookie = nil
        deviceKey = nil
        approve = nil
        client = nil
        config = nil
        connection = .unavailable
        publicSettings = nil
        usesDeviceKey = false
        policyCapped = true
        pendingCount = nil
    }

    /// The account changed (`onChange(of: activeAccountKey)`, and the head of
    /// `reload`): resets unless the state already belongs to `newKey`. SwiftUI
    /// may deliver the `onChange` AFTER the reload of the account it announces
    /// has begun — an unconditional reset there would drop that reload's
    /// answers and leave Seerr dark until the next foreground.
    func accountDidChange(to newKey: String?) {
        if newKey == nil || newKey != accountKey { reset() }
    }

    func setLanguage(_ code: String?) {
        guard code != languageCode else { return }
        languageCode = code
        if let client {
            self.client = SeerrClient(baseURL: client.baseURL, languageCode: code, transport: transport)
        }
    }

    /// Re-reads the active account's configuration and Seerr identity. Called
    /// after every `refreshCurrentUser` (sign-in, switch, restore, foreground,
    /// `UserUpdated`), when the network comes back and when the active
    /// account's age cap changes. The SAME account keeps its generation and
    /// its state until a new answer replaces it — no flicker on every return.
    func reload(appState: AppState) async {
        let key = appState.activeAccountKey
        accountDidChange(to: key)
        guard let key, let userId = appState.currentUserId, let serverId = appState.activeServerId else { return }
        accountKey = key
        jellyfinUserId = userId
        jellyfinURL = appState.serverURL
        reloadPass &+= 1
        let pass = (generation: generation, reload: reloadPass)
        approve = Self.makeApprover(appState: appState, accountKey: key)

        // The policy first. Not known yet (no user, someone else's record) or
        // absent is a cap: nothing is read for a capped account — not even its
        // configuration.
        let user = appState.currentUser
        let policy = user?.id == userId ? user?.policy : nil
        setPolicyCapped(policy.map { SeerrAccess.isAgeCapped(deviceMaxAge: 0, policy: $0) } ?? true)
        guard !isAgeCapped else {
            forgetIdentity(keepingConfig: false)
            return
        }
        let isAdmin = appState.isAdministrator

        let api = appState.apiClient
        let prefs: DisplayPreferencesDto
        do {
            prefs = try await api.getDisplayPreferences(
                id: SeerrUserConfig.preferencesId, client: SeerrUserConfig.client, userId: nil)
        } catch {
            // Last known kept for this account; nothing Seerr is called.
            logger.notice("Seerr ▸ configuration unreadable, last known kept")
            return
        }
        guard isLive(pass) else { return }
        let fresh = SeerrUserConfig.read(prefs)
        if config != fresh { config = fresh }
        guard let url = fresh.url, Self.resolvesIdentity(fresh, isAdmin: isAdmin), proAllowsProvider() else {
            forgetIdentity(keepingConfig: true)
            return
        }
        guard appState.isOnlineProvider() else { return }

        if client?.baseURL != url {
            client = SeerrClient(baseURL: url, languageCode: languageCode, transport: transport)
            setConnection(.unavailable)
            if publicSettings != nil { publicSettings = nil }
            // Another Seerr's queue: its count is not this one's.
            if pendingCount != nil { pendingCount = nil }
        }
        guard let client else { return }
        // A key entered for another address is not this Seerr's: the device is
        // keyless here, and the key is never sent.
        let usableKey = storage.seerrAPIKeys()[serverId].flatMap { !$0.value.isEmpty && $0.isBound(to: url) ? $0 : nil }
        if (usableKey != nil) != usesDeviceKey {
            usesDeviceKey = usableKey != nil
            setConnection(.unavailable)
        }
        deviceKey = usableKey
        cookie = storage.seerrSessions()[key]
        let usableCookie = cookie.flatMap { $0.isBound(to: url) ? $0 : nil }

        let settings: SeerrPublicSettings
        do {
            settings = try await client.publicSettings()
        } catch {
            return
        }
        guard isLive(pass) else { return }
        if publicSettings != settings { publicSettings = settings }

        if let usableKey {
            await resolveByKey(usableKey.value, jellyfinUserId: userId, client: client, pass: pass)
        } else if let usableCookie {
            await resolveBySession(usableCookie.value, client: client, pass: pass)
        } else {
            setConnection(.notConnected)
        }
    }

    /// Whose Seerr identity is resolved: an enabled account, or an
    /// administrator whose own switch is off (the Configuration page needs
    /// their identity for the per-user lookups). The browse surfaces still
    /// require `isEnabled` (`SeerrAccess.showsBrowse`).
    private static func resolvesIdentity(_ config: SeerrUserConfig, isAdmin: Bool) -> Bool {
        config.url != nil && (config.isEnabled || isAdmin)
    }

    private func resolveByKey(_ key: String, jellyfinUserId: String, client: SeerrClient,
                              pass: (generation: Int, reload: Int)) async {
        do {
            let found = try await client.user(forJellyfinUserId: jellyfinUserId, auth: .adminKey(key))
            guard isLive(pass) else { return }
            setConnection(found.map(Connection.connected) ?? .notLinked)
        } catch SeerrError.forbidden {
            guard isLive(pass) else { return }
            logger.notice("Seerr ▸ device key refused")
            setConnection(.keyRefused)
        } catch {
            // A blip: the last known state stands.
        }
    }

    private func resolveBySession(_ cookie: String, client: SeerrClient,
                                  pass: (generation: Int, reload: Int)) async {
        do {
            let user = try await client.me(.session(cookie: cookie))
            guard isLive(pass) else { return }
            setConnection(.connected(user))
        } catch SeerrError.forbidden {
            // `/auth/me` refusing IS the dead-session probe: sign in again,
            // once, silently (spec call #18); a failure shows the prompt.
            guard isLive(pass) else { return }
            _ = await reSignInOnce(client: client, deadCookie: cookie)
        } catch {
            // A blip: the last known state stands.
        }
    }

    // MARK: Requests waiting (the Réglages bubble)

    /// The number the bubble on Réglages and on « Demandes » shows: only for a
    /// connected Seerr user who may manage requests (Pro, not age-capped —
    /// `credential()`'s gate), `nil` otherwise and while unknown.
    var pendingBadgeCount: Int? {
        showsPendingBadge ? pendingCount : nil
    }

    /// Whether this account may see the bubble at all (its count aside).
    /// `servesActiveAccount` comes LAST: `accountKey` is not observed, so
    /// short-circuiting on it first left `connection` unread — SwiftUI then
    /// never redrew the bar when the count arrived (recette 2026-11-08).
    var showsPendingBadge: Bool {
        SeerrPendingModel.isShown(for: connection) && proAllowsProvider() && !isAgeCapped && servesActiveAccount
    }

    /// Re-reads the count: one row asked, the listing's total kept. Called
    /// after the `reload` of `onCurrentUserRefreshed` (launch, foreground),
    /// by `MainTabView` whenever `showsPendingBadge` turns true (back online,
    /// sign-in, Pro or the age cap back — the identity coming back) and after
    /// a withdrawal. A failure keeps the last number; a user who may not
    /// manage requests asks nothing.
    func refreshPendingCount() async {
        guard SeerrPendingModel.isShown(for: connection), let snap = snapshot() else { return }
        let asked = pendingCountWrites
        let page: SeerrRequestPage
        do {
            page = try await perform { client, credential in
                try await client.requests(filter: .pending, take: 1, skip: 0, requestedBy: nil, credential)
            }
        } catch {
            return
        }
        guard pendingCountWrites == asked else { return }
        notePendingCount(page.total, for: snap)
    }

    /// « À valider » read or settled a request: its total is the fresh count.
    func notePendingCount(_ count: Int, for snapshot: Snapshot) {
        guard isCurrent(snapshot) else { return }
        pendingCountWrites &+= 1
        if pendingCount != count { pendingCount = count }
    }

    // MARK: Stale-answer token

    func snapshot() -> Snapshot? {
        guard servesActiveAccount, let accountKey else { return nil }
        return Snapshot(accountKey: accountKey, generation: generation)
    }

    func isCurrent(_ snapshot: Snapshot) -> Bool {
        snapshot.generation == generation && snapshot.accountKey == accountKey && servesActiveAccount
    }

    /// The state belongs to the account the app is on right now.
    private var servesActiveAccount: Bool {
        guard let accountKey else { return false }
        return accountKey == activeAccountKeyProvider()
    }

    private func isLive(_ pass: (generation: Int, reload: Int)) -> Bool {
        pass.generation == generation && pass.reload == reloadPass
    }

    // MARK: Calls

    /// How the active account is authenticated right now, toward the
    /// configured Seerr only; `nil` when it is not (another account on screen,
    /// no Pro, capped, not connected, not linked, key refused, a secret issued
    /// for another address).
    func credential() -> SeerrCredential? {
        guard servesActiveAccount, proAllowsProvider(), !isAgeCapped, let client,
              case .connected(let user) = connection else { return nil }
        if usesDeviceKey {
            guard let deviceKey, deviceKey.isBound(to: client.baseURL) else { return nil }
            return .apiKey(key: deviceKey.value, user: user.id)
        }
        guard let cookie, cookie.isBound(to: client.baseURL) else { return nil }
        return .session(cookie: cookie.value)
    }

    /// Runs `op` as the active account. A 403 is probed: in account mode a
    /// dead session (`/auth/me` 403 too) signs in again ONCE, silently — one
    /// sign-in shared by concurrent callers — and `op` is retried once;
    /// anything else surfaces the 403. Whatever `op` returns or throws, if the
    /// account changed meanwhile the caller gets a `CancellationError` and
    /// must write and show nothing.
    func perform<T: Sendable>(_ op: @Sendable (SeerrClient, SeerrCredential) async throws -> T) async throws -> T {
        guard let snapshot = snapshot(), let client, let credential = credential() else {
            throw SeerrError.unreachable
        }
        do {
            let answer: T
            do {
                answer = try await op(client, credential)
            } catch SeerrError.forbidden {
                let renewed = try await recoverFromForbidden(client: client, credential: credential, snapshot: snapshot)
                answer = try await op(client, renewed)
            }
            guard isCurrent(snapshot) else { throw CancellationError() }
            return answer
        } catch {
            // An answer — or a failure — of an account the app has left is
            // nobody's to show.
            guard isCurrent(snapshot) else { throw CancellationError() }
            throw error
        }
    }

    /// The probe after a 403. Returns the credential to retry with — only
    /// after a silent sign-in — or throws.
    private func recoverFromForbidden(
        client: SeerrClient, credential: SeerrCredential, snapshot: Snapshot
    ) async throws -> SeerrCredential {
        switch credential {
        case .apiKey(let key, _):
            // Without `X-API-User`: 403 ⇒ the key itself is refused, 404 ⇒ not
            // linked, 200 ⇒ a genuine refusal. Never a retry.
            guard let jellyfinUserId else { throw SeerrError.forbidden }
            let next: Connection?
            do {
                next = try await client.user(forJellyfinUserId: jellyfinUserId, auth: .adminKey(key))
                    .map(Connection.connected) ?? .notLinked
            } catch SeerrError.forbidden {
                next = .keyRefused
            } catch {
                next = nil
            }
            guard isCurrent(snapshot) else { throw CancellationError() }
            if let next { setConnection(next) }
            throw SeerrError.forbidden

        case .session(let deadCookie):
            let probe: Result<SeerrUser, any Error>
            do {
                probe = .success(try await client.me(credential))
            } catch {
                probe = .failure(error)
            }
            guard isCurrent(snapshot) else { throw CancellationError() }
            switch probe {
            case .success(let user):
                setConnection(.connected(user))
                throw SeerrError.forbidden
            case .failure(let error as SeerrError) where error == .forbidden:
                break   // the session is dead
            case .failure(let error) where error is CancellationError:
                throw CancellationError()
            case .failure:
                throw SeerrError.forbidden
            }
            switch await reSignInOnce(client: client, deadCookie: deadCookie) {
            case .renewed(let fresh): return .session(cookie: fresh)
            case .failed: throw SeerrError.forbidden
            case .stale: throw CancellationError()
            }
        }
    }

    /// The silent sign-in after a dead session: ONE per generation, every
    /// concurrent caller awaits the same one. Only against the configured
    /// address, with this account's approver, and never from an HTTPS Jellyfin
    /// to a plain-HTTP Seerr (`SeerrAccess.downgradesFromHTTPS`: the dead
    /// session is given up, « Se connecter à Seerr » stays). Its outcome is
    /// written here; a failure never overwrites a fresher session (a manual
    /// sign-in that landed meanwhile).
    private func reSignInOnce(client: SeerrClient, deadCookie: String) async -> ReSignIn {
        guard let key = accountKey else { return .stale }
        if let cookie, cookie.value != deadCookie, cookie.isBound(to: client.baseURL) {
            return .renewed(cookie.value)   // a concurrent caller already renewed it
        }
        if let pending = pendingReSignIn, pending.ticket.generation == generation {
            return await pending.task.value
        }
        guard let approve, SeerrAddress.sameOrigin(client.baseURL, config?.url),
              !SeerrAccess.downgradesFromHTTPS(jellyfin: jellyfinURL, seerr: client.baseURL) else {
            abandonSession(deadCookie: deadCookie, for: key)
            return .failed
        }
        logger.notice("Seerr ▸ session expired, signing in again")
        reSignInCount &+= 1
        let ticket = ReSignInTicket(
            id: reSignInCount, generation: generation, accountKey: key, origin: client.baseURL, deadCookie: deadCookie)
        let signIn = SeerrQuickConnectSignIn(client: client, approve: approve, pause: signInPause)
        let task = Task { [weak self] () -> ReSignIn in
            let outcome: Result<(cookie: String, user: SeerrUser), SeerrSignInError>
            do throws(SeerrSignInError) {
                outcome = .success(try await signIn.run())
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return .stale }
            return self.finishReSignIn(outcome, ticket: ticket)
        }
        pendingReSignIn = PendingReSignIn(ticket: ticket, task: task)
        return await task.value
    }

    private func finishReSignIn(
        _ outcome: Result<(cookie: String, user: SeerrUser), SeerrSignInError>, ticket: ReSignInTicket
    ) -> ReSignIn {
        if pendingReSignIn?.ticket.id == ticket.id { pendingReSignIn = nil }
        guard ticket.generation == generation, ticket.accountKey == accountKey else { return .stale }
        // The mode or the saved address moved while the sign-in ran: it no
        // longer describes the connection, so it writes nothing.
        guard !usesDeviceKey, SeerrAddress.sameOrigin(ticket.origin, client?.baseURL) else { return .stale }
        switch outcome {
        case .success(let signedIn):
            storeCookie(SeerrBoundSecret(value: signedIn.cookie, origin: ticket.origin), for: ticket.accountKey)
            setConnection(.connected(signedIn.user))
            return .renewed(signedIn.cookie)
        case .failure(.cancelled):
            return .stale
        case .failure(let error):
            logger.notice("Seerr ▸ silent sign-in failed: \(String(describing: error), privacy: .public)")
            abandonSession(deadCookie: ticket.deadCookie, for: ticket.accountKey)
            return .failed
        }
    }

    /// The dead session is given up — cookie dropped, « Se connecter à
    /// Seerr » — unless a fresher one landed meanwhile, which stands.
    private func abandonSession(deadCookie: String, for key: String) {
        guard cookie == nil || cookie?.value == deadCookie else { return }
        dropCookie(deadCookie, for: key)
        setConnection(.notConnected)
    }

    // MARK: Sign in / out, device key

    /// A throwaway client for the connection test: the TYPED address, this
    /// session's transport and language, nothing saved.
    func makeTestClient(for address: URL) -> SeerrClient {
        SeerrClient(baseURL: address, languageCode: languageCode, transport: transport)
    }

    /// The one-gesture sign-in against `address` — the SAVED address from
    /// Settings and search, the TYPED one from the connection test. The cookie
    /// is always stored under the active account, bound to `address`; the
    /// connection only moves to `.connected` when `address` is the saved one
    /// (the test may sign in before saving). `.cancelled` — or no account, a
    /// capped one, no Pro, a switch midway — changes nothing.
    func signIn(address: URL, appState: AppState) async -> Result<SeerrUser, SeerrSignInError> {
        guard let key = appState.activeAccountKey, key == accountKey, proAllowsProvider(),
              let snapshot = snapshot(), !isAgeCapped else {
            return .failure(.cancelled)
        }
        let target = SeerrAddress.sameOrigin(client?.baseURL, address)
            ? client
            : SeerrClient(baseURL: address, languageCode: languageCode, transport: transport)
        guard let target else { return .failure(.cancelled) }
        let signIn = SeerrQuickConnectSignIn(
            client: target, approve: Self.makeApprover(appState: appState, accountKey: key), pause: signInPause)
        let signedIn: (cookie: String, user: SeerrUser)
        do {
            signedIn = try await signIn.run()
        } catch {
            if error != .cancelled {
                logger.notice("Seerr ▸ sign-in failed: \(String(describing: error), privacy: .public)")
            }
            return .failure(error)
        }
        guard isCurrent(snapshot), appState.activeAccountKey == key else { return .failure(.cancelled) }
        storeCookie(SeerrBoundSecret(value: signedIn.cookie, origin: target.baseURL), for: key)
        if !usesDeviceKey {
            if let config, SeerrAddress.sameOrigin(address, config.url),
               Self.resolvesIdentity(config, isAdmin: appState.isAdministrator) {
                setConnection(.connected(signedIn.user))
            } else if case .connected = connection {
                // The saved address's session was replaced by another address's.
                setConnection(.notConnected)
            }
        }
        return .success(signedIn.user)
    }

    /// « Se connecter à Seerr » — from Settings → Demandes and from the
    /// search screen's invitation — toward the SAVED address only. Quick
    /// Connect is probed first: without it, Jellyfin's refusal would read as
    /// a device one (and a probe that does not get through says nothing about
    /// Quick Connect). `nil` = signed in, or nothing to say (cancelled).
    func signInToSavedAddress(appState: AppState) async -> SeerrTestFailure? {
        guard let address = config?.url else { return nil }
        let quickConnectOn: Bool
        do {
            quickConnectOn = try await appState.apiClient.isQuickConnectEnabled()
        } catch {
            return .unreachable
        }
        guard quickConnectOn else { return .quickConnectOff }
        if case .failure(let error) = await signIn(address: address, appState: appState) {
            return SeerrAccess.signInFailure(error, policy: appState.currentUser?.policy)
        }
        return nil
    }

    /// « Se déconnecter »: the cookie goes first, then Seerr is told (best
    /// effort — a failed logout changes nothing the user can act on), and only
    /// the Seerr that issued it.
    func signOut() async {
        guard servesActiveAccount, let key = accountKey else { return }
        let signedOut = cookie ?? storage.seerrSessions()[key]
        dropCookie(nil, for: key)
        if !usesDeviceKey, client != nil { setConnection(.notConnected) }
        if let signedOut, let client, signedOut.isBound(to: client.baseURL), !isAgeCapped, proAllowsProvider() {
            await client.logout(cookie: signedOut.value)
        }
    }

    /// An administrator writes (or removes, for `nil` / blank) this device's
    /// API key for the active server, bound to the Seerr `address` it was
    /// entered for, then the identity is re-read in the new mode. A key with
    /// no address is never stored (it could not be bound); removing needs none.
    func setDeviceKey(_ key: String?, address: URL?, appState: AppState) async {
        guard appState.isAdministrator, let serverId = appState.activeServerId else { return }
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var keys = storage.seerrAPIKeys()
        if trimmed.isEmpty {
            keys.removeValue(forKey: serverId)
        } else {
            guard let address else { return }
            let origin = SeerrAddress.normalize(address.absoluteString) ?? address
            keys[serverId] = SeerrBoundSecret(value: trimmed, origin: origin)
        }
        storage.saveSeerrAPIKeys(keys)
        await reload(appState: appState)
    }

    /// Whether this device holds an API key for the active server — bound to
    /// the saved address or not: Settings shows « Clé enregistrée » for it, so
    /// a key entered for an address since changed can still be removed.
    func hasStoredDeviceKey(appState: AppState) -> Bool {
        storedDeviceKeyOrigin(appState: appState) != nil
    }

    /// The Seerr address this device's key was entered for (not a secret):
    /// Settings says when it is not the saved one, i.e. the key is unused.
    func storedDeviceKeyOrigin(appState: AppState) -> URL? {
        storedDeviceKey(appState: appState).flatMap { URL(string: $0.origin) }
    }

    /// The stored key, lent to « Tester la connexion » — only to an
    /// administrator and only toward the address it was entered for. Passed
    /// straight to the test, never displayed.
    func deviceKeyForTest(address: URL, appState: AppState) -> String? {
        guard appState.isAdministrator, let stored = storedDeviceKey(appState: appState),
              stored.isBound(to: address) else { return nil }
        return stored.value
    }

    private func storedDeviceKey(appState: AppState) -> SeerrBoundSecret? {
        guard let serverId = appState.activeServerId,
              let stored = storage.seerrAPIKeys()[serverId], !stored.value.isEmpty else { return nil }
        return stored
    }

    /// An account left this device for good (`AppState.onAccountForgotten`):
    /// its cookie goes, and so does what this device remembered for it — the
    /// arrivals already seen and the dismissed search invitation — so the
    /// account added back starts afresh (its first arrival check seeds again,
    /// in silence).
    func forgetAccount(_ accountKey: String) {
        dropCookie(nil, for: accountKey)
        defaults.removeObject(forKey: SettingsKey.seerrArrivalsSeen(accountKey: accountKey))
        defaults.removeObject(forKey: SettingsKey.seerrSearchPromptDismissed(accountKey: accountKey))
    }

    /// A server was removed (`AppState.onServerForgotten`): its device key goes.
    func forgetServer(_ serverId: String) {
        var keys = storage.seerrAPIKeys()
        guard keys.removeValue(forKey: serverId) != nil else { return }
        storage.saveSeerrAPIKeys(keys)
    }

    // MARK: Render gates

    /// Whether a browse surface shows its Seerr part — read at RENDER, every
    /// input re-evaluated (account, Pro, cap, configuration, network,
    /// connection).
    func isVisible(proAllows: Bool, isOnline: Bool) -> Bool {
        guard servesActiveAccount,
              SeerrAccess.showsBrowse(proAllows: proAllows, ageCapped: isAgeCapped, config: config, isOnline: isOnline),
              case .connected = connection else { return false }
        return true
    }

    /// « Se connecter à Seerr » in place of the section: account mode only.
    func showsConnectPrompt(proAllows: Bool, isOnline: Bool) -> Bool {
        servesActiveAccount
            && SeerrAccess.showsBrowse(proAllows: proAllows, ageCapped: isAgeCapped, config: config, isOnline: isOnline)
            && !usesDeviceKey && connection == .notConnected
    }

    // MARK: Internals

    /// The approval of a Quick Connect code on JELLYFIN, with the user's token.
    /// `appState.apiClient` is ONE client repointed in place by every switch,
    /// so the approval first checks — on the main actor, where `reconnect` and
    /// `currentUserId` move together — that the app is still on the account
    /// it was built for: otherwise it would mint a Seerr session with the
    /// NEXT profile's token (a child's, typically).
    private static func makeApprover(
        appState: AppState, accountKey: String
    ) -> @Sendable (String) async throws -> Bool {
        let api = appState.apiClient
        return { [weak appState] code in
            let stillActive = await MainActor.run { appState?.activeAccountKey == accountKey }
            guard stillActive else { throw CancellationError() }
            return try await api.authorizeQuickConnect(code: code)
        }
    }

    private func forgetIdentity(keepingConfig: Bool) {
        if !keepingConfig, config != nil { config = nil }
        // No identity, no count: a number kept here would come back unread.
        if pendingCount != nil { pendingCount = nil }
        client = nil
        cookie = nil
        deviceKey = nil
        setConnection(.unavailable)
        if publicSettings != nil { publicSettings = nil }
        if usesDeviceKey { usesDeviceKey = false }
    }

    private func setConnection(_ new: Connection) {
        if connection != new { connection = new }
    }

    private func setPolicyCapped(_ capped: Bool) {
        if policyCapped != capped { policyCapped = capped }
    }

    private func storeCookie(_ secret: SeerrBoundSecret, for key: String) {
        var sessions = storage.seerrSessions()
        sessions[key] = secret
        storage.saveSeerrSessions(sessions)
        if key == accountKey { cookie = secret }
    }

    /// Removes `key`'s cookie — only if it is still `expected` when one is
    /// given, so a dead cookie's cleanup cannot erase the fresh one a
    /// concurrent sign-in just stored.
    private func dropCookie(_ expected: String?, for key: String) {
        var sessions = storage.seerrSessions()
        guard let stored = sessions[key], expected == nil || stored.value == expected else { return }
        sessions.removeValue(forKey: key)
        storage.saveSeerrSessions(sessions)
        if key == accountKey { cookie = nil }
    }
}
