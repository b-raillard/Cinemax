import Foundation
import Observation
import Testing
import JellyfinAPI
@testable import CinemaxKit
@testable import Cinemax

// MARK: - Fixtures

private let jellyfinURL = URL(string: "https://maison.local")!
private let seerrURL = URL(string: "http://192.168.1.20:5055")!
private let enabledConfig = SeerrUserConfig(isEnabled: true, url: seerrURL)
private let prefsKey = "me|\(SeerrUserConfig.preferencesId)|\(SeerrUserConfig.client)"

private let settingsReply = StubSeerrTransport.Reply.response(
    status: 200, body: #"{"mediaServerType":2,"partialRequestsEnabled":true}"#)
private let forbiddenReply = StubSeerrTransport.Reply.response(
    status: 403, body: #"{"error":"You do not have permission to access this endpoint"}"#)
private let notFoundReply = StubSeerrTransport.Reply.response(status: 404, body: #"{"message":"Not found"}"#)
private let searchReply = StubSeerrTransport.Reply.response(
    status: 200, body: #"{"page":1,"totalPages":1,"totalResults":0,"results":[]}"#)
private let initiatedReply = StubSeerrTransport.Reply.response(status: 200, body: #"{"code":"123456","secret":"s"}"#)
private let approvedReply = StubSeerrTransport.Reply.response(status: 200, body: #"{"authenticated":true}"#)

private let aliceJSON = #"{"id":7,"permissions":32,"jellyfinUserId":"A","displayName":"Alice"}"#
private let bobJSON = #"{"id":8,"permissions":32,"jellyfinUserId":"B","displayName":"Bob"}"#
private let alice = SeerrUser(id: SeerrUserID(rawValue: 7), permissions: .request, jellyfinUserId: "A", displayName: "Alice")
private let bob = SeerrUser(id: SeerrUserID(rawValue: 8), permissions: .request, jellyfinUserId: "B", displayName: "Bob")

private func userReply(_ json: String = aliceJSON) -> StubSeerrTransport.Reply {
    .response(status: 200, body: json)
}

private func authenticatedReply(cookie: String) -> StubSeerrTransport.Reply {
    .response(status: 200, headers: ["Set-Cookie": "connect.sid=\(cookie); Path=/; HttpOnly"], body: aliceJSON)
}

private func policy(maxRating: Int? = nil) -> UserPolicy {
    var policy = UserPolicy(authenticationProviderID: "", passwordResetProviderID: "")
    policy.maxParentalRating = maxRating
    return policy
}

/// Fires once on the first mutation of whatever the tracking closure read.
private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var didFire = false
    var fired: Bool { lock.withLock { didFire } }
    func fire() { lock.withLock { didFire = true } }
}

/// Signed in on server `S1` as `userId`, with the Seerr configuration `config`
/// stored in that user's DisplayPreferences (`nil` = never configured).
/// `knownUser: false` leaves `currentUser` unfetched — the policy unknown.
@MainActor
private func signedIn(
    userId: String = "A",
    policy userPolicy: UserPolicy? = policy(),
    knownUser: Bool = true,
    config: SeerrUserConfig? = enabledConfig,
    api: MockAPIClient = MockAPIClient()
) -> (AppState, MockAPIClient) {
    if let config {
        api.displayPreferences[prefsKey] = SeerrUserConfig.merged(config, into: nil)
    }
    let keychain = MockKeychain()
    keychain.savedServers = [ServerEntry(
        id: "S1", name: "Maison", url: jellyfinURL, serverID: "srv",
        accessToken: "tok\(userId)", userId: userId, username: userId,
        lastUsedAt: Date(timeIntervalSince1970: 1_000))]
    keychain.savedActiveServerId = "S1"
    let app = AppState(apiClient: api, keychain: keychain)
    app.settingsDefaults = .isolatedForTesting()
    app.loadServersFromKeychain()
    app.serverURL = jellyfinURL
    app.hasServer = true
    app.isAuthenticated = true
    app.accessToken = "tok\(userId)"
    app.currentUserId = userId
    if knownUser {
        var user = UserDto()
        user.id = userId
        user.policy = userPolicy
        app.currentUser = user
    }
    return (app, api)
}

@MainActor
private func makeSession(
    _ stub: StubSeerrTransport,
    storage: MockKeychain = MockKeychain(),
    defaults: UserDefaults = .isolatedForTesting()
) -> SeerrSession {
    SeerrSession(storage: storage, defaults: defaults, transport: stub, signInPause: {})
}

private func search(_ client: SeerrClient, _ credential: SeerrCredential) async throws -> [SeerrTitle] {
    try await client.search("dune", credential)
}

// MARK: - Suite

@MainActor
@Suite("Seerr session")
struct SeerrSessionTests {

    // MARK: Fail closed

    @Test("a server age cap makes no Seerr call, through any entry point")
    func cappedAccountMakesNoSeerrCall() async {
        let stub = StubSeerrTransport()
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "abc"])
        let session = makeSession(stub, storage: storage)
        let (app, _) = signedIn(policy: policy(maxRating: 10))

        await session.reload(appState: app)

        #expect(session.isAgeCapped)
        #expect(session.connection == .unavailable)
        #expect(session.credential() == nil)
        #expect(!session.isVisible(proAllows: true, isOnline: true))
        await #expect(throws: (any Error).self) { try await session.perform(search) }
        #expect(await session.signIn(address: seerrURL, appState: app) == .failure(.cancelled))
        #expect(stub.requests.isEmpty)
    }

    @Test("a device age cap makes no Seerr call")
    func deviceCapMakesNoSeerrCall() async {
        let stub = StubSeerrTransport()
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set(12, forKey: SettingsKey.privacyMaxContentAge)
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "abc"])
        let session = makeSession(stub, storage: storage, defaults: defaults)
        let (app, _) = signedIn()

        await session.reload(appState: app)

        #expect(session.isAgeCapped)
        #expect(session.connection == .unavailable)
        #expect(stub.requests.isEmpty)
    }

    @Test("a device cap set while connected hides Seerr at once, before any reload")
    func deviceCapAppliesWithoutReload() async {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let defaults = UserDefaults.isolatedForTesting()
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "abc"])
        let session = makeSession(stub, storage: storage, defaults: defaults)
        let (app, _) = signedIn()
        await session.reload(appState: app)
        #expect(session.isVisible(proAllows: true, isOnline: true))

        defaults.set(10, forKey: SettingsKey.privacyMaxContentAge)

        #expect(session.isAgeCapped)
        #expect(!session.isVisible(proAllows: true, isOnline: true))
        #expect(session.credential() == nil)
        await #expect(throws: (any Error).self) { try await session.perform(search) }
        #expect(stub.requests.count == 2)
    }

    @Test("a disabled configuration, or one without an address, makes no Seerr call")
    func disabledMakesNoSeerrCall() async {
        let stub = StubSeerrTransport()
        let session = makeSession(stub)
        let disabled = SeerrUserConfig(isEnabled: false, url: seerrURL)
        let (app, _) = signedIn(config: disabled)

        await session.reload(appState: app)

        #expect(session.config == disabled)
        #expect(session.connection == .unavailable)
        #expect(!session.isVisible(proAllows: true, isOnline: true))

        let (noAddress, _) = signedIn(userId: "B", config: SeerrUserConfig(isEnabled: true, url: nil))
        await session.reload(appState: noAddress)

        #expect(session.connection == .unavailable)
        #expect(stub.requests.isEmpty)
    }

    @Test("an unknown policy (user not fetched yet) is a cap: no Seerr call")
    func policyUnknownIsCapped() async {
        let stub = StubSeerrTransport()
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "abc"])
        let session = makeSession(stub, storage: storage)
        let (app, _) = signedIn(knownUser: false)

        await session.reload(appState: app)

        #expect(session.isAgeCapped)
        #expect(session.connection == .unavailable)

        // A cached record belonging to ANOTHER account is no better.
        var someoneElse = UserDto()
        someoneElse.id = "Z"
        someoneElse.policy = policy()
        app.currentUser = someoneElse
        await session.reload(appState: app)

        #expect(session.isAgeCapped)
        #expect(stub.requests.isEmpty)
    }

    // MARK: Identity

    @Test("a stored cookie answered by /auth/me restores the connection")
    func cookieRestoresConnection() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "abc"])
        let session = makeSession(stub, storage: storage)
        let (app, _) = signedIn()

        await session.reload(appState: app)

        #expect(session.connection == .connected(alice))
        #expect(session.credential() == .session(cookie: "abc"))
        #expect(!session.usesDeviceKey)
        #expect(session.publicSettings?.isJellyfin == true)
        #expect(session.isVisible(proAllows: true, isOnline: true))
        #expect(!session.isVisible(proAllows: false, isOnline: true))
        #expect(!session.isVisible(proAllows: true, isOnline: false))
        let me = try #require(stub.requests.last)
        #expect(me.url?.path == "/api/v1/auth/me")
        #expect(me.value(forHTTPHeaderField: "Cookie")?.contains("connect.sid=abc") == true)
        #expect(!stub.exhausted)
    }

    @Test("a cookie /auth/me refuses is dropped and the account is not connected")
    func deadCookieAtReloadIsDropped() async {
        let stub = StubSeerrTransport([settingsReply, forbiddenReply])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "dead", "S1|B": "bob"])
        let session = makeSession(stub, storage: storage)
        let (app, api) = signedIn()

        await session.reload(appState: app)

        #expect(session.connection == .notConnected)
        #expect(storage.seerrSessions() == ["S1|B": "bob"])
        #expect(api.authorizeQuickConnectCalls.isEmpty)
    }

    @Test("an unreachable Seerr keeps the last known connection of the same account")
    func blipKeepsConnection() async {
        let stub = StubSeerrTransport([settingsReply, userReply(), .failure(URLError(.timedOut))])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "abc"])
        let session = makeSession(stub, storage: storage)
        let (app, _) = signedIn()
        await session.reload(appState: app)

        await session.reload(appState: app)

        #expect(session.connection == .connected(alice))
        #expect(storage.seerrSessions()["S1|A"] == "abc")
    }

    @Test("the device key resolves the Seerr user; a 404 is « not linked »")
    func deviceKeyResolvesUser() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrAPIKeys(["S1": "KEY"])
        storage.saveSeerrSessions(["S1|A": "abc"])
        let session = makeSession(stub, storage: storage)
        let (app, _) = signedIn()

        await session.reload(appState: app)

        #expect(session.connection == .connected(alice))
        #expect(session.usesDeviceKey)
        #expect(session.credential() == .apiKey(key: "KEY", user: SeerrUserID(rawValue: 7)))
        let lookup = try #require(stub.requests.last)
        #expect(lookup.url?.path == "/api/v1/user/jellyfin/A")
        #expect(lookup.value(forHTTPHeaderField: "X-Api-Key") == "KEY")
        #expect(lookup.value(forHTTPHeaderField: "X-API-User") == nil)

        let notLinked = makeSession(StubSeerrTransport([settingsReply, notFoundReply]), storage: storage)
        await notLinked.reload(appState: app)

        #expect(notLinked.connection == .notLinked)
        #expect(notLinked.credential() == nil)
    }

    @Test("a device key Seerr refuses is « key refused »")
    func refusedDeviceKey() async {
        let storage = MockKeychain()
        storage.saveSeerrAPIKeys(["S1": "OLD"])
        let session = makeSession(StubSeerrTransport([settingsReply, forbiddenReply]), storage: storage)
        let (app, _) = signedIn()

        await session.reload(appState: app)

        #expect(session.connection == .keyRefused)
        #expect(session.credential() == nil)
        #expect(!session.showsConnectPrompt(proAllows: true, isOnline: true))
    }

    // MARK: perform — the 403 probe

    @Test("a dead session signs in again silently, once, then retries")
    func deadSessionReSignsInOnce() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "old"])
        let session = makeSession(stub, storage: storage)
        let (app, api) = signedIn()
        await session.reload(appState: app)
        for reply in [forbiddenReply, forbiddenReply, initiatedReply, approvedReply,
                      authenticatedReply(cookie: "fresh"), searchReply] {
            stub.enqueue(reply)
        }

        let results = try await session.perform(search)

        #expect(results.isEmpty)
        #expect(api.authorizeQuickConnectCalls == ["123456"])
        #expect(stub.requests[3].url?.path == "/api/v1/auth/me")
        #expect(stub.requests[3].value(forHTTPHeaderField: "Cookie")?.contains("connect.sid=old") == true)
        #expect(stub.requests.last?.value(forHTTPHeaderField: "Cookie")?.contains("connect.sid=fresh") == true)
        #expect(storage.seerrSessions()["S1|A"] == "fresh")
        #expect(session.credential() == .session(cookie: "fresh"))
        #expect(session.connection == .connected(alice))
        #expect(!stub.exhausted)
    }

    @Test("a silent sign-in that fails disconnects, drops the cookie and surfaces the error")
    func failedReSignInDisconnects() async {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "old"])
        let session = makeSession(stub, storage: storage)
        let (app, api) = signedIn()
        await session.reload(appState: app)
        api.stubbedAuthorizeQuickConnectResult = false
        for reply in [forbiddenReply, forbiddenReply, initiatedReply] { stub.enqueue(reply) }

        await #expect(throws: SeerrError.forbidden) { try await session.perform(search) }

        #expect(session.connection == .notConnected)
        #expect(storage.seerrSessions()["S1|A"] == nil)
        #expect(api.authorizeQuickConnectCalls.count == 1)
        #expect(stub.requests.count == 5)
        #expect(!stub.exhausted)
    }

    @Test("a 403 on the retry after a silent sign-in surfaces: no second sign-in")
    func forbiddenAfterReSignInSurfaces() async {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "old"])
        let session = makeSession(stub, storage: storage)
        let (app, api) = signedIn()
        await session.reload(appState: app)
        for reply in [forbiddenReply, forbiddenReply, initiatedReply, approvedReply,
                      authenticatedReply(cookie: "fresh"), forbiddenReply] {
            stub.enqueue(reply)
        }

        await #expect(throws: SeerrError.forbidden) { try await session.perform(search) }

        #expect(api.authorizeQuickConnectCalls.count == 1)
        #expect(stub.requests.count == 8)
        #expect(!stub.exhausted)
    }

    @Test("a genuine refusal (/auth/me still answers) does not sign in again")
    func genuineForbiddenDoesNotReSignIn() async {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "abc"])
        let session = makeSession(stub, storage: storage)
        let (app, api) = signedIn()
        await session.reload(appState: app)
        stub.enqueue(forbiddenReply)
        stub.enqueue(userReply())

        await #expect(throws: SeerrError.forbidden) { try await session.perform(search) }

        #expect(api.authorizeQuickConnectCalls.isEmpty)
        #expect(session.connection == .connected(alice))
        #expect(storage.seerrSessions()["S1|A"] == "abc")
        #expect(!stub.exhausted)
    }

    @Test("key mode: a refused key or an unlinked user surfaces the 403, never a retry")
    func keyModeProbeNeverRetries() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrAPIKeys(["S1": "KEY"])
        let session = makeSession(stub, storage: storage)
        let (app, api) = signedIn()
        await session.reload(appState: app)
        stub.enqueue(forbiddenReply)
        stub.enqueue(forbiddenReply)

        await #expect(throws: SeerrError.forbidden) { try await session.perform(search) }

        #expect(session.connection == .keyRefused)
        let probe = try #require(stub.requests.last)
        #expect(probe.url?.path == "/api/v1/user/jellyfin/A")
        #expect(probe.value(forHTTPHeaderField: "X-API-User") == nil)

        stub.enqueue(settingsReply)
        stub.enqueue(userReply())
        await session.reload(appState: app)
        stub.enqueue(forbiddenReply)
        stub.enqueue(notFoundReply)

        await #expect(throws: SeerrError.forbidden) { try await session.perform(search) }

        #expect(session.connection == .notLinked)
        #expect(api.authorizeQuickConnectCalls.isEmpty)
        #expect(!stub.exhausted)
    }

    // MARK: Generations

    @Test("reloading the same account keeps the generation and never blanks the state")
    func sameAccountReloadKeepsGenerationAndSections() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "abc"])
        let session = makeSession(stub, storage: storage)
        let (app, api) = signedIn()
        await session.reload(appState: app)
        let snapshot = try #require(session.snapshot())
        let started = TestLatch()
        let release = TestLatch()
        api.onGetDisplayPreferences = { started.open(); await release.wait() }
        stub.enqueue(settingsReply)
        stub.enqueue(userReply())
        let flag = ObservationFlag()
        withObservationTracking {
            _ = session.connection
            _ = session.config
            _ = session.isAgeCapped
        } onChange: {
            flag.fire()
        }

        let reload = Task { await session.reload(appState: app) }
        await started.wait()

        #expect(session.connection == .connected(alice))
        #expect(session.isCurrent(snapshot))
        release.open()
        await reload.value

        #expect(session.isCurrent(snapshot))
        #expect(session.connection == .connected(alice))
        #expect(!flag.fired)
        #expect(!stub.exhausted)
    }

    @Test("reloading ANOTHER account blanks everything before its first await")
    func reloadResetsBeforeFirstAwait() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "abc"])
        let session = makeSession(stub, storage: storage)
        let (admin, _) = signedIn()
        await session.reload(appState: admin)
        #expect(session.isVisible(proAllows: true, isOnline: true))
        let adminSnapshot = try #require(session.snapshot())

        let (child, childAPI) = signedIn(userId: "B")
        let started = TestLatch()
        let release = TestLatch()
        childAPI.onGetDisplayPreferences = { started.open(); await release.wait() }
        stub.enqueue(settingsReply)
        let reload = Task { await session.reload(appState: child) }
        await started.wait()

        #expect(session.connection == .unavailable)
        #expect(!session.isVisible(proAllows: true, isOnline: true))
        #expect(session.credential() == nil)
        #expect(session.config == nil)
        #expect(!session.isCurrent(adminSnapshot))
        #expect(session.snapshot()?.accountKey == "S1|B")
        release.open()
        await reload.value

        #expect(session.connection == .notConnected)
    }

    @Test("a late answer for the account left behind is dropped")
    func staleAnswerIsDropped() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply(bobJSON)])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "a", "S1|B": "b"])
        let session = makeSession(stub, storage: storage)
        let configA = SeerrUserConfig(isEnabled: true, url: URL(string: "http://seerr-a.local:5055"))
        let configB = SeerrUserConfig(isEnabled: true, url: URL(string: "http://seerr-b.local:5055"))
        let (appA, apiA) = signedIn(config: configA)
        let (appB, _) = signedIn(userId: "B", config: configB)
        let started = TestLatch()
        let release = TestLatch()
        apiA.onGetDisplayPreferences = { started.open(); await release.wait() }

        let reloadA = Task { await session.reload(appState: appA) }
        await started.wait()
        await session.reload(appState: appB)
        release.open()
        await reloadA.value

        #expect(session.config == configB)
        #expect(session.connection == .connected(bob))
        #expect(session.snapshot()?.accountKey == "S1|B")
        #expect(session.credential() == .session(cookie: "b"))
        #expect(stub.requests.count == 2)
        #expect(stub.requests.allSatisfy { $0.url?.host == "seerr-b.local" })
        #expect(!stub.exhausted)
    }

    @Test("an account change resets — unless the reload of that very account already began")
    func accountChangeSparesTheNewAccountsReload() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply(bobJSON)])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|B": "b"])
        let session = makeSession(stub, storage: storage)
        let (appB, apiB) = signedIn(userId: "B")
        let started = TestLatch()
        let release = TestLatch()
        apiB.onGetDisplayPreferences = { started.open(); await release.wait() }

        let reload = Task { await session.reload(appState: appB) }
        await started.wait()
        // SwiftUI's `onChange(of: activeAccountKey)` may arrive after the
        // reload of the account it announces has started.
        session.accountDidChange(to: "S1|B")
        release.open()
        await reload.value

        #expect(session.connection == .connected(bob))
        let snapshot = try #require(session.snapshot())

        session.accountDidChange(to: "S1|C")

        #expect(!session.isCurrent(snapshot))
        #expect(session.snapshot() == nil)
        #expect(session.connection == .unavailable)
        #expect(session.isAgeCapped)

        session.accountDidChange(to: nil)
        #expect(session.connection == .unavailable)
    }

    @Test("reset forgets the identity, never the stored secrets")
    func resetKeepsSecrets() async {
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "abc"])
        storage.saveSeerrAPIKeys(["S2": "KEY"])
        let session = makeSession(StubSeerrTransport([settingsReply, userReply()]), storage: storage)
        let (app, _) = signedIn()
        await session.reload(appState: app)

        session.reset()

        #expect(session.connection == .unavailable)
        #expect(session.config == nil)
        #expect(session.publicSettings == nil)
        #expect(session.client == nil)
        #expect(session.isAgeCapped)
        #expect(session.credential() == nil)
        #expect(storage.seerrSessions() == ["S1|A": "abc"])
        #expect(storage.seerrAPIKeys() == ["S2": "KEY"])
    }

    // MARK: Render gates

    @Test("the connect prompt shows only when signed out of Seerr in account mode")
    func promptOnlyWhenNotConnected() async {
        let notConnected = makeSession(StubSeerrTransport([settingsReply]))
        let (app, _) = signedIn()
        await notConnected.reload(appState: app)

        #expect(notConnected.connection == .notConnected)
        #expect(notConnected.showsConnectPrompt(proAllows: true, isOnline: true))
        #expect(!notConnected.showsConnectPrompt(proAllows: false, isOnline: true))
        #expect(!notConnected.showsConnectPrompt(proAllows: true, isOnline: false))
        #expect(!notConnected.isVisible(proAllows: true, isOnline: true))

        let cookies = MockKeychain()
        cookies.saveSeerrSessions(["S1|A": "abc"])
        let connected = makeSession(StubSeerrTransport([settingsReply, userReply()]), storage: cookies)
        await connected.reload(appState: app)
        #expect(!connected.showsConnectPrompt(proAllows: true, isOnline: true))

        let keys = MockKeychain()
        keys.saveSeerrAPIKeys(["S1": "KEY"])
        let keyMode = makeSession(StubSeerrTransport([settingsReply, notFoundReply]), storage: keys)
        await keyMode.reload(appState: app)
        #expect(keyMode.connection == .notLinked)
        #expect(!keyMode.showsConnectPrompt(proAllows: true, isOnline: true))

        let capped = makeSession(StubSeerrTransport())
        let (child, _) = signedIn(userId: "B", policy: policy(maxRating: 10))
        await capped.reload(appState: child)
        #expect(!capped.showsConnectPrompt(proAllows: true, isOnline: true))
    }

    // MARK: Sign in / out, device key

    @Test("sign-in stores the cookie under the active account; it connects only for the saved address")
    func signInConnectsOnlyForTheSavedAddress() async {
        let typed = URL(string: "http://192.168.1.30:5055")!
        let stub = StubSeerrTransport([settingsReply,
                                       initiatedReply, approvedReply, authenticatedReply(cookie: "c1")])
        let storage = MockKeychain()
        let session = makeSession(stub, storage: storage)
        let (app, api) = signedIn()
        await session.reload(appState: app)

        let tested = await session.signIn(address: typed, appState: app)

        #expect(tested == .success(alice))
        #expect(storage.seerrSessions()["S1|A"] == "c1")
        #expect(session.connection == .notConnected)
        #expect(stub.requests.count == 4)
        #expect(stub.requests.dropFirst().allSatisfy { $0.url?.host == "192.168.1.30" })

        for reply in [initiatedReply, approvedReply, authenticatedReply(cookie: "c2")] { stub.enqueue(reply) }
        let saved = await session.signIn(address: seerrURL, appState: app)

        #expect(saved == .success(alice))
        #expect(session.connection == .connected(alice))
        #expect(session.credential() == .session(cookie: "c2"))
        #expect(api.authorizeQuickConnectCalls.count == 2)
    }

    @Test("a cancelled sign-in changes nothing")
    func cancelledSignInChangesNothing() async {
        let stub = StubSeerrTransport([settingsReply, initiatedReply])
        let storage = MockKeychain()
        let session = makeSession(stub, storage: storage)
        let (app, api) = signedIn()
        await session.reload(appState: app)
        api.shouldThrow = true
        api.stubbedError = CancellationError()

        let result = await session.signIn(address: seerrURL, appState: app)

        #expect(result == .failure(.cancelled))
        #expect(storage.seerrSessions().isEmpty)
        #expect(session.connection == .notConnected)
    }

    @Test("the approval refuses to run once the app has moved to another account")
    func approvalRefusedAfterAccountMoved() async {
        let stub = StubSeerrTransport([settingsReply, userReply(), forbiddenReply, forbiddenReply, initiatedReply])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "old"])
        let session = makeSession(stub, storage: storage)
        let (app, api) = signedIn()
        await session.reload(appState: app)
        // The Jellyfin client already speaks for B (`applyActiveServer`
        // repoints it and moves `currentUserId` in one main-actor slice),
        // while the session has not heard of the switch yet.
        app.currentUserId = "B"

        await #expect(throws: CancellationError.self) { try await session.perform(search) }

        #expect(api.authorizeQuickConnectCalls.isEmpty)
        #expect(storage.seerrSessions() == ["S1|A": "old"])
    }

    @Test("sign-out logs out on Seerr and forgets the cookie")
    func signOutForgetsCookie() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply(), .response(status: 200, body: #"{"status":"ok"}"#)])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "abc", "S1|B": "b"])
        let session = makeSession(stub, storage: storage)
        let (app, _) = signedIn()
        await session.reload(appState: app)

        await session.signOut()

        #expect(storage.seerrSessions() == ["S1|B": "b"])
        #expect(session.connection == .notConnected)
        #expect(session.credential() == nil)
        let logout = try #require(stub.requests.last)
        #expect(logout.url?.path == "/api/v1/auth/logout")
        #expect(logout.value(forHTTPHeaderField: "Cookie")?.contains("connect.sid=abc") == true)
    }

    @Test("the device key is stored per server and switches the mode")
    func deviceKeyIsPerServer() async {
        let stub = StubSeerrTransport([settingsReply])
        let storage = MockKeychain()
        storage.saveSeerrAPIKeys(["S9": "OTHER"])
        let session = makeSession(stub, storage: storage)
        let (app, _) = signedIn()
        await session.reload(appState: app)
        #expect(session.connection == .notConnected)
        stub.enqueue(settingsReply)
        stub.enqueue(userReply())

        await session.setDeviceKey("  KEY \n", appState: app)

        #expect(storage.seerrAPIKeys() == ["S9": "OTHER", "S1": "KEY"])
        #expect(session.usesDeviceKey)
        #expect(session.credential() == .apiKey(key: "KEY", user: SeerrUserID(rawValue: 7)))
        stub.enqueue(settingsReply)

        await session.setDeviceKey(nil, appState: app)

        #expect(storage.seerrAPIKeys() == ["S9": "OTHER"])
        #expect(!session.usesDeviceKey)
        #expect(session.connection == .notConnected)
        #expect(!stub.exhausted)
    }

    @Test("forgetting an account drops its cookie; forgetting a server drops its key")
    func forgettingDropsSecrets() {
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "a", "S1|B": "b"])
        storage.saveSeerrAPIKeys(["S1": "K1", "S2": "K2"])
        let session = makeSession(StubSeerrTransport(), storage: storage)

        session.forgetAccount("S1|A")
        session.forgetServer("S2")

        #expect(storage.seerrSessions() == ["S1|B": "b"])
        #expect(storage.seerrAPIKeys() == ["S1": "K1"])
    }

    @Test("a language change rebuilds the client with the new language")
    func languageRebuildsClient() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply(), searchReply])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": "abc"])
        let session = makeSession(stub, storage: storage)
        session.setLanguage("fr")
        let (app, _) = signedIn()
        await session.reload(appState: app)

        session.setLanguage("de")
        _ = try await session.perform(search)

        let query = URLComponents(url: try #require(stub.requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "language" }?.value == "de")
    }
}

