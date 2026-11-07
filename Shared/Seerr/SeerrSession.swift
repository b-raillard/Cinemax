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
/// Three invariants, in order of importance:
/// 1. **Fail closed.** An account whose policy is not known yet, or that is
///    capped by age (server policy OR this device's `privacy.maxContentAge`),
///    makes no Seerr call at all — not from `reload`, not through `perform`,
///    not through `signIn`. The device half of the cap is re-read live, so a
///    cap set while connected hides everything at the next render.
/// 2. **No answer crosses accounts.** Everything is keyed to `accountKey` and
///    a `generation` bumped by `reset()` — synchronously, on the account
///    change, and again at the head of `reload` before its first `await`.
///    Every write after an `await` is dropped once the generation moved, and a
///    screen's own load does the same through `snapshot()` / `isCurrent(_:)`.
/// 3. **A 403 is probed before it is believed** (spec, § Spike findings 2):
///    Seerr answers a dead session, a refused key and a genuine refusal alike.
@MainActor @Observable
final class SeerrSession {
    enum Connection: Equatable {
        /// Not known, or not applicable (capped, disabled, no address, offline
        /// before the first answer). Nothing Seerr renders.
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
    /// This device holds an API key for the active server: every profile goes
    /// through it (`X-API-User`), the account mode's cookie is not used.
    private(set) var usesDeviceKey = false
    /// The server half of the cap, as of the last `reload` (`true` until the
    /// policy is known).
    private var policyCapped = true

    /// Capped by age — the server policy, or this device's setting read LIVE.
    var isAgeCapped: Bool {
        policyCapped || defaults.integer(forKey: SettingsKey.privacyMaxContentAge) > 0
    }

    // MARK: Identity (not observed)