// MARK: - AppState hooks

@MainActor
@Suite("Seerr session — AppState hooks")
struct SeerrSessionAppStateHookTests {

    @Test("refreshCurrentUser announces itself even signed out (its early return)")
    func refreshAnnouncesEvenSignedOut() async {
        let app = AppState(apiClient: MockAPIClient(), keychain: MockKeychain())
        app.settingsDefaults = .isolatedForTesting()
        var calls = 0
        app.onCurrentUserRefreshed = { calls += 1 }

        await app.refreshCurrentUser()

        #expect(calls == 1)
    }

    @Test("removing a server announces its id, after each of its accounts")
    func removeServerAnnouncesTheServer() async {
        let keychain = MockKeychain()
        let active = ServerEntry(id: "S1", url: jellyfinURL, accessToken: "tokA", userId: "A")
        let other = ServerEntry(id: "S2", url: URL(string: "https://autre.local")!, accessToken: "tokB", userId: "B")
        keychain.savedServers = [active, other]
        keychain.savedActiveServerId = "S1"
        let app = AppState(apiClient: MockAPIClient(), keychain: keychain)
        app.settingsDefaults = .isolatedForTesting()
        app.sessionRevoker = { _, _ in }
        app.loadServersFromKeychain()
        var events: [String] = []
        app.onAccountForgotten = { events.append("account:\($0)") }
        app.onServerForgotten = { events.append("server:\($0)") }

        await app.removeServer(other)

        #expect(events == ["account:S2|B", "server:S2"])
    }
}