    @ObservationIgnored private(set) var client: SeerrClient?
    @ObservationIgnored private var generation = 0
    /// Bumped by every `reload`, never by `reset`: two reloads of the SAME
    /// account (foreground + a `UserUpdated` frame) cannot leave the older
    /// answer last. Invisible to `Snapshot`, so screens are not disturbed.
    @ObservationIgnored private var reloadPass = 0
    @ObservationIgnored private var accountKey: String?
    @ObservationIgnored private var jellyfinUserId: String?
    @ObservationIgnored private var cookie: String?
    @ObservationIgnored private var deviceKey: String?
    @ObservationIgnored private var approve: (@Sendable (String) async throws -> Bool)?
    @ObservationIgnored private var languageCode: String?

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
    /// account precisely so that they survive a switch. Synchronous.
    func reset() {
        generation &+= 1
        accountKey = nil
        jellyfinUserId = nil
        cookie = nil
        deviceKey = nil
        approve = nil
        client = nil
        config = nil
        connection = .unavailable
        publicSettings = nil
        usesDeviceKey = false
        policyCapped = true
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
    /// `UserUpdated`). The SAME account keeps its generation and its state
    /// until a new answer replaces it — no flicker on every return to the app.
    func reload(appState: AppState) async {
        let key = appState.activeAccountKey
        accountDidChange(to: key)
        guard let key, let userId = appState.currentUserId, let serverId = appState.activeServerId else { return }
        accountKey = key
        jellyfinUserId = userId
        reloadPass &+= 1
        let pass = (generation: generation, reload: reloadPass)
        approve = Self.makeApprover(appState: appState, accountKey: key)

        // The policy first, and an unknown one is a cap: nothing is read for a
        // capped account — not even its configuration.
        let policy = appState.currentUser.flatMap { $0.id == userId ? $0.policy : nil }
        let known = appState.currentUser?.id == userId
        setPolicyCapped(!known || SeerrAccess.isAgeCapped(deviceMaxAge: 0, policy: policy))
        guard !isAgeCapped else {
            forgetIdentity(keepingConfig: false)
            return
        }

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
        guard fresh.isEnabled, let url = fresh.url else {
            forgetIdentity(keepingConfig: true)
            return
        }
        guard appState.isOnlineProvider() else { return }

        if client?.baseURL != url {
            client = SeerrClient(baseURL: url, languageCode: languageCode, transport: transport)
            setConnection(.unavailable)
            if publicSettings != nil { publicSettings = nil }
        }
        guard let client else { return }
        let storedKey = storage.seerrAPIKeys()[serverId].flatMap { $0.isEmpty ? nil : $0 }
        if (storedKey != nil) != usesDeviceKey {
            usesDeviceKey = storedKey != nil
            setConnection(.unavailable)
        }
        deviceKey = storedKey
        cookie = storage.seerrSessions()[key]

        let settings: SeerrPublicSettings
        do {
            settings = try await client.publicSettings()
        } catch {
            return
        }
        guard isLive(pass) else { return }
        if publicSettings != settings { publicSettings = settings }

        if let storedKey {
            await resolveByKey(storedKey, jellyfinUserId: userId, client: client, pass: pass)
        } else if let cookie {
            await resolveBySession(cookie, accountKey: key, client: client, pass: pass)
        } else {
            setConnection(.notConnected)
        }
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

    private func resolveBySession(_ cookie: String, accountKey key: String, client: SeerrClient,
                                  pass: (generation: Int, reload: Int)) async {
        do {
            let user = try await client.me(.session(cookie: cookie))
            guard isLive(pass) else { return }
            setConnection(.connected(user))
        } catch SeerrError.forbidden {
            // `/auth/me` refusing IS the dead-session probe.
            guard isLive(pass) else { return }
            logger.notice("Seerr ▸ stored session expired")
            dropCookie(cookie, for: key)
            setConnection(.notConnected)
        } catch {
            // A blip: the last known state stands.
        }
    }

    // MARK: Stale-answer token

    func snapshot() -> Snapshot? {
        accountKey.map { Snapshot(accountKey: $0, generation: generation) }
    }

    func isCurrent(_ snapshot: Snapshot) -> Bool {
        snapshot.generation == generation && snapshot.accountKey == accountKey
    }

    private func isLive(_ pass: (generation: Int, reload: Int)) -> Bool {
        pass.generation == generation && pass.reload == reloadPass
    }

    // MARK: Calls

    /// How the active account is authenticated right now, `nil` when it is not
    /// (capped, not connected, not linked, key refused).
    func credential() -> SeerrCredential? {
        guard !isAgeCapped, case .connected(let user) = connection else { return nil }
        if usesDeviceKey {
            return deviceKey.map { SeerrCredential.apiKey(key: $0, user: user.id) }
        }
        return cookie.map { SeerrCredential.session(cookie: $0) }
    }

    /// Runs `op` as the active account. A 403 is probed: in account mode a
    /// dead session (`/auth/me` 403 too) signs in again ONCE, silently, and
    /// `op` is retried once; anything else surfaces the 403. Throws
    /// `CancellationError` when the account changed under the call — the
    /// caller then writes nothing.
    func perform<T: Sendable>(_ op: @Sendable (SeerrClient, SeerrCredential) async throws -> T) async throws -> T {
        guard let snapshot = snapshot(), let client, let credential = credential() else {
            throw SeerrError.unreachable
        }
        do {
            return try await op(client, credential)
        } catch SeerrError.forbidden {
            let renewed = try await recoverFromForbidden(client: client, credential: credential, snapshot: snapshot)
            return try await op(client, renewed)
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
            let sessionIsDead: Bool
            do {
                let user = try await client.me(credential)
                guard isCurrent(snapshot) else { throw CancellationError() }
                setConnection(.connected(user))
                sessionIsDead = false
            } catch SeerrError.forbidden {
                sessionIsDead = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                sessionIsDead = false
            }
            guard isCurrent(snapshot) else { throw CancellationError() }
            guard sessionIsDead else { throw SeerrError.forbidden }
            return try await signInSilently(client: client, deadCookie: deadCookie, snapshot: snapshot)
        }
    }

    private func signInSilently(
        client: SeerrClient, deadCookie: String, snapshot: Snapshot
    ) async throws -> SeerrCredential {
        // Only against the configured address, with this account's approver.
        guard let approve, client.baseURL == config?.url else {
            dropCookie(deadCookie, for: snapshot.accountKey)
            setConnection(.notConnected)
            throw SeerrError.forbidden
        }
        logger.notice("Seerr ▸ session expired, signing in again")
        let signIn = SeerrQuickConnectSignIn(client: client, approve: approve, pause: signInPause)
        let outcome: Result<(cookie: String, user: SeerrUser), SeerrSignInError>
        do {
            outcome = .success(try await signIn.run())
        } catch {
            outcome = .failure(error)
        }
        guard isCurrent(snapshot) else { throw CancellationError() }
        switch outcome {
        case .success(let signedIn):
            storeCookie(signedIn.cookie, for: snapshot.accountKey)
            setConnection(.connected(signedIn.user))
            return .session(cookie: signedIn.cookie)
        case .failure(.cancelled):
            throw CancellationError()
        case .failure(let error):
            logger.notice("Seerr ▸ silent sign-in failed: \(String(describing: error), privacy: .public)")
            dropCookie(deadCookie, for: snapshot.accountKey)
            setConnection(.notConnected)
            throw SeerrError.forbidden
        }
    }

    // MARK: Sign in / out, device key

    /// The one-gesture sign-in against `address` — the SAVED address from
    /// Settings and search, the TYPED one from the connection test. The cookie
    /// is always stored under the active account; the connection only moves
    /// when `address` is the saved one (the test may sign in before saving).
    /// `.cancelled` — or no account, a capped one, a switch midway — changes
    /// nothing.
    func signIn(address: URL, appState: AppState) async -> Result<SeerrUser, SeerrSignInError> {
        guard let key = appState.activeAccountKey, key == accountKey,
              let snapshot = snapshot(), !isAgeCapped else {
            return .failure(.cancelled)
        }
        let target = client?.baseURL == address
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
        storeCookie(signedIn.cookie, for: key)
        if !usesDeviceKey, config?.isEnabled == true, address == config?.url {
            setConnection(.connected(signedIn.user))
        }
        return .success(signedIn.user)
    }

    /// « Se déconnecter »: the cookie goes first, then Seerr is told (best
    /// effort — a failed logout changes nothing the user can act on).
    func signOut() async {
        guard let key = accountKey else { return }
        let signedOut = cookie ?? storage.seerrSessions()[key]
        dropCookie(nil, for: key)
        if !usesDeviceKey, client != nil { setConnection(.notConnected) }
        if let signedOut, let client, !isAgeCapped {
            await client.logout(cookie: signedOut)
        }
    }

    /// Writes (or removes, for `nil` / blank) this device's API key for the
    /// active server, then re-reads the identity in the new mode.
    func setDeviceKey(_ key: String?, appState: AppState) async {
        guard let serverId = appState.activeServerId else { return }
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var keys = storage.seerrAPIKeys()
        if trimmed.isEmpty { keys.removeValue(forKey: serverId) } else { keys[serverId] = trimmed }
        storage.saveSeerrAPIKeys(keys)
        await reload(appState: appState)
    }

    /// An account left this device for good (`AppState.onAccountForgotten`).
    func forgetAccount(_ accountKey: String) {
        dropCookie(nil, for: accountKey)
    }

    /// A server was removed (`AppState.onServerForgotten`): its device key goes.
    func forgetServer(_ serverId: String) {
        var keys = storage.seerrAPIKeys()
        guard keys.removeValue(forKey: serverId) != nil else { return }
        storage.saveSeerrAPIKeys(keys)
    }

    // MARK: Render gates

    /// Whether a browse surface shows its Seerr part — read at RENDER, every
    /// input re-evaluated (Pro, cap, configuration, network, connection).
    func isVisible(proAllows: Bool, isOnline: Bool) -> Bool {
        guard SeerrAccess.showsBrowse(proAllows: proAllows, ageCapped: isAgeCapped, config: config, isOnline: isOnline),
              case .connected = connection else { return false }
        return true
    }

    /// « Se connecter à Seerr » in place of the section: account mode only.
    func showsConnectPrompt(proAllows: Bool, isOnline: Bool) -> Bool {
        SeerrAccess.showsBrowse(proAllows: proAllows, ageCapped: isAgeCapped, config: config, isOnline: isOnline)
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

    private func storeCookie(_ value: String, for key: String) {
        var sessions = storage.seerrSessions()
        sessions[key] = value
        storage.saveSeerrSessions(sessions)
        if key == accountKey { cookie = value }
    }

    /// Removes `key`'s cookie — only if it is still `expected` when one is
    /// given, so a dead cookie's cleanup cannot erase the fresh one a
    /// concurrent sign-in just stored.
    private func dropCookie(_ expected: String?, for key: String) {
        var sessions = storage.seerrSessions()
        guard let stored = sessions[key], expected == nil || stored == expected else { return }
        sessions.removeValue(forKey: key)
        storage.saveSeerrSessions(sessions)
        if key == accountKey { cookie = nil }
    }
}
