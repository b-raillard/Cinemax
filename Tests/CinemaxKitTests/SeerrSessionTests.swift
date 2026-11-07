import Foundation
import Observation
import Testing
import Get
import JellyfinAPI
@testable import CinemaxKit
@testable import Cinemax

// MARK: - Fixtures

private let jellyfinURL = URL(string: "https://maison.local")!
private let seerrURL = URL(string: "http://192.168.1.20:5055")!
private let otherSeerrURL = URL(string: "http://192.168.1.30:5055")!
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

/// A secret bound to the Seerr address it was issued for.
private func bound(_ value: String, to url: URL = seerrURL) -> SeerrBoundSecret {
    SeerrBoundSecret(value: value, origin: url)
}

private func policy(maxRating: Int? = nil, admin: Bool = false) -> UserPolicy {
    var policy = UserPolicy(authenticationProviderID: "", passwordResetProviderID: "")
    policy.maxParentalRating = maxRating
    policy.isAdministrator = admin
    return policy
}

private func carriesKey(_ request: URLRequest) -> Bool {
    request.value(forHTTPHeaderField: "X-Api-Key") != nil
}

private func carriesCookie(_ request: URLRequest) -> Bool {
    request.value(forHTTPHeaderField: "Cookie")?.contains("connect.sid=") == true
}

/// Fires once on the first mutation of whatever the tracking closure read.
private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var didFire = false
    var fired: Bool { lock.withLock { didFire } }
    func fire() { lock.withLock { didFire = true } }
}

/// Every arrival waits until `count` arrivals happened: holds concurrent
/// requests together so their order cannot decide the test.
private final class Barrier: @unchecked Sendable {
    private let lock = NSLock()
    private let count: Int
    private var arrived = 0
    private let latch = TestLatch()

    init(_ count: Int) { self.count = count }

    func arrive() async {
        let full = lock.withLock { () -> Bool in
            arrived += 1
            return arrived >= count
        }
        if full { latch.open() }
        await latch.wait()
    }
}

/// Answers by PATH (relative to `/api/v1`), so concurrent callers cannot take
/// each other's replies, and runs `onRequest(path, n)` — `n` = how many
/// earlier requests went to that path — before choosing the answer.
private final class RoutedSeerrTransport: SeerrTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: [StubSeerrTransport.Reply]]
    private var sent: [URLRequest] = []
    private var counts: [String: Int] = [:]
    private var ranDry = false
    private var hook: (@Sendable (String, Int) async -> Void)?

    init(_ routes: [String: [StubSeerrTransport.Reply]]) {
        self.routes = routes
    }

    var requests: [URLRequest] { lock.withLock { sent } }
    var exhausted: Bool { lock.withLock { ranDry } }

    func onRequest(_ hook: @escaping @Sendable (String, Int) async -> Void) {
        lock.withLock { self.hook = hook }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path.replacingOccurrences(of: "/api/v1", with: "") ?? ""
        let (index, hook) = lock.withLock { () -> (Int, (@Sendable (String, Int) async -> Void)?) in
            sent.append(request)
            let index = counts[path, default: 0]
            counts[path] = index + 1
            return (index, self.hook)
        }
        await hook?(path, index)
        let reply = lock.withLock { () -> StubSeerrTransport.Reply? in
            guard var queue = routes[path], !queue.isEmpty else {
                ranDry = true
                return nil
            }
            let next = queue.removeFirst()
            routes[path] = queue
            return next
        }
        switch reply {
        case nil:
            throw StubSeerrTransport.Exhausted()
        case .failure(let error):
            throw error
        case .response(let status, let headers, let body):
            let url = request.url ?? seerrURL
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }
}

/// The test host IS the app: `refreshCurrentUser` / `setAgeCap` publish to the
/// REAL shared Keychain item the widget and the Top Shelf read. Put it back
/// (root CLAUDE.md test RULE, T4 — same as `sharedSessionRoundTrips`).
@MainActor
private func preservingSharedSession(_ body: () async -> Void) async {
    let keychain = KeychainService()
    let original = keychain.readSharedSession()
    await body()
    if let original { keychain.saveSharedSession(original) } else { keychain.deleteSharedSession() }
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
    api: MockAPIClient = MockAPIClient(),
    registryServerID: String? = "srv"
) -> (AppState, MockAPIClient) {
    if let config {
        api.displayPreferences[prefsKey] = SeerrUserConfig.merged(config, into: nil)
    }
    let keychain = MockKeychain()
    keychain.savedServers = [ServerEntry(
        id: "S1", name: "Maison", url: jellyfinURL, serverID: registryServerID,
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

/// Makes the signed-in user a Jellyfin administrator the way the app learns
/// it — `refreshCurrentUser` — with the shared session put back afterwards.
@MainActor
private func promoteToAdmin(_ app: AppState, _ api: MockAPIClient) async {
    var admin = UserDto()
    admin.id = app.currentUserId
    admin.policy = policy(admin: true)
    api.stubbedUserByID = admin
    await preservingSharedSession { await app.refreshCurrentUser() }
}

@MainActor
private func makeSession(
    _ transport: any SeerrTransport,
    storage: MockKeychain = MockKeychain(),
    defaults: UserDefaults = .isolatedForTesting(),
    following app: AppState? = nil
) -> SeerrSession {
    let session = SeerrSession(storage: storage, defaults: defaults, transport: transport, signInPause: {})
    // The Pro gate fails closed when unwired; these tests are about everything else.
    session.proAllowsProvider = { true }
    if let app { session.follow(app) }
    return session
}

private extension SeerrSession {
    /// What `AppNavigation` wires: the account the app is on.
    func follow(_ app: AppState) {
        activeAccountKeyProvider = { [app] in app.activeAccountKey }
    }
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
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, _) = signedIn(policy: policy(maxRating: 10))
        let session = makeSession(stub, storage: storage, following: app)

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
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, _) = signedIn()
        let session = makeSession(stub, storage: storage, defaults: defaults, following: app)

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
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, _) = signedIn()
        let session = makeSession(stub, storage: storage, defaults: defaults, following: app)
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
        let disabled = SeerrUserConfig(isEnabled: false, url: seerrURL)
        let (app, _) = signedIn(config: disabled)
        let session = makeSession(stub, following: app)

        await session.reload(appState: app)

        #expect(session.config == disabled)
        #expect(session.connection == .unavailable)
        #expect(!session.isVisible(proAllows: true, isOnline: true))

        let (noAddress, _) = signedIn(userId: "B", config: SeerrUserConfig(isEnabled: true, url: nil))
        session.follow(noAddress)
        await session.reload(appState: noAddress)

        #expect(session.connection == .unavailable)
        #expect(stub.requests.isEmpty)
    }

    @Test("an unknown policy (user not fetched yet) is a cap: no Seerr call")
    func policyUnknownIsCapped() async {
        let stub = StubSeerrTransport()
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, _) = signedIn(knownUser: false)
        let session = makeSession(stub, storage: storage, following: app)

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

    @Test("a known user without a policy is capped too (fail closed)")
    func knownUserWithoutPolicyIsCapped() async {
        let stub = StubSeerrTransport()
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, _) = signedIn(policy: nil)
        let session = makeSession(stub, storage: storage, following: app)

        await session.reload(appState: app)

        #expect(session.isAgeCapped)
        #expect(session.connection == .unavailable)
        #expect(stub.requests.isEmpty)
    }

    @Test("without Pro, reload makes no Seerr call (the configuration is still read)")
    func proRefusedMakesNoSeerrCall() async {
        let stub = StubSeerrTransport()
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, _) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
        session.proAllowsProvider = { false }

        await session.reload(appState: app)

        #expect(session.config == enabledConfig)
        #expect(session.connection == .unavailable)
        #expect(session.credential() == nil)
        await #expect(throws: (any Error).self) { try await session.perform(search) }
        #expect(await session.signIn(address: seerrURL, appState: app) == .failure(.cancelled))
        #expect(stub.requests.isEmpty)
    }

    // MARK: Identity

    @Test("a stored cookie answered by /auth/me restores the connection")
    func cookieRestoresConnection() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, _) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)

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

    @Test("a cookie /auth/me refuses at reload signs in again silently")
    func reloadWithDeadCookieReSignsInSilently() async {
        let stub = StubSeerrTransport([settingsReply, forbiddenReply,
                                       initiatedReply, approvedReply, authenticatedReply(cookie: "fresh")])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("dead")])
        let (app, api) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)

        await session.reload(appState: app)

        #expect(session.connection == .connected(alice))
        #expect(session.credential() == .session(cookie: "fresh"))
        #expect(storage.seerrSessions()["S1|A"] == bound("fresh"))
        #expect(api.authorizeQuickConnectCalls == ["123456"])
        #expect(!stub.exhausted)
    }

    @Test("a silent sign-in that fails at reload shows the prompt: cookie dropped, no retry")
    func reloadReSignInFailureShowsPrompt() async {
        let stub = StubSeerrTransport([settingsReply, forbiddenReply, initiatedReply])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("dead"), "S1|B": bound("bob")])
        let (app, api) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
        api.stubbedAuthorizeQuickConnectResult = false

        await session.reload(appState: app)

        #expect(session.connection == .notConnected)
        #expect(session.showsConnectPrompt(proAllows: true, isOnline: true))
        #expect(storage.seerrSessions() == ["S1|B": bound("bob")])
        #expect(api.authorizeQuickConnectCalls.count == 1)
        #expect(stub.requests.count == 3)
        #expect(!stub.exhausted)
    }

    @Test("an unreachable Seerr keeps the last known connection of the same account")
    func blipKeepsConnection() async {
        let stub = StubSeerrTransport([settingsReply, userReply(), .failure(URLError(.timedOut))])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, _) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
        await session.reload(appState: app)

        await session.reload(appState: app)

        #expect(session.connection == .connected(alice))
        #expect(storage.seerrSessions()["S1|A"] == bound("abc"))
    }

    @Test("the device key resolves the Seerr user; a 404 is « not linked »")
    func deviceKeyResolvesUser() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrAPIKeys(["S1": bound("KEY")])
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, _) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)

        await session.reload(appState: app)

        #expect(session.connection == .connected(alice))
        #expect(session.usesDeviceKey)
        #expect(session.credential() == .apiKey(key: "KEY", user: SeerrUserID(rawValue: 7)))
        let lookup = try #require(stub.requests.last)
        #expect(lookup.url?.path == "/api/v1/user/jellyfin/A")
        #expect(lookup.value(forHTTPHeaderField: "X-Api-Key") == "KEY")
        #expect(lookup.value(forHTTPHeaderField: "X-API-User") == nil)

        let notLinked = makeSession(StubSeerrTransport([settingsReply, notFoundReply]), storage: storage, following: app)
        await notLinked.reload(appState: app)

        #expect(notLinked.connection == .notLinked)
        #expect(notLinked.credential() == nil)
    }

    @Test("a device key entered for another Seerr address is never sent")
    func deviceKeyBoundElsewhereIsNeverSent() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply(), searchReply])
        let storage = MockKeychain()
        storage.saveSeerrAPIKeys(["S1": bound("KEY", to: URL(string: "http://seerr-a.local:5055")!)])
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, _) = signedIn()       // the profile's configuration points at seerrURL
        let session = makeSession(stub, storage: storage, following: app)

        await session.reload(appState: app)
        _ = try await session.perform(search)

        #expect(!session.usesDeviceKey)
        #expect(session.credential() == .session(cookie: "abc"))
        #expect(stub.requests.count == 3)
        #expect(!stub.requests.contains(where: carriesKey))
        #expect(storage.seerrAPIKeys()["S1"] != nil)      // not erased: it belongs to its own address
    }

    @Test("a session cookie issued by another Seerr address is never sent, nor erased")
    func cookieBoundElsewhereIsNeverSent() async {
        let stub = StubSeerrTransport([settingsReply])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("x", to: otherSeerrURL)])
        let (app, _) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)

        await session.reload(appState: app)

        #expect(session.connection == .notConnected)
        #expect(session.credential() == nil)
        #expect(!stub.requests.contains(where: carriesCookie))
        #expect(storage.seerrSessions()["S1|A"] == bound("x", to: otherSeerrURL))
    }

    @Test("signing in to a typed address never sends its cookie to the saved one")
    func testedAddressCookieStaysWithIt() async {
        let stub = StubSeerrTransport([settingsReply, userReply(),
                                       initiatedReply, approvedReply, authenticatedReply(cookie: "x")])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("y")])
        let (app, _) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
        await session.reload(appState: app)
        #expect(session.connection == .connected(alice))

        _ = await session.signIn(address: otherSeerrURL, appState: app)

        #expect(storage.seerrSessions()["S1|A"] == bound("x", to: otherSeerrURL))
        #expect(session.connection == .notConnected)       // the saved address has no session any more
        #expect(session.credential() == nil)
        let sentBefore = stub.requests.count
        stub.enqueue(settingsReply)

        await session.reload(appState: app)

        #expect(session.connection == .notConnected)
        #expect(stub.requests.count == sentBefore + 1)    // /settings/public only
        #expect(!stub.requests.dropFirst(sentBefore).contains(where: carriesCookie))
        #expect(storage.seerrSessions()["S1|A"] == bound("x", to: otherSeerrURL))
        #expect(!stub.exhausted)
    }

    @Test("a device key Seerr refuses is « key refused »")
    func refusedDeviceKey() async {
        let storage = MockKeychain()
        storage.saveSeerrAPIKeys(["S1": bound("OLD")])
        let (app, _) = signedIn()
        let session = makeSession(StubSeerrTransport([settingsReply, forbiddenReply]), storage: storage, following: app)

        await session.reload(appState: app)

        #expect(session.connection == .keyRefused)
        #expect(session.credential() == nil)
        #expect(!session.showsConnectPrompt(proAllows: true, isOnline: true))
    }

    @Test("an admin whose own Seerr switch is off still gets an identity, but no browse surface")
    func adminWithOwnSeerrOffResolvesIdentity() async {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, api) = signedIn(config: SeerrUserConfig(isEnabled: false, url: seerrURL))
        await promoteToAdmin(app, api)
        let session = makeSession(stub, storage: storage, following: app)

        await session.reload(appState: app)

        #expect(session.connection == .connected(alice))
        #expect(session.credential() == .session(cookie: "abc"))
        #expect(!session.isVisible(proAllows: true, isOnline: true))
        #expect(!session.showsConnectPrompt(proAllows: true, isOnline: true))
    }

    // MARK: perform — the 403 probe

    @Test("a dead session signs in again silently, once, then retries")
    func deadSessionReSignsInOnce() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("old")])
        let (app, api) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
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
        #expect(storage.seerrSessions()["S1|A"] == bound("fresh"))
        #expect(session.credential() == .session(cookie: "fresh"))
        #expect(session.connection == .connected(alice))
        #expect(!stub.exhausted)
    }

    @Test("a silent sign-in that fails disconnects, drops the cookie and surfaces the error")
    func failedReSignInDisconnects() async {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("old")])
        let (app, api) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
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
        storage.saveSeerrSessions(["S1|A": bound("old")])
        let (app, api) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
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

    @Test("concurrent calls on a dead session share ONE silent sign-in")
    func concurrentDeadSessionsSignInOnce() async throws {
        let transport = RoutedSeerrTransport([
            "/settings/public": [settingsReply],
            "/auth/me": [userReply(), forbiddenReply, forbiddenReply],
            "/search": [forbiddenReply, forbiddenReply, searchReply, searchReply],
            "/auth/jellyfin/quickconnect/initiate": [initiatedReply],
            "/auth/jellyfin/quickconnect/check": [approvedReply],
            "/auth/jellyfin/quickconnect/authenticate": [authenticatedReply(cookie: "fresh")],
        ])
        let searches = Barrier(2)
        let probes = Barrier(2)
        // Both first calls are refused together, and both probes answered
        // together: each caller then reaches the sign-in while the other's
        // would be in flight.
        transport.onRequest { path, index in
            if path == "/search", index < 2 { await searches.arrive() }
            if path == "/auth/me", index >= 1 { await probes.arrive() }
        }
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("old")])
        let (app, api) = signedIn()
        let session = makeSession(transport, storage: storage, following: app)
        await session.reload(appState: app)

        let first = Task { try await session.perform(search) }
        let second = Task { try await session.perform(search) }
        _ = try await first.value
        _ = try await second.value

        #expect(api.authorizeQuickConnectCalls.count == 1)
        #expect(storage.seerrSessions()["S1|A"] == bound("fresh"))
        #expect(session.connection == .connected(alice))
        #expect(!transport.exhausted)
    }

    @Test("a silent sign-in that fails never overwrites a fresher session")
    func failedSilentSignInSparesAFresherSession() async throws {
        let transport = RoutedSeerrTransport([
            "/settings/public": [settingsReply],
            "/auth/me": [userReply(), forbiddenReply],
            "/search": [forbiddenReply],
            "/auth/jellyfin/quickconnect/initiate": [initiatedReply, initiatedReply],
            "/auth/jellyfin/quickconnect/check": [approvedReply],
            "/auth/jellyfin/quickconnect/authenticate": [authenticatedReply(cookie: "manual")],
        ])
        let silentStarted = TestLatch()
        let releaseSilent = TestLatch()
        transport.onRequest { path, index in
            if path == "/auth/jellyfin/quickconnect/initiate", index == 0 {
                silentStarted.open()
                await releaseSilent.wait()
            }
        }
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("old")])
        let (app, api) = signedIn()
        let session = makeSession(transport, storage: storage, following: app)
        await session.reload(appState: app)

        let call = Task { try await session.perform(search) }
        await silentStarted.wait()
        // The user taps « Se connecter à Seerr » meanwhile, and it works.
        #expect(await session.signIn(address: seerrURL, appState: app) == .success(alice))
        api.stubbedAuthorizeQuickConnectResult = false
        releaseSilent.open()
        await #expect(throws: SeerrError.forbidden) { try await call.value }

        #expect(session.connection == .connected(alice))
        #expect(session.credential() == .session(cookie: "manual"))
        #expect(storage.seerrSessions()["S1|A"] == bound("manual"))
    }

    @Test("a genuine refusal (/auth/me still answers) does not sign in again")
    func genuineForbiddenDoesNotReSignIn() async {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, api) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
        await session.reload(appState: app)
        stub.enqueue(forbiddenReply)
        stub.enqueue(userReply())

        await #expect(throws: SeerrError.forbidden) { try await session.perform(search) }

        #expect(api.authorizeQuickConnectCalls.isEmpty)
        #expect(session.connection == .connected(alice))
        #expect(storage.seerrSessions()["S1|A"] == bound("abc"))
        #expect(!stub.exhausted)
    }

    @Test("key mode: a refused key or an unlinked user surfaces the 403, never a retry")
    func keyModeProbeNeverRetries() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrAPIKeys(["S1": bound("KEY")])
        let (app, api) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
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

    // MARK: Generations and the account switch

    @Test("reloading the same account keeps the generation and never blanks the state")
    func sameAccountReloadKeepsGenerationAndSections() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, api) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
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
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (admin, _) = signedIn()
        let session = makeSession(stub, storage: storage, following: admin)
        await session.reload(appState: admin)
        #expect(session.isVisible(proAllows: true, isOnline: true))
        let adminSnapshot = try #require(session.snapshot())

        let (child, childAPI) = signedIn(userId: "B")
        let started = TestLatch()
        let release = TestLatch()
        childAPI.onGetDisplayPreferences = { started.open(); await release.wait() }
        stub.enqueue(settingsReply)
        session.follow(child)
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
        let urlA = URL(string: "http://seerr-a.local:5055")!
        let urlB = URL(string: "http://seerr-b.local:5055")!
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("a", to: urlA), "S1|B": bound("b", to: urlB)])
        let configA = SeerrUserConfig(isEnabled: true, url: urlA)
        let configB = SeerrUserConfig(isEnabled: true, url: urlB)
        let (appA, apiA) = signedIn(config: configA)
        let (appB, _) = signedIn(userId: "B", config: configB)
        let session = makeSession(stub, storage: storage, following: appA)
        let started = TestLatch()
        let release = TestLatch()
        apiA.onGetDisplayPreferences = { started.open(); await release.wait() }

        let reloadA = Task { await session.reload(appState: appA) }
        await started.wait()
        session.follow(appB)
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
        storage.saveSeerrSessions(["S1|B": bound("b")])
        let (appB, apiB) = signedIn(userId: "B")
        let session = makeSession(stub, storage: storage, following: appB)
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

    @Test("the moment the app is on another account, nothing of the previous one is served")
    func switchWindowServesNothing() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply()])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, _) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
        await session.reload(appState: app)
        let snapshot = try #require(session.snapshot())

        // `applyActiveServer` moved the app; no reset, no reload yet.
        app.currentUserId = "B"

        #expect(session.credential() == nil)
        #expect(session.snapshot() == nil)
        #expect(!session.isCurrent(snapshot))
        #expect(!session.isVisible(proAllows: true, isOnline: true))
        #expect(!session.showsConnectPrompt(proAllows: true, isOnline: true))
        await #expect(throws: (any Error).self) { try await session.perform(search) }
        #expect(stub.requests.count == 2)
    }

    @Test("an answer — or a failure — landing after a switch is a cancellation")
    func answerAfterSwitchIsCancelled() async {
        let transport = RoutedSeerrTransport([
            "/settings/public": [settingsReply],
            "/auth/me": [userReply()],
            "/search": [searchReply, .response(status: 500, body: "{}")],
        ])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, _) = signedIn()
        transport.onRequest { path, _ in
            if path == "/search" { await MainActor.run { app.currentUserId = "B" } }
        }
        let session = makeSession(transport, storage: storage, following: app)
        await session.reload(appState: app)

        await #expect(throws: CancellationError.self) { try await session.perform(search) }

        app.currentUserId = "A"
        await #expect(throws: CancellationError.self) { try await session.perform(search) }
        #expect(!transport.exhausted)
    }

    @Test("the approval refuses to run once the app has moved to another account")
    func approvalRefusedAfterAccountMoved() async {
        let transport = RoutedSeerrTransport([
            "/settings/public": [settingsReply],
            "/auth/me": [userReply(), forbiddenReply],
            "/search": [forbiddenReply],
            "/auth/jellyfin/quickconnect/initiate": [initiatedReply],
        ])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("old")])
        let (app, api) = signedIn()
        // The Jellyfin client already speaks for B (`applyActiveServer`
        // repoints it and moves `currentUserId` in one main-actor slice)
        // while the silent sign-in is between Seerr's code and its approval.
        transport.onRequest { path, _ in
            if path == "/auth/jellyfin/quickconnect/initiate" { await MainActor.run { app.currentUserId = "B" } }
        }
        let session = makeSession(transport, storage: storage, following: app)
        await session.reload(appState: app)

        await #expect(throws: CancellationError.self) { try await session.perform(search) }

        #expect(api.authorizeQuickConnectCalls.isEmpty)
        #expect(storage.seerrSessions() == ["S1|A": bound("old")])
    }

    @Test("reset forgets the identity, never the stored secrets")
    func resetKeepsSecrets() async {
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        storage.saveSeerrAPIKeys(["S2": bound("KEY")])
        let (app, _) = signedIn()
        let session = makeSession(StubSeerrTransport([settingsReply, userReply()]), storage: storage, following: app)
        await session.reload(appState: app)

        session.reset()

        #expect(session.connection == .unavailable)
        #expect(session.config == nil)
        #expect(session.publicSettings == nil)
        #expect(session.client == nil)
        #expect(session.isAgeCapped)
        #expect(session.credential() == nil)
        #expect(storage.seerrSessions() == ["S1|A": bound("abc")])
        #expect(storage.seerrAPIKeys() == ["S2": bound("KEY")])
    }

    // MARK: Render gates

    @Test("the connect prompt shows only when signed out of Seerr in account mode")
    func promptOnlyWhenNotConnected() async {
        let (app, _) = signedIn()
        let notConnected = makeSession(StubSeerrTransport([settingsReply]), following: app)
        await notConnected.reload(appState: app)

        #expect(notConnected.connection == .notConnected)
        #expect(notConnected.showsConnectPrompt(proAllows: true, isOnline: true))
        #expect(!notConnected.showsConnectPrompt(proAllows: false, isOnline: true))
        #expect(!notConnected.showsConnectPrompt(proAllows: true, isOnline: false))
        #expect(!notConnected.isVisible(proAllows: true, isOnline: true))

        let cookies = MockKeychain()
        cookies.saveSeerrSessions(["S1|A": bound("abc")])
        let connected = makeSession(StubSeerrTransport([settingsReply, userReply()]), storage: cookies, following: app)
        await connected.reload(appState: app)
        #expect(!connected.showsConnectPrompt(proAllows: true, isOnline: true))

        let keys = MockKeychain()
        keys.saveSeerrAPIKeys(["S1": bound("KEY")])
        let keyMode = makeSession(StubSeerrTransport([settingsReply, notFoundReply]), storage: keys, following: app)
        await keyMode.reload(appState: app)
        #expect(keyMode.connection == .notLinked)
        #expect(!keyMode.showsConnectPrompt(proAllows: true, isOnline: true))

        let (child, _) = signedIn(userId: "B", policy: policy(maxRating: 10))
        let capped = makeSession(StubSeerrTransport(), following: child)
        await capped.reload(appState: child)
        #expect(!capped.showsConnectPrompt(proAllows: true, isOnline: true))
    }

    // MARK: Sign in / out, device key

    @Test("sign-in stores the cookie under the active account; it connects only for the saved address")
    func signInConnectsOnlyForTheSavedAddress() async {
        let stub = StubSeerrTransport([settingsReply,
                                       initiatedReply, approvedReply, authenticatedReply(cookie: "c1")])
        let storage = MockKeychain()
        let (app, api) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
        await session.reload(appState: app)

        let tested = await session.signIn(address: otherSeerrURL, appState: app)

        #expect(tested == .success(alice))
        #expect(storage.seerrSessions()["S1|A"] == bound("c1", to: otherSeerrURL))
        #expect(session.connection == .notConnected)
        #expect(stub.requests.count == 4)
        #expect(stub.requests.dropFirst().allSatisfy { $0.url?.host == "192.168.1.30" })

        for reply in [initiatedReply, approvedReply, authenticatedReply(cookie: "c2")] { stub.enqueue(reply) }
        let saved = await session.signIn(address: seerrURL, appState: app)

        #expect(saved == .success(alice))
        #expect(session.connection == .connected(alice))
        #expect(session.credential() == .session(cookie: "c2"))
        #expect(storage.seerrSessions()["S1|A"] == bound("c2"))
        #expect(api.authorizeQuickConnectCalls.count == 2)
    }

    @Test("a cancelled sign-in changes nothing")
    func cancelledSignInChangesNothing() async {
        let stub = StubSeerrTransport([settingsReply, initiatedReply])
        let storage = MockKeychain()
        let (app, api) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
        await session.reload(appState: app)
        api.shouldThrow = true
        api.stubbedError = CancellationError()

        let result = await session.signIn(address: seerrURL, appState: app)

        #expect(result == .failure(.cancelled))
        #expect(storage.seerrSessions().isEmpty)
        #expect(session.connection == .notConnected)
    }

    @Test("sign-out logs out on Seerr and forgets the cookie")
    func signOutForgetsCookie() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply(), .response(status: 200, body: #"{"status":"ok"}"#)])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("abc"), "S1|B": bound("b")])
        let (app, _) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
        await session.reload(appState: app)

        await session.signOut()

        #expect(storage.seerrSessions() == ["S1|B": bound("b")])
        #expect(session.connection == .notConnected)
        #expect(session.credential() == nil)
        let logout = try #require(stub.requests.last)
        #expect(logout.url?.path == "/api/v1/auth/logout")
        #expect(logout.value(forHTTPHeaderField: "Cookie")?.contains("connect.sid=abc") == true)
    }

    @Test("the device key is an admin's, stored per server with its address, and switches the mode")
    func deviceKeyIsPerServer() async {
        let stub = StubSeerrTransport([settingsReply])
        let storage = MockKeychain()
        storage.saveSeerrAPIKeys(["S9": bound("OTHER")])
        let (app, api) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
        await session.reload(appState: app)
        #expect(session.connection == .notConnected)

        await session.setDeviceKey("KEY", address: seerrURL, appState: app)       // not an admin

        #expect(storage.seerrAPIKeys() == ["S9": bound("OTHER")])
        #expect(stub.requests.count == 1)

        await promoteToAdmin(app, api)
        stub.enqueue(settingsReply)
        stub.enqueue(userReply())

        await session.setDeviceKey("  KEY \n", address: seerrURL, appState: app)

        #expect(storage.seerrAPIKeys() == ["S9": bound("OTHER"), "S1": bound("KEY")])
        #expect(session.usesDeviceKey)
        #expect(session.credential() == .apiKey(key: "KEY", user: SeerrUserID(rawValue: 7)))
        stub.enqueue(settingsReply)

        await session.setDeviceKey(nil, address: seerrURL, appState: app)

        #expect(storage.seerrAPIKeys() == ["S9": bound("OTHER")])
        #expect(!session.usesDeviceKey)
        #expect(session.connection == .notConnected)
        #expect(!stub.exhausted)
    }

    /// Settings shows « Clé enregistrée » for any key stored for this server,
    /// even one entered for another Seerr address (unusable, but there to remove).
    @Test("a stored device key is reported for the active server only, whatever its address")
    func storedDeviceKeyIsPerServer() async {
        let stub = StubSeerrTransport([settingsReply])
        let storage = MockKeychain()
        storage.saveSeerrAPIKeys(["S9": bound("OTHER")])
        let (app, _) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
        #expect(!session.hasStoredDeviceKey(appState: app))
        storage.saveSeerrAPIKeys(["S9": bound("OTHER"),
                                  "S1": SeerrBoundSecret(value: "KEY", origin: URL(string: "http://elsewhere:5055")!)])
        #expect(session.hasStoredDeviceKey(appState: app))
        storage.saveSeerrAPIKeys(["S1": SeerrBoundSecret(value: "", origin: URL(string: "http://elsewhere:5055")!)])
        #expect(!session.hasStoredDeviceKey(appState: app))
    }

    /// « Tester la connexion » with a key already saved: the stored key is
    /// used only toward the address it was entered for, and only by an admin.
    @Test("the stored key is lent to the test only for its own address, and only to an admin")
    func deviceKeyForTestOnlyForItsAddress() async {
        let stub = StubSeerrTransport([settingsReply])
        let storage = MockKeychain()
        storage.saveSeerrAPIKeys(["S1": bound("KEY"), "S9": bound("OTHER")])
        let (app, api) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
        let elsewhere = URL(string: "http://elsewhere:5055")!

        #expect(session.deviceKeyForTest(address: seerrURL, appState: app) == nil)   // not an admin
        await promoteToAdmin(app, api)
        #expect(session.deviceKeyForTest(address: seerrURL, appState: app) == "KEY")
        #expect(session.deviceKeyForTest(address: URL(string: "http://192.168.1.20:5055/")!, appState: app) == "KEY")
        #expect(session.deviceKeyForTest(address: elsewhere, appState: app) == nil)
        #expect(session.storedDeviceKeyOrigin(appState: app).map { SeerrAddress.sameOrigin($0, seerrURL) } == true)
    }

    /// `AppNavigation` wires the Pro gate; an unwired session must not call Seerr.
    @Test("an unwired Pro gate fails closed: no Seerr call")
    func unwiredProGateFailsClosed() async {
        let stub = StubSeerrTransport([settingsReply])
        let (app, _) = signedIn()
        let session = SeerrSession(storage: MockKeychain(), defaults: .isolatedForTesting(), transport: stub, signInPause: {})
        session.follow(app)
        await session.reload(appState: app)
        #expect(stub.requests.isEmpty)
        #expect(session.connection == .unavailable)
    }

    @Test("a device key without an address is never stored; removing needs no address")
    func deviceKeyNeedsAnAddress() async {
        let stub = StubSeerrTransport([settingsReply])
        let storage = MockKeychain()
        let (app, api) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
        await promoteToAdmin(app, api)

        await session.setDeviceKey("KEY", address: nil, appState: app)
        #expect(storage.seerrAPIKeys().isEmpty)
        #expect(stub.requests.isEmpty)

        storage.saveSeerrAPIKeys(["S1": bound("KEY")])
        await session.setDeviceKey(nil, address: nil, appState: app)
        #expect(storage.seerrAPIKeys().isEmpty)
        #expect(!session.hasStoredDeviceKey(appState: app))
    }

    @Test("forgetting an account drops its cookie; forgetting a server drops its key")
    func forgettingDropsSecrets() {
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("a"), "S1|B": bound("b")])
        storage.saveSeerrAPIKeys(["S1": bound("K1"), "S2": bound("K2")])
        let session = makeSession(StubSeerrTransport(), storage: storage)

        session.forgetAccount("S1|A")
        session.forgetServer("S2")

        #expect(storage.seerrSessions() == ["S1|B": bound("b")])
        #expect(storage.seerrAPIKeys() == ["S1": bound("K1")])
    }

    @Test("a language change rebuilds the client with the new language")
    func languageRebuildsClient() async throws {
        let stub = StubSeerrTransport([settingsReply, userReply(), searchReply])
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("abc")])
        let (app, _) = signedIn()
        let session = makeSession(stub, storage: storage, following: app)
        session.setLanguage("fr")
        await session.reload(appState: app)

        session.setLanguage("de")
        _ = try await session.perform(search)

        let query = URLComponents(url: try #require(stub.requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "language" }?.value == "de")
    }
}

// MARK: - Secret binding

@Suite("Seerr secret binding")
struct SeerrSecretBindingTests {

    @Test("same Seerr: case, default port, trailing slash and a pasted /api/v1 do not matter")
    func sameOrigin() {
        func same(_ lhs: String, _ rhs: String) -> Bool {
            SeerrAddress.sameOrigin(URL(string: lhs), URL(string: rhs))
        }
        #expect(same("http://192.168.1.20:5055", "HTTP://192.168.1.20:5055/"))
        #expect(same("https://Hote/seerr", "https://hote/seerr/api/v1"))
        #expect(same("http://hote", "http://hote:80"))
        #expect(same("https://hote", "https://hote:443/"))
    }

    @Test("another scheme, host, port or path is another Seerr")
    func otherOrigin() {
        func same(_ lhs: String, _ rhs: String) -> Bool {
            SeerrAddress.sameOrigin(URL(string: lhs), URL(string: rhs))
        }
        #expect(!same("http://hote:5055", "https://hote:5055"))
        #expect(!same("http://hote:5055", "http://autre:5055"))
        #expect(!same("http://hote:5055", "http://hote:5056"))
        #expect(!same("https://hote/seerr", "https://hote/autre"))
        #expect(!same("https://hote/seerr", "https://hote"))
        #expect(!SeerrAddress.sameOrigin(nil, URL(string: "http://hote")))
        #expect(!SeerrAddress.sameOrigin(URL(string: "http://hote"), nil))
    }

    @Test("a bound secret prints nothing of its value")
    func boundSecretIsRedacted() {
        let secret = SeerrBoundSecret(value: "s%3Asecret", origin: seerrURL)
        #expect(!"\(secret)".contains("secret"))
        #expect(secret.isBound(to: URL(string: "http://192.168.1.20:5055/")))
        #expect(!secret.isBound(to: otherSeerrURL))
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

        await preservingSharedSession { await app.refreshCurrentUser() }

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
        // `removeServer` forgets the server's certificate pin in the REAL
        // Keychain item: put the pins back as they were.
        let real = KeychainService()
        let pins = real.getTrustedCertificates()

        await app.removeServer(other)

        real.saveTrustedCertificates(pins)
        #expect(events == ["account:S2|B", "server:S2"])
    }

    @Test("a change of the ACTIVE account's age cap announces itself")
    func ageCapChangeAnnouncesItself() async {
        let (app, _) = signedIn()
        var calls = 0
        app.onAgeCapChanged = { calls += 1 }

        await preservingSharedSession { app.setAgeCap(12, forAccountKey: "S1|A") }
        app.setAgeCap(16, forAccountKey: "S1|Z")       // another account: stored, applies when it opens

        #expect(calls == 1)
    }
}

// MARK: - Connection test

private let statusReply = StubSeerrTransport.Reply.response(status: 200, body: #"{"version":"3.4.0"}"#)
private let seerrServerReply = StubSeerrTransport.Reply.response(status: 200, body: #"{"serverId":"srv","ip":"x"}"#)

@MainActor
@Suite("Seerr connection test")
struct SeerrConnectionTestTests {
    private let loc = LocalizationManager()

    /// Account mode: Quick Connect is on, the session is loaded (no cookie).
    private func accountMode(
        _ replies: [StubSeerrTransport.Reply], quickConnect: Bool = true, policy userPolicy: UserPolicy = policy()
    ) async -> (StubSeerrTransport, SeerrSession, AppState, MockAPIClient) {
        let stub = StubSeerrTransport([settingsReply])
        let (app, api) = signedIn(policy: userPolicy)
        app.serverInfo = ServerInfo(name: "Maison", serverID: "srv", version: "10.11.0", url: jellyfinURL)
        api.stubbedQuickConnectEnabled = quickConnect
        let session = makeSession(stub, following: app)
        await session.reload(appState: app)
        for reply in replies { stub.enqueue(reply) }
        return (stub, session, app, api)
    }

    private func keyMode(
        _ replies: [StubSeerrTransport.Reply], liveServerID: String? = "srv", registryServerID: String? = "srv"
    ) -> (StubSeerrTransport, SeerrSession, AppState) {
        let stub = StubSeerrTransport(replies)
        let (app, _) = signedIn(registryServerID: registryServerID)
        app.serverInfo = liveServerID.map {
            ServerInfo(name: "Maison", serverID: $0, version: "10.11.0", url: jellyfinURL)
        }
        return (stub, makeSession(stub, following: app), app)
    }

    private func run(_ session: SeerrSession, _ app: AppState, key: String? = nil) async -> SeerrTestReport {
        await SeerrConnectionTest.run(address: seerrURL, deviceKey: key, session: session, appState: app, loc: loc)
    }

    private let signInReplies = [initiatedReply, approvedReply, authenticatedReply(cookie: "c")]

    @Test("nothing answering is « unreachable »")
    func reportsUnreachable() async {
        let (_, session, app, _) = await accountMode([.failure(URLError(.cannotConnectToHost))])
        let report = await run(session, app)
        #expect(report == SeerrTestReport(failure: .unreachable))
    }

    @Test("something else answering /status is « not Seerr », a redirect is « redirected »")
    func reportsNotSeerr() async {
        let (_, session, app, _) = await accountMode([.response(status: 200, body: "<html></html>")])
        #expect(await run(session, app).failure == .notSeerr)
        let (_, redirected, app2, _) = await accountMode([.response(status: 302, headers: ["Location": "https://elsewhere.example/"])])
        #expect(await run(redirected, app2).failure == .redirected)
    }

    /// Jellyfin itself answers `/api/v1/status` with an empty 404 (bench,
    /// 2026-11-07): something answers, so it is the port, not a dead host.
    @Test("an HTTP error from /status is « not Seerr », never « unreachable »")
    func httpErrorFromStatusIsNotSeerr() async {
        let (_, notFound, app, _) = await accountMode([.response(status: 404, body: "")])
        #expect(await run(notFound, app).failure == .notSeerr)
        let (_, serverError, app2, _) = await accountMode([.response(status: 500, body: "oops")])
        #expect(await run(serverError, app2).failure == .notSeerr)
        // Past /status, Seerr HAS answered: a later HTTP error is not « the port ».
        let (_, later, app3, _) = await accountMode([statusReply, .response(status: 500, body: "oops")])
        #expect(await run(later, app3).failure == .unreachable)
    }

    /// A reverse proxy answering for a Seerr that is down: « ne répond pas ».
    @Test("a gateway error from /status is « unreachable »")
    func gatewayErrorIsUnreachable() async {
        for code in [502, 503, 504] {
            let (_, session, app, _) = await accountMode([.response(status: code, body: "<html>Bad Gateway</html>")])
            #expect(await run(session, app).failure == .unreachable, "\(code)")
        }
    }

    @Test("a Seerr older than 3.4 is « too old »")
    func reportsTooOld() async {
        let (stub, session, app, _) = await accountMode([.response(status: 200, body: #"{"version":"3.3.2"}"#)])
        let report = await run(session, app)
        #expect(report.failure == .tooOld("3.3.2"))
        #expect(report.verified.isEmpty)
        #expect(stub.requests.count == 2)   // the reload's /settings/public, then /status: it stopped there
    }

    @Test("a Seerr on Plex or Emby is « not Jellyfin »")
    func reportsNotJellyfin() async {
        let plex = StubSeerrTransport.Reply.response(status: 200, body: #"{"mediaServerType":1}"#)
        let (_, session, app, _) = await accountMode([statusReply, plex])
        #expect(await run(session, app).failure == .notJellyfin)
    }

    @Test("Quick Connect off on Jellyfin stops before any Seerr sign-in")
    func reportsQuickConnectOff() async {
        let (stub, session, app, api) = await accountMode([statusReply, settingsReply], quickConnect: false)
        let report = await run(session, app)
        #expect(report.failure == .quickConnectOff)
        #expect(api.authorizeQuickConnectCalls.isEmpty)
        #expect(stub.requests.count == 3)
    }

    @Test("an approval Jellyfin answers 404 is « another Jellyfin »")
    func reportsOtherJellyfinFromApproval404() async {
        let (_, session, app, api) = await accountMode([statusReply, settingsReply, initiatedReply])
        api.shouldThrow = true
        api.stubbedError = Get.APIError.unacceptableStatusCode(404)
        #expect(await run(session, app).failure == .otherJellyfin)
    }

    @Test("a different Jellyfin server id behind the key is « another Jellyfin »")
    func reportsOtherJellyfinFromServerId() async {
        let other = StubSeerrTransport.Reply.response(status: 200, body: #"{"serverId":"elsewhere"}"#)
        let (_, session, app) = keyMode([statusReply, settingsReply, other])
        let report = await run(session, app, key: "KEY")
        #expect(report.failure == .otherJellyfin)
        #expect(report.verified.count == 1)      // the version line only; the user is never looked up
    }

    @Test("a Jellyfin refusal names its cause: device restriction, session limit, or plain refusal")
    func reportsDeviceRestriction() async {
        var restricted = policy()
        restricted.enableAllDevices = false
        let (_, session, app, api) = await accountMode([statusReply, settingsReply, initiatedReply], policy: restricted)
        api.shouldThrow = true
        api.stubbedError = Get.APIError.unacceptableStatusCode(403)
        #expect(await run(session, app).failure == .jellyfinDevice)
    }

    @Test("a key Seerr refuses is « key refused »")
    func reportsKeyRefused() async {
        let (_, session, app) = keyMode([statusReply, settingsReply, forbiddenReply])
        #expect(await run(session, app, key: "KEY").failure == .keyRefused)
    }

    @Test("a user Seerr has not imported is « not in Seerr », in both modes")
    func reportsNotInSeerr() async {
        let (_, session, app) = keyMode([statusReply, settingsReply, seerrServerReply, notFoundReply])
        #expect(await run(session, app, key: "KEY").failure == .notInSeerr)
        let denied = StubSeerrTransport.Reply.response(status: 403, body: #"{"message":"Access denied."}"#)
        let (_, accountSession, accountApp, _) = await accountMode(
            [statusReply, settingsReply, initiatedReply, approvedReply, denied])
        #expect(await run(accountSession, accountApp).failure == .notInSeerr)
    }

    @Test("success lists what was verified; a user who cannot manage requests is warned")
    func successListsVerifiedAndWarnsWithoutManage() async {
        let storage = MockKeychain()
        let stub = StubSeerrTransport([settingsReply])
        let (app, api) = signedIn()
        app.serverInfo = ServerInfo(name: "Maison", serverID: "srv", version: "10.11.0", url: jellyfinURL)
        api.stubbedQuickConnectEnabled = true
        let session = makeSession(stub, storage: storage, following: app)
        await session.reload(appState: app)
        for reply in [statusReply, settingsReply] + signInReplies { stub.enqueue(reply) }

        let report = await run(session, app)

        #expect(report.failure == nil)
        #expect(report.verified == [
            loc.localized("seerr.test.ok.version", "3.4.0"),
            loc.localized("seerr.test.ok.server", "Maison"),
            loc.localized("seerr.test.ok.quickConnect"),
            loc.localized("seerr.test.ok.account", loc.localized("seerr.test.ok.role.request")),
        ])
        #expect(report.warning == loc.localized("seerr.test.warning.cannotManage"))
        // The test saves no configuration: the cookie bound to the address is the only trace
        // (the typed address is the saved one here, so the session reads as connected).
        #expect(storage.seerrSessions()["S1|A"] == bound("c"))
        #expect(session.connection == .connected(alice))
    }

    @Test("key mode succeeds with the key's user; an admin is not warned")
    func keyModeSucceedsWithoutWarningForAdmins() async {
        let admin = #"{"id":1,"permissions":2,"jellyfinUserId":"A","displayName":"Alice"}"#
        let (_, session, app) = keyMode([statusReply, settingsReply, seerrServerReply, userReply(admin)])
        let report = await run(session, app, key: "KEY")
        #expect(report.failure == nil)
        #expect(report.warning == nil)
        #expect(report.verified.count == 3)      // no Quick Connect line in key mode
    }

    @Test("serverInfo not fetched yet (after a switch): the registry's server id is compared")
    func otherJellyfinFromRegistryWhenServerInfoMissing() async {
        let other = StubSeerrTransport.Reply.response(status: 200, body: #"{"serverId":"elsewhere"}"#)
        let (_, session, app) = keyMode([statusReply, settingsReply, other], liveServerID: nil)
        #expect(app.serverInfo == nil)
        #expect(await run(session, app, key: "KEY").failure == .otherJellyfin)
        // And the same server, known only by the registry, passes.
        let (_, okSession, okApp) = keyMode(
            [statusReply, settingsReply, seerrServerReply, userReply()], liveServerID: nil)
        #expect(await run(okSession, okApp, key: "KEY").failure == nil)
    }

    @Test("a Jellyfin server id known nowhere fails closed")
    func serverIdUnknownFailsClosed() async {
        let (_, session, app) = keyMode(
            [statusReply, settingsReply, seerrServerReply], liveServerID: nil, registryServerID: nil)
        #expect(await run(session, app, key: "KEY").failure == .otherJellyfin)
        let (_, emptySession, emptyApp) = keyMode(
            [statusReply, settingsReply, seerrServerReply], liveServerID: "", registryServerID: "")
        #expect(await run(emptySession, emptyApp, key: "KEY").failure == .otherJellyfin)
    }

    @Test("a Seerr linked to another Jellyfin says so before looking for the user")
    func otherJellyfinBeforeUserLookup() async {
        let other = StubSeerrTransport.Reply.response(status: 200, body: #"{"serverId":"elsewhere"}"#)
        let (stub, session, app) = keyMode([statusReply, settingsReply, other, notFoundReply])
        #expect(await run(session, app, key: "KEY").failure == .otherJellyfin)
        #expect(stub.requests.count == 3)
    }

    @Test("key mode without a signed-in user is an empty report")
    func keyModeWithoutUserIsEmpty() async {
        let (_, session, app) = keyMode([statusReply, settingsReply])
        app.currentUserId = nil
        #expect(await run(session, app, key: "KEY") == SeerrTestReport())
    }

    @Test("a cancelled sign-in is an empty report")
    func cancelledSignInIsEmpty() async {
        let (_, session, app, api) = await accountMode([statusReply, settingsReply, initiatedReply])
        api.shouldThrow = true
        api.stubbedError = CancellationError()
        #expect(await run(session, app) == SeerrTestReport())
    }

    @Test("a re-sign-in finishing after the mode or the address changed writes nothing")
    func reSignInIgnoresModeOrAddressChange() async throws {
        let transport = RoutedSeerrTransport([
            "/settings/public": [settingsReply, settingsReply],
            "/auth/me": [userReply(), forbiddenReply],
            "/search": [forbiddenReply],
            "/user/jellyfin/A": [userReply()],
            "/auth/jellyfin/quickconnect/initiate": [initiatedReply],
            "/auth/jellyfin/quickconnect/check": [approvedReply],
            "/auth/jellyfin/quickconnect/authenticate": [authenticatedReply(cookie: "late")],
        ])
        let silentStarted = TestLatch()
        let releaseSilent = TestLatch()
        transport.onRequest { path, _ in
            if path == "/auth/jellyfin/quickconnect/initiate" {
                silentStarted.open()
                await releaseSilent.wait()
            }
        }
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("old")])
        let (app, api) = signedIn()
        let session = makeSession(transport, storage: storage, following: app)
        await session.reload(appState: app)

        let call = Task { try await session.perform(search) }
        await silentStarted.wait()
        await promoteToAdmin(app, api)
        await session.setDeviceKey("KEY", address: seerrURL, appState: app)     // account mode → key mode
        releaseSilent.open()
        _ = try? await call.value

        #expect(session.usesDeviceKey)
        #expect(storage.seerrSessions()["S1|A"] == bound("old"))
        #expect(session.connection == .connected(alice))
    }

    @Test("a re-sign-in finishing after the saved address changed writes nothing")
    func reSignInIgnoresAddressChange() async throws {
        let transport = RoutedSeerrTransport([
            "/settings/public": [settingsReply, settingsReply],
            "/auth/me": [userReply(), forbiddenReply],
            "/search": [forbiddenReply],
            "/auth/jellyfin/quickconnect/initiate": [initiatedReply],
            "/auth/jellyfin/quickconnect/check": [approvedReply],
            "/auth/jellyfin/quickconnect/authenticate": [authenticatedReply(cookie: "late")],
        ])
        let silentStarted = TestLatch()
        let releaseSilent = TestLatch()
        transport.onRequest { path, _ in
            if path == "/auth/jellyfin/quickconnect/initiate" {
                silentStarted.open()
                await releaseSilent.wait()
            }
        }
        let storage = MockKeychain()
        storage.saveSeerrSessions(["S1|A": bound("old")])
        let (app, api) = signedIn()
        let session = makeSession(transport, storage: storage, following: app)
        await session.reload(appState: app)

        let call = Task { try await session.perform(search) }
        await silentStarted.wait()
        api.displayPreferences[prefsKey] = SeerrUserConfig.merged(
            SeerrUserConfig(isEnabled: true, url: otherSeerrURL), into: nil)
        await session.reload(appState: app)                                    // same account, another address
        releaseSilent.open()
        _ = try? await call.value

        #expect(session.client?.baseURL == otherSeerrURL)
        #expect(storage.seerrSessions()["S1|A"] == bound("old"))              // "late" was never written
        #expect(session.connection == .notConnected)
    }
}

// MARK: - Activation (admin)

private func prefsKey(for userId: String) -> String {
    "\(userId)|\(SeerrUserConfig.preferencesId)|\(SeerrUserConfig.client)"
}

private func jellyfinUser(_ id: String, _ name: String, maxRating: Int? = nil) -> UserDto {
    var user = UserDto()
    user.id = id
    user.name = name
    user.policy = policy(maxRating: maxRating)
    return user
}

private let adminJSON = #"{"id":1,"permissions":2,"jellyfinUserId":"ADMIN","displayName":"Admin"}"#

@MainActor
private struct ActivationWorld {
    let app: AppState
    let api: MockAPIClient
    let session: SeerrSession
    let transport: RoutedSeerrTransport
    let model = SeerrActivationModel()
    let loc = LocalizationManager()

    func writes(for userId: String) -> [DisplayPreferencesDto] {
        api.updateDisplayPreferencesCalls.filter { $0.userId == userId }.map(\.prefs)
    }

    func stored(_ userId: String) -> SeerrUserConfig {
        SeerrUserConfig.read(api.displayPreferences[prefsKey(for: userId)])
    }
}

/// An administrator (`ADMIN`) whose Seerr session is connected, over `users`.
/// `enabled` users carry `seerr.enabled` + the address; the admin always keeps
/// the address. `lookups` answers `/user/jellyfin/<id>` (absent ⇒ no answer).
@MainActor
private func activationWorld(
    users: [UserDto], enabled: Set<String> = [], lookups: [String: StubSeerrTransport.Reply] = [:],
    credentialed: Bool = true, publicSettings: StubSeerrTransport.Reply = settingsReply
) async -> ActivationWorld {
    let api = MockAPIClient()
    api.stubbedUsers = users
    for user in users {
        guard let id = user.id else { continue }
        let on = enabled.contains(id)
        if on || id == "ADMIN" {
            api.displayPreferences[prefsKey(for: id)] = SeerrUserConfig.merged(
                SeerrUserConfig(isEnabled: on, url: seerrURL), into: nil)
        }
    }
    let (app, _) = signedIn(userId: "ADMIN", config: enabledConfig, api: api)
    var routes: [String: [StubSeerrTransport.Reply]] = [
        "/settings/public": [publicSettings], "/auth/me": [userReply(adminJSON)]]
    for (id, reply) in lookups { routes["/user/jellyfin/\(id)"] = [reply] }
    let transport = RoutedSeerrTransport(routes)
    let storage = MockKeychain()
    if credentialed { storage.saveSeerrSessions(["S1|ADMIN": bound("abc")]) }
    let session = makeSession(transport, storage: storage, following: app)
    await session.reload(appState: app)
    return ActivationWorld(app: app, api: api, session: session, transport: transport)
}

@MainActor
@Suite("Seerr activation")
struct SeerrActivationTests {
    private let adminUser = jellyfinUser("ADMIN", "Admin")
    private let ann = jellyfinUser("ANN", "Ann")
    private let bobUser = jellyfinUser("BOB", "Bob")
    private let tom = jellyfinUser("TOM", "Tom", maxRating: 10)

    @Test("a server-capped user is refused with a reason, and nothing is written for them")
    func cappedUserIsRefusedWithReason() async {
        let world = await activationWorld(
            users: [adminUser, tom], lookups: ["ADMIN": userReply(adminJSON)])
        await world.model.load(appState: world.app, session: world.session)

        let message = await world.model.setEnabled(true, userId: "TOM", appState: world.app, loc: world.loc)

        #expect(message == world.loc.localized("seerr.activation.refused.capped", "Tom"))
        #expect(world.writes(for: "TOM").isEmpty)
        #expect(world.model.lines.first { $0.id == "TOM" }?.kind == .ageCapped)
        #expect(world.model.lines.first { $0.id == "TOM" }?.isEnabled == false)
    }

    @Test("enable-all skips the capped, writes the others, and summarises")
    func enableAllSkipsCappedAndSummarises() async {
        let world = await activationWorld(
            users: [adminUser, ann, bobUser, tom],
            lookups: ["ADMIN": userReply(adminJSON), "ANN": notFoundReply, "BOB": userReply(bobJSON)])
        await world.model.load(appState: world.app, session: world.session)

        let summary = await world.model.enableAll(appState: world.app, loc: world.loc)

        #expect(world.api.updateDisplayPreferencesCalls.count == 3)
        #expect(world.writes(for: "TOM").isEmpty)
        for id in ["ADMIN", "ANN", "BOB"] { #expect(world.stored(id) == SeerrUserConfig(isEnabled: true, url: seerrURL)) }
        #expect(summary == SeerrActivationModel.activationSummary(enabled: 3, refusedNames: ["Tom"], loc: world.loc))
        #expect(world.model.enabledCount == 3)
    }

    @Test("a write carries every other pref of the stored entity")
    func writePreservesOtherPrefs() async {
        let world = await activationWorld(users: [adminUser, ann], lookups: ["ADMIN": userReply(adminJSON), "ANN": notFoundReply])
        var existing = DisplayPreferencesDto(client: SeerrUserConfig.client, id: SeerrUserConfig.preferencesId)
        existing.customPrefs = ["skipForwardLength": "30000", "chromecastVersion": "stable"]
        existing.sortBy = "SortName"
        world.api.displayPreferences[prefsKey(for: "ANN")] = existing
        await world.model.load(appState: world.app, session: world.session)

        let message = await world.model.setEnabled(true, userId: "ANN", appState: world.app, loc: world.loc)

        #expect(message == nil)
        let sent = world.writes(for: "ANN")
        #expect(sent.count == 1)
        #expect(sent.first?.customPrefs?["skipForwardLength"] == "30000")
        #expect(sent.first?.customPrefs?["chromecastVersion"] == "stable")
        #expect(sent.first?.sortBy == "SortName")
        #expect(sent.first?.customPrefs?["seerr.enabled"] == "true")
        #expect(sent.first?.customPrefs?["seerr.url"] == seerrURL.absoluteString)
    }

    @Test("disable-all keeps the admin's address, and each user's")
    func disableAllKeepsAdminAddress() async {
        let world = await activationWorld(
            users: [adminUser, ann, bobUser], enabled: ["ADMIN", "ANN"],
            lookups: ["ADMIN": userReply(adminJSON), "ANN": userReply(), "BOB": notFoundReply])
        await world.model.load(appState: world.app, session: world.session)
        #expect(world.model.enabledCount == 2)

        _ = await world.model.disableAll(appState: world.app, loc: world.loc)

        #expect(world.stored("ADMIN") == SeerrUserConfig(isEnabled: false, url: seerrURL))
        #expect(world.stored("ANN") == SeerrUserConfig(isEnabled: false, url: seerrURL))
        #expect(world.writes(for: "BOB").isEmpty)
        #expect(world.model.enabledCount == 0)
    }

    @Test("turning one user off keeps their stored address")
    func disableOneKeepsAddress() async {
        let world = await activationWorld(
            users: [adminUser, ann], enabled: ["ANN"], lookups: ["ADMIN": userReply(adminJSON), "ANN": userReply()])
        await world.model.load(appState: world.app, session: world.session)

        let message = await world.model.setEnabled(false, userId: "ANN", appState: world.app, loc: world.loc)

        #expect(message == nil)
        #expect(world.stored("ANN") == SeerrUserConfig(isEnabled: false, url: seerrURL))
    }

    @Test("a new address rewrites the admin and every enabled user, never a disabled one")
    func setAddressRewritesEnabledOnly() async {
        let world = await activationWorld(
            users: [adminUser, ann, bobUser], enabled: ["ANN"],
            lookups: ["ADMIN": userReply(adminJSON), "ANN": userReply(), "BOB": notFoundReply])
        await world.model.load(appState: world.app, session: world.session)

        _ = await world.model.setAddress(otherSeerrURL, appState: world.app, loc: world.loc)

        #expect(world.stored("ADMIN") == SeerrUserConfig(isEnabled: false, url: otherSeerrURL))
        #expect(world.stored("ANN") == SeerrUserConfig(isEnabled: true, url: otherSeerrURL))
        #expect(world.writes(for: "BOB").isEmpty)
        #expect(world.api.updateDisplayPreferencesCalls.count == 2)
    }

    @Test("a failed Seerr lookup is « unknown »; with no credential nothing is looked up")
    func lookupFailureIsUnknown() async {
        let failing = await activationWorld(users: [adminUser, ann], lookups: ["ADMIN": userReply(adminJSON), "ANN": .failure(URLError(.timedOut))])
        await failing.model.load(appState: failing.app, session: failing.session)
        #expect(failing.model.lines.map(\.kind) == [.linked(autoApproves: true), .unknown])

        let keyless = await activationWorld(users: [adminUser, ann], credentialed: false)
        let before = keyless.transport.requests.count
        await keyless.model.load(appState: keyless.app, session: keyless.session)
        #expect(keyless.transport.requests.count == before)
        #expect(keyless.model.lines.map(\.kind) == [.unknown, .unknown])
    }

    @Test("lines keep the server's user order and reflect each stored switch")
    func linesInUserOrder() async {
        let world = await activationWorld(
            users: [adminUser, ann, bobUser], enabled: ["BOB"],
            lookups: ["ADMIN": userReply(adminJSON), "ANN": notFoundReply, "BOB": userReply(bobJSON)],
            publicSettings: .response(status: 200, body: #"{"mediaServerType":2,"newPlexLogin":true}"#))
        await world.model.load(appState: world.app, session: world.session)

        #expect(world.model.lines.map(\.id) == ["ADMIN", "ANN", "BOB"])
        #expect(world.model.lines.map(\.name) == ["Admin", "Ann", "Bob"])
        #expect(world.model.lines.map(\.isEnabled) == [false, false, true])
        #expect(world.model.lines[1].kind == .willBeCreated)
    }

    @Test("a profile switch in the middle of enable-all stops the writes")
    func switchMidEnableAllStopsWriting() async {
        let world = await activationWorld(
            users: [adminUser, ann, bobUser],
            lookups: ["ADMIN": userReply(adminJSON), "ANN": notFoundReply, "BOB": notFoundReply])
        await world.model.load(appState: world.app, session: world.session)
        let started = TestLatch()
        let release = TestLatch()
        world.api.onUpdateDisplayPreferences = { _ in started.open(); await release.wait() }

        let task = Task { await world.model.enableAll(appState: world.app, loc: world.loc) }
        await started.wait()
        world.app.currentUserId = "OTHER"
        release.open()
        _ = await task.value

        #expect(world.api.updateDisplayPreferencesCalls.count == 1)
    }

    @Test("disable-all names who could not be switched off")
    func disableAllReportsFailures() async {
        let world = await activationWorld(
            users: [adminUser, ann, bobUser], enabled: ["ANN", "BOB"],
            lookups: ["ADMIN": userReply(adminJSON), "ANN": userReply(), "BOB": notFoundReply])
        await world.model.load(appState: world.app, session: world.session)
        world.api.failingUpdateUserIds = ["ANN"]

        let message = await world.model.disableAll(appState: world.app, loc: world.loc)

        #expect(message == world.loc.localized(world.loc.pluralKey("seerr.activation.summary.disableFailed", 1), "Ann"))
        #expect(world.stored("BOB").isEnabled == false)
        #expect(world.stored("ANN").isEnabled == true)
    }

    @Test("a failed admin write leaves the remembered address alone")
    func setAddressKeepsOldAddressWhenAdminWriteFails() async {
        let world = await activationWorld(
            users: [adminUser, ann], enabled: ["ANN"],
            lookups: ["ADMIN": userReply(adminJSON), "ANN": userReply()])
        await world.model.load(appState: world.app, session: world.session)
        world.api.failingUpdateUserIds = ["ADMIN"]

        let message = await world.model.setAddress(otherSeerrURL, appState: world.app, loc: world.loc)
        #expect(message == world.loc.localized(world.loc.pluralKey("seerr.activation.summary.addressFailed", 1), "Admin"))
        #expect(world.stored("ANN").url == otherSeerrURL)

        world.api.failingUpdateUserIds = []
        let enabled = await world.model.setEnabled(true, userId: "ADMIN", appState: world.app, loc: world.loc)
        #expect(enabled == nil)
        #expect(world.stored("ADMIN").url == seerrURL)      // still the old address
    }

    @Test("a failed admin address write names the admin even before the lines are loaded")
    func addressFailureNamesTheAdminWithoutLines() async {
        let world = await activationWorld(users: [adminUser], lookups: ["ADMIN": userReply(adminJSON)])
        world.app.currentUser?.name = "Admin"
        world.api.failingUpdateUserIds = ["ADMIN"]

        let message = await world.model.setAddress(otherSeerrURL, appState: world.app, loc: world.loc)

        #expect(world.model.lines.isEmpty)
        #expect(message == world.loc.localized(world.loc.pluralKey("seerr.activation.summary.addressFailed", 1), "Admin"))
    }

    @Test("an id that is not in the list is never enabled")
    func unknownUserIsNeverEnabled() async {
        let world = await activationWorld(users: [adminUser], lookups: ["ADMIN": userReply(adminJSON)])
        await world.model.load(appState: world.app, session: world.session)

        let message = await world.model.setEnabled(true, userId: "GHOST", appState: world.app, loc: world.loc)

        #expect(message == world.loc.localized("seerr.activation.failed.enable", ""))
        #expect(world.writes(for: "GHOST").isEmpty)
    }

    @Test("loading for another account clears the previous account's lines")
    func loadForAnotherAccountClearsLines() async {
        let world = await activationWorld(users: [adminUser, ann], lookups: ["ADMIN": userReply(adminJSON), "ANN": notFoundReply])
        await world.model.load(appState: world.app, session: world.session)
        #expect(world.model.lines.count == 2)

        world.app.currentUserId = "OTHER"
        await world.session.reload(appState: world.app)
        world.api.getUsersError = URLError(.notConnectedToInternet)
        await world.model.load(appState: world.app, session: world.session)

        #expect(world.model.lines.isEmpty)
    }

    @Test("a failed write is named in the enable-all summary, the others still land")
    func enableAllReportsFailedNames() async {
        let world = await activationWorld(
            users: [adminUser, ann, bobUser, tom],
            lookups: ["ADMIN": userReply(adminJSON), "ANN": notFoundReply, "BOB": notFoundReply])
        await world.model.load(appState: world.app, session: world.session)
        world.api.failingUpdateUserIds = ["ANN"]

        let summary = await world.model.enableAll(appState: world.app, loc: world.loc)

        #expect(summary == SeerrActivationModel.activationSummary(
            enabled: 2, refusedNames: ["Tom"], failedNames: ["Ann"], loc: world.loc))
        #expect(world.stored("ADMIN").isEnabled && world.stored("BOB").isEnabled)
        #expect(!world.stored("ANN").isEnabled)
    }

    @Test("the line kind truth table")
    func lineKinds() {
        let request = SeerrUser(id: SeerrUserID(rawValue: 2), permissions: .request)
        let approved = SeerrUser(id: SeerrUserID(rawValue: 3), permissions: [.request, .autoApprove])
        let adminSeerr = SeerrUser(id: SeerrUserID(rawValue: 4), permissions: .admin)
        let movieOnly = SeerrUser(id: SeerrUserID(rawValue: 5), permissions: [.request, .autoApproveMovie])
        func kind(_ policy: UserPolicy?, _ user: SeerrUser?, failed: Bool = false, plex: Bool = false) -> SeerrUserLineKind {
            SeerrUserLineKind.kind(policy: policy, seerrUser: user, lookupFailed: failed, newPlexLogin: plex)
        }
        #expect(kind(policy(maxRating: 10), request) == .ageCapped)
        #expect(kind(policy(maxRating: 10), nil, failed: true) == .ageCapped)
        #expect(kind(policy(), request, failed: true) == .unknown)
        #expect(kind(policy(), request) == .linked(autoApproves: false))
        #expect(kind(policy(), approved) == .linked(autoApproves: true))
        #expect(kind(policy(), adminSeerr) == .linked(autoApproves: true))
        #expect(kind(policy(), movieOnly) == .linked(autoApproves: false))
        #expect(kind(policy(), nil, plex: true) == .willBeCreated)
        #expect(kind(policy(), nil, plex: false) == .mustBeAdded)
        #expect(kind(nil, nil) == .mustBeAdded)
    }

    @Test("the summary names who was refused, with the plural rule")
    func summaryWording() {
        let loc = LocalizationManager()
        #expect(SeerrActivationModel.activationSummary(enabled: 3, refusedNames: [], loc: loc)
                == loc.counted("seerr.activation.summary.enabled", 3))
        let one = SeerrActivationModel.activationSummary(enabled: 1, refusedNames: ["Tom"], loc: loc)
        #expect(one.hasPrefix(loc.counted("seerr.activation.summary.enabled", 1)))
        #expect(one.contains(loc.localized(loc.pluralKey("seerr.activation.summary.refused", 1), "Tom")))
        let two = SeerrActivationModel.activationSummary(enabled: 0, refusedNames: ["Tom", "Zoé"], loc: loc)
        #expect(two.contains(loc.localized(loc.pluralKey("seerr.activation.summary.refused", 2), "Tom, Zoé")))
    }
}

// MARK: - Mes demandes (Settings → Demandes)

private func requestJSON(
    _ id: Int, status: Int = 1, type: String = "movie", seasons: [Int] = [],
    tmdbId: Int = 11, mediaStatus: Int = 2, jellyfinId: String? = nil, by requester: String = aliceJSON
) -> String {
    let seasonList = seasons.map { #"{"seasonNumber":\#($0)}"# }.joined(separator: ",")
    let jellyfin = jellyfinId.map { #","jellyfinMediaId":"\#($0)""# } ?? ""
    return #"{"id":\#(id),"status":\#(status),"type":"\#(type)","seasons":[\#(seasonList)],"#
        + #""createdAt":"2026-11-01T10:00:00.000Z","updatedAt":"2026-11-02T10:00:00.000Z","#
        + #""requestedBy":\#(requester),"media":{"tmdbId":\#(tmdbId),"status":\#(mediaStatus)\#(jellyfin)}}"#
}

private func requestPage(_ items: [String], total: Int) -> StubSeerrTransport.Reply {
    .response(status: 200, body: #"{"pageInfo":{"pages":2,"pageSize":20,"results":\#(total),"page":1},"#
        + #""results":[\#(items.joined(separator: ","))]}"#)
}

/// `/movie/{id}` as Seerr 3.5.1 serves it: no `mediaType` (measured on the bench).
private func movieReply(_ id: Int, _ title: String) -> StubSeerrTransport.Reply {
    .response(status: 200, body: #"{"id":\#(id),"title":"\#(title)","posterPath":"/m\#(id).jpg"}"#)
}

private func tvReply(_ id: Int, _ name: String) -> StubSeerrTransport.Reply {
    .response(status: 200, body: #"{"id":\#(id),"name":"\#(name)","posterPath":"/t\#(id).jpg","seasons":[]}"#)
}

private func myRequest(
    status: SeerrRequestStatus = .pending, kind: SeerrMediaKind = .movie, seasons: [Int] = [],
    media: SeerrMediaStatus = .pending, jellyfinId: String? = nil
) -> SeerrRequest {
    SeerrRequest(
        id: 1, status: status, kind: kind, seasons: seasons, createdAt: .distantPast, updatedAt: .distantPast,
        requestedBy: alice, media: SeerrRequestMedia(tmdbId: 1, status: media, jellyfinMediaId: jellyfinId))
}

private func isRequestList(_ request: URLRequest) -> Bool {
    request.url?.path.hasSuffix("/request") == true
}

private func queryValue(_ name: String, in request: URLRequest?) -> String? {
    request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?
        .first { $0.name == name }?.value
}

/// Signed in to Seerr (account mode) as Alice — Seerr id 7, with
/// `permissions` — plus whatever `routes` the test answers.
@MainActor
private func myRequestsWorld(
    permissions: Int = 32, routes: [String: [StubSeerrTransport.Reply]]
) async -> (SeerrSession, AppState, RoutedSeerrTransport) {
    var all = routes
    all["/settings/public"] = [settingsReply]
    all["/auth/me"] = [userReply(#"{"id":7,"permissions":\#(permissions),"jellyfinUserId":"A","displayName":"Alice"}"#)]
    let transport = RoutedSeerrTransport(all)
    let storage = MockKeychain()
    storage.saveSeerrSessions(["S1|A": bound("abc")])
    let (app, _) = signedIn()
    let session = makeSession(transport, storage: storage, following: app)
    await session.reload(appState: app)
    return (session, app, transport)
}

@MainActor
@Suite("Seerr — Mes demandes")
struct SeerrMyRequestsTests {
    private let pending = "seerr.myRequests.status.pending"
    private let approved = "seerr.myRequests.status.approved"
    private let declined = "seerr.myRequests.status.declined"
    private let available = "seerr.myRequests.status.available"

    @Test("only my requests: requestedBy is my Seerr id, even for a manager; a first page of 20")
    func onlyMyRequests() async throws {
        let (session, _, transport) = await myRequestsWorld(permissions: 48, routes: [
            "/request": [requestPage([requestJSON(1, tmdbId: 11)], total: 1)],
            "/movie/11": [movieReply(11, "Dune")],
        ])
        #expect(session.connection == .connected(SeerrUser(
            id: SeerrUserID(rawValue: 7), permissions: [.manageRequests, .request],
            jellyfinUserId: "A", displayName: "Alice")))

        let model = SeerrMyRequestsModel()
        await model.loadFirstPage(session: session)

        let sent = try #require(transport.requests.first(where: isRequestList))
        #expect(queryValue("requestedBy", in: sent) == "7")
        #expect(queryValue("take", in: sent) == "20")
        #expect(queryValue("skip", in: sent) == "0")
        #expect(queryValue("filter", in: sent) == "all")
        #expect(model.rows.map(\.id) == [1])
        #expect(model.rows.first?.title == "Dune")
        #expect(!model.canLoadMore)
        #expect(!transport.exhausted)
    }

    @Test("the status line: arrived first, then refused, waiting, else approved")
    func statusLines() {
        typealias Model = SeerrMyRequestsModel
        #expect(Model.statusKey(myRequest(status: .pending)) == pending)
        // Someone else's request moved the media: mine still waits.
        #expect(Model.statusKey(myRequest(status: .pending, media: .processing)) == pending)
        #expect(Model.statusKey(myRequest(status: .approved, media: .processing)) == approved)
        #expect(Model.statusKey(myRequest(status: .approved, media: .pending)) == approved)
        #expect(Model.statusKey(myRequest(status: .approved, media: .partiallyAvailable)) == approved)
        // Sending it to the downloader failed: still approved, the admin retries.
        #expect(Model.statusKey(myRequest(status: .failed, media: .processing)) == approved)
        #expect(Model.statusKey(myRequest(status: .declined)) == declined)
        #expect(Model.statusKey(myRequest(status: .approved, media: .available)) == available)
        #expect(Model.statusKey(myRequest(status: .pending, media: .available)) == available)
        // A series whose requested seasons all arrived, others still missing.
        #expect(Model.statusKey(myRequest(status: .completed, kind: .tv, media: .partiallyAvailable)) == available)
        let loc = LocalizationManager()
        for key in [pending, approved, declined, available] {
            #expect(loc.localized(key) != key, "\(key) is missing")
        }
    }

    @Test("a series names its seasons, ascending, once each; a film names none")
    func seasonsSuffix() {
        typealias Model = SeerrMyRequestsModel
        #expect(Model.seasonList(myRequest(kind: .tv, seasons: [5, 4, 4])) == "4, 5")
        #expect(Model.seasonList(myRequest(kind: .tv, seasons: [])) == nil)
        #expect(Model.seasonList(myRequest(kind: .movie, seasons: [1])) == nil)
        let loc = LocalizationManager()
        #expect(Model.seasonsSuffix(myRequest(kind: .tv, seasons: [5, 4]), loc: loc)
                == loc.localized(loc.pluralKey("seerr.myRequests.seasons", 2), "4, 5"))
        #expect(Model.seasonsSuffix(myRequest(kind: .tv, seasons: [4]), loc: loc)
                == loc.localized(loc.pluralKey("seerr.myRequests.seasons", 1), "4"))
        #expect(Model.seasonsSuffix(myRequest(kind: .movie), loc: loc) == nil)
        #expect(loc.localized("seerr.myRequests.seasons.one", "4") != loc.localized("seerr.myRequests.seasons", "4"))
    }

    @Test("paging: 20, then the rest, then nothing once the total is reached")
    func pagingStopsAtTotal() async {
        let first = (1...20).map { requestJSON($0, tmdbId: 11) }
        let second = (21...25).map { requestJSON($0, tmdbId: 11) }
        let (session, _, transport) = await myRequestsWorld(routes: [
            "/request": [requestPage(first, total: 25), requestPage(second, total: 25)],
            "/movie/11": Array(repeating: movieReply(11, "Dune"), count: 25),
        ])
        let model = SeerrMyRequestsModel()
        await model.loadFirstPage(session: session)
        #expect(model.rows.count == 20)
        #expect(model.canLoadMore)

        await model.loadNextPage(session: session)
        #expect(model.rows.map(\.id) == Array(1...25))
        #expect(model.rows.allSatisfy { $0.title == "Dune" })
        #expect(!model.canLoadMore)
        let pages = transport.requests.filter(isRequestList)
        #expect(pages.count == 2)
        #expect(queryValue("skip", in: pages.last) == "20")
        #expect(queryValue("requestedBy", in: pages.last) == "7")

        // Past the total, « Afficher plus » asks for nothing.
        await model.loadNextPage(session: session)
        #expect(transport.requests.filter(isRequestList).count == 2)
        #expect(!transport.exhausted)
    }

    @Test("a request already listed is not listed twice when the order moved between pages")
    func pagingDeduplicates() async {
        let first = (1...20).map { requestJSON($0, tmdbId: 11) }
        // Request 20 was modified meanwhile: the second page repeats it.
        let second = (20...24).map { requestJSON($0, tmdbId: 11) }
        let (session, _, _) = await myRequestsWorld(routes: [
            "/request": [requestPage(first, total: 25), requestPage(second, total: 25)],
            "/movie/11": Array(repeating: movieReply(11, "Dune"), count: 24),
        ])
        let model = SeerrMyRequestsModel()
        await model.loadFirstPage(session: session)
        await model.loadNextPage(session: session)
        #expect(model.rows.map(\.id) == Array(1...24))
        // 25 rows were served: the total is reached, nothing more to ask.
        #expect(!model.canLoadMore)
    }

    @Test("titles load row by row: a failed one reads unavailable, and the list never waits for them")
    func titlesPerRow() async {
        let held = TestLatch()
        let asked = TestLatch()
        let (session, _, transport) = await myRequestsWorld(routes: [
            "/request": [requestPage([
                requestJSON(1, tmdbId: 11), requestJSON(2, type: "tv", seasons: [4, 5], tmdbId: 22),
                requestJSON(3, tmdbId: 33),
            ], total: 3)],
            "/movie/11": [movieReply(11, "Dune")],
            "/tv/22": [tvReply(22, "The Expanse")],
            "/movie/33": [notFoundReply],
        ])
        transport.onRequest { path, _ in
            guard path == "/movie/11" else { return }
            asked.open()
            await held.wait()
        }
        let model = SeerrMyRequestsModel()
        let load = Task { await model.loadFirstPage(session: session) }
        await asked.wait()
        // The rows are on screen while a title is still on its way.
        #expect(model.rows.map(\.id) == [1, 2, 3])
        #expect(model.rows.first?.isTitlePending == true)
        held.open()
        await load.value

        #expect(model.rows[0].title == "Dune")
        #expect(model.rows[0].posterPath == "/m11.jpg")
        #expect(model.rows[1].title == "The Expanse")
        #expect(model.rows[1].posterPath == "/t22.jpg")
        #expect(model.rows[2].title == nil)
        #expect(model.rows[2].isTitlePending == false)
        #expect(model.phase == .loaded)
    }

    @Test("no request yet: loaded and empty")
    func emptyList() async {
        let (session, _, _) = await myRequestsWorld(routes: ["/request": [requestPage([], total: 0)]])
        let model = SeerrMyRequestsModel()
        await model.loadFirstPage(session: session)
        #expect(model.phase == .loaded)
        #expect(model.rows.isEmpty)
        #expect(!model.canLoadMore)
    }

    @Test("a list Seerr does not serve ends in a failure, never a stranded spinner")
    func failedList() async {
        let (session, _, _) = await myRequestsWorld(routes: [
            "/request": [.response(status: 500, body: #"{"message":"boom"}"#)],
        ])
        let model = SeerrMyRequestsModel()
        await model.loadFirstPage(session: session)
        #expect(model.phase == .failed)
        #expect(model.rows.isEmpty)
    }

    @Test("« Regarder » opens the Jellyfin item, and only once the title has arrived")
    func watchUsesJellyfinId() {
        typealias Model = SeerrMyRequestsModel
        #expect(Model.watchTarget(myRequest(status: .approved, media: .available, jellyfinId: "jf1")) == "jf1")
        #expect(Model.watchTarget(myRequest(status: .approved, media: .available)) == nil)
        #expect(Model.watchTarget(myRequest(status: .approved, media: .processing, jellyfinId: "jf1")) == nil)
        #expect(Model.watchTarget(myRequest(status: .completed, media: .partiallyAvailable, jellyfinId: "jf1")) == nil)

        let (app, _) = signedIn()
        #expect(Model.watch(myRequest(media: .available, jellyfinId: "jf1"), appState: app))
        #expect(app.pendingDeepLinkItemId == "jf1")
        app.pendingDeepLinkItemId = nil
        #expect(!Model.watch(myRequest(media: .processing, jellyfinId: "jf1"), appState: app))
        #expect(app.pendingDeepLinkItemId == nil)
    }
}

// MARK: - À valider (Settings → Demandes)

private let leaJSON = #"{"id":9,"permissions":32,"jellyfinUserId":"L","displayName":"Léa"}"#

/// Léa's pending requests 1…`count` (all for TMDb 11), and a title for each.
private func pendingRoutes(
    _ count: Int, total: Int, extra: [String: [StubSeerrTransport.Reply]] = [:]
) -> [String: [StubSeerrTransport.Reply]] {
    var routes = extra
    routes["/request", default: []].insert(
        requestPage((1...count).map { requestJSON($0, by: leaJSON) }, total: total), at: 0)
    routes["/movie/11"] = Array(repeating: movieReply(11, "Dune"), count: count + 5)
    return routes
}

private func settled(_ id: Int, status: Int) -> StubSeerrTransport.Reply {
    .response(status: 200, body: requestJSON(id, status: status, by: leaJSON))
}

private func isCall(_ suffix: String) -> (URLRequest) -> Bool {
    { $0.url?.path.hasSuffix(suffix) == true }
}

@MainActor
@Suite("Seerr — À valider")
struct SeerrPendingTests {
    private let loc = LocalizationManager()

    @Test("the count is the pending listing's own total, everyone's requests — never /request/count")
    func countFromPendingFilter() async throws {
        let (session, _, transport) = await myRequestsWorld(permissions: 48, routes: pendingRoutes(20, total: 23))
        let model = SeerrPendingModel()
        await model.load(session: session)

        let sent = try #require(transport.requests.first(where: isRequestList))
        #expect(queryValue("filter", in: sent) == "pending")
        // The queue is the household's: never narrowed to the manager.
        #expect(queryValue("requestedBy", in: sent) == nil)
        #expect(queryValue("take", in: sent) == "20")
        #expect(queryValue("skip", in: sent) == "0")
        #expect(model.count == 23)
        #expect(model.rows.count == 20)
        #expect(model.rows.allSatisfy { $0.request.requestedBy.displayName == "Léa" && $0.title == "Dune" })
        #expect(model.canLoadMore)
        #expect(model.phase == .loaded)
        #expect(!transport.requests.contains(where: isCall("/request/count")))
        #expect(transport.requests.filter(isRequestList).count == 1)
        #expect(!transport.exhausted)
    }

    @Test("approving or refusing removes the row, drops the count, says so — and the next page starts that much earlier")
    func approveRemovesRow() async {
        let (session, _, transport) = await myRequestsWorld(permissions: 16, routes: pendingRoutes(20, total: 22, extra: [
            "/request": [requestPage([requestJSON(21, by: leaJSON), requestJSON(22, by: leaJSON)], total: 20)],
            "/request/2/approve": [settled(2, status: 2)],
            "/request/3/decline": [settled(3, status: 3)],
        ]))
        let toasts = ToastCenter()
        let model = SeerrPendingModel()
        await model.load(session: session)

        await model.approve(2, session: session, toasts: toasts, loc: loc)
        #expect(!model.rows.contains { $0.id == 2 })
        #expect(model.count == 21)
        #expect(model.inFlight.isEmpty)
        #expect(toasts.current?.level == .success)
        #expect(toasts.current?.title == loc.localized("seerr.pending.approved"))
        let approval = transport.requests.first(where: isCall("/request/2/approve"))
        #expect(approval?.httpMethod == "POST")

        await model.decline(3, session: session, toasts: toasts, loc: loc)
        #expect(!model.rows.contains { $0.id == 3 })
        #expect(model.count == 20)
        #expect(toasts.current?.level == .success)
        #expect(toasts.current?.title == loc.localized("seerr.pending.declined"))
        #expect(transport.requests.first(where: isCall("/request/3/decline"))?.httpMethod == "POST")

        // 20 served, 2 settled: the listing is 2 shorter, so the next page's skip is 18.
        #expect(model.canLoadMore)
        await model.loadNextPage(session: session)
        #expect(queryValue("skip", in: transport.requests.filter(isRequestList).last) == "18")
        #expect(queryValue("filter", in: transport.requests.filter(isRequestList).last) == "pending")
        #expect(model.rows.map(\.id) == [1] + Array(4...22))
        #expect(model.count == 20)
        #expect(!model.canLoadMore)
        #expect(!transport.exhausted)
    }

    @Test("a request settled elsewhere first (409) leaves quietly: row removed, an info toast")
    func alreadyHandledIsQuiet() async {
        let (session, _, _) = await myRequestsWorld(permissions: 16, routes: pendingRoutes(3, total: 3, extra: [
            "/request/2/approve": [.response(status: 409, body: #"{"message":"Request is not pending."}"#)],
            "/request/3/decline": [.response(status: 409, body: #"{"message":"Request is not pending."}"#)],
        ]))
        let toasts = ToastCenter()
        let model = SeerrPendingModel()
        await model.load(session: session)

        await model.approve(2, session: session, toasts: toasts, loc: loc)
        #expect(model.rows.map(\.id) == [1, 3])
        #expect(model.count == 2)
        #expect(toasts.current?.level == .info)
        #expect(toasts.current?.title == loc.localized("seerr.pending.alreadyHandled"))

        await model.decline(3, session: session, toasts: toasts, loc: loc)
        #expect(model.rows.map(\.id) == [1])
        #expect(model.count == 1)
        #expect(toasts.current?.level == .info)
        #expect(model.inFlight.isEmpty)
    }

    @Test("any other failure keeps the row for another try, with an error toast")
    func otherErrorKeepsRow() async {
        let (session, _, _) = await myRequestsWorld(permissions: 16, routes: pendingRoutes(3, total: 3, extra: [
            "/request/2/approve": [.response(status: 500, body: #"{"message":"boom"}"#), settled(2, status: 2)],
        ]))
        let toasts = ToastCenter()
        let model = SeerrPendingModel()
        await model.load(session: session)

        await model.approve(2, session: session, toasts: toasts, loc: loc)
        #expect(model.rows.map(\.id) == [1, 2, 3])
        #expect(model.count == 3)
        #expect(model.inFlight.isEmpty)
        #expect(toasts.current?.level == .error)
        #expect(toasts.current?.title == loc.localized("seerr.pending.approveFailed"))

        // The row is still there to be pressed again.
        await model.approve(2, session: session, toasts: toasts, loc: loc)
        #expect(model.rows.map(\.id) == [1, 3])
        #expect(toasts.current?.level == .success)
    }

    @Test("while a request is being settled, a second press on its row sends nothing")
    func secondPressIgnored() async {
        let asked = TestLatch()
        let held = TestLatch()
        let (session, _, transport) = await myRequestsWorld(permissions: 16, routes: pendingRoutes(3, total: 3, extra: [
            "/request/2/approve": [settled(2, status: 2)],
        ]))
        transport.onRequest { path, _ in
            guard path == "/request/2/approve" else { return }
            asked.open()
            await held.wait()
        }
        let toasts = ToastCenter()
        let model = SeerrPendingModel()
        await model.load(session: session)

        let first = Task { await model.approve(2, session: session, toasts: toasts, loc: loc) }
        await asked.wait()
        #expect(model.inFlight[2] == .approve)
        #expect(model.inFlight[1] == nil)
        await model.approve(2, session: session, toasts: toasts, loc: loc)
        await model.decline(2, session: session, toasts: toasts, loc: loc)
        held.open()
        await first.value

        #expect(transport.requests.filter { $0.url?.path.contains("/request/2/") == true }.count == 1)
        #expect(model.rows.map(\.id) == [1, 3])
        #expect(!transport.exhausted)
    }

    @Test("an account change during the call writes and shows nothing")
    func accountChangeMidCall() async {
        let (session, app, transport) = await myRequestsWorld(permissions: 16, routes: pendingRoutes(3, total: 3, extra: [
            "/request/2/approve": [settled(2, status: 2)],
        ]))
        transport.onRequest { path, _ in
            if path == "/request/2/approve" { await MainActor.run { app.currentUserId = "B" } }
        }
        let toasts = ToastCenter()
        let model = SeerrPendingModel()
        await model.load(session: session)

        await model.approve(2, session: session, toasts: toasts, loc: loc)
        #expect(toasts.current == nil)
        #expect(model.rows.map(\.id) == [1, 2, 3])
        #expect(model.count == 3)
    }

    @Test("without Seerr's permission to manage requests: no section, no call — whatever Jellyfin says")
    func hiddenWithoutManage() async {
        let (session, _, transport) = await myRequestsWorld(permissions: 32 | 128, routes: [:])
        #expect(!SeerrPendingModel.isShown(for: session.connection))
        let model = SeerrPendingModel()
        await model.load(session: session)
        #expect(model.phase == .idle)
        #expect(!transport.requests.contains(where: isRequestList))
        #expect(!transport.exhausted)

        func connected(_ permissions: SeerrPermissions) -> SeerrSession.Connection {
            .connected(SeerrUser(id: SeerrUserID(rawValue: 1), permissions: permissions))
        }
        #expect(SeerrPendingModel.isShown(for: connected(.manageRequests)))
        #expect(SeerrPendingModel.isShown(for: connected([.manageRequests, .request])))
        // A Seerr admin passes every check, as on the server.
        #expect(SeerrPendingModel.isShown(for: connected(.admin)))
        #expect(!SeerrPendingModel.isShown(for: connected([.request, .autoApprove, .requestView])))
        #expect(!SeerrPendingModel.isShown(for: .notConnected))
        #expect(!SeerrPendingModel.isShown(for: .unavailable))
        #expect(!SeerrPendingModel.isShown(for: .notLinked))
    }

    @Test("a pending list Seerr does not serve ends in a failure, and can be read again")
    func failedThenRetried() async {
        let (session, _, _) = await myRequestsWorld(permissions: 16, routes: [
            "/request": [.response(status: 500, body: #"{"message":"boom"}"#), requestPage([], total: 0)],
        ])
        let model = SeerrPendingModel()
        await model.load(session: session)
        #expect(model.phase == .failed)
        await model.load(session: session)
        #expect(model.phase == .loaded)
        #expect(model.rows.isEmpty)
        #expect(model.count == 0)
        #expect(!model.canLoadMore)
    }

    @Test("who and when: « Demandé par Léa · il y a 2 h », in the app's language")
    func requestedLine() {
        let created = Date.now.addingTimeInterval(-7_200)
        func request(by user: SeerrUser) -> SeerrRequest {
            SeerrRequest(id: 1, status: .pending, kind: .movie, createdAt: created, updatedAt: created,
                         requestedBy: user, media: SeerrRequestMedia(tmdbId: 1, status: .pending))
        }
        let style = SeerrPendingModel.relativeStyle(loc: loc)
        #expect(style.locale == loc.locale)
        let when = created.formatted(style)
        let lea = SeerrUser(id: SeerrUserID(rawValue: 9), permissions: .request, displayName: "Léa")
        #expect(SeerrPendingModel.requestedLine(request(by: lea), loc: loc)
                == loc.localized("seerr.pending.requestedBy", "Léa", when))
        let nobody = SeerrUser(id: SeerrUserID(rawValue: 9), permissions: .request)
        #expect(SeerrPendingModel.requestedLine(request(by: nobody), loc: loc)
                == loc.localized("seerr.pending.requestedAt", when))
        #expect(loc.localized("seerr.pending.requestedBy", "Léa", when).contains("Léa"))
        #expect(loc.localized("seerr.pending.requestedBy", "Léa", when).contains(when))
        for key in ["seerr.pending.approved", "seerr.pending.declined", "seerr.pending.alreadyHandled",
                    "seerr.pending.approveFailed", "seerr.pending.declineFailed", "seerr.pending.empty",
                    "seerr.pending.approve", "seerr.pending.decline", "seerr.pending.approving",
                    "seerr.pending.declining", "seerr.settings.section.pending"] {
            #expect(loc.localized(key) != key, "\(key) is missing")
        }
        #expect(loc.counted("seerr.settings.section.pendingCount", 3).contains("3"))
    }
}

@Suite("Seerr settings — connection report")
struct SeerrConnectionReportTests {
    @Test("the report stays while the field names the tested address, and goes as soon as it names another")
    func reportFollowsTheField() throws {
        let tested = try #require(URL(string: "http://127.0.0.1:5055"))
        #expect(SeerrTestReport.stillApplies(typed: "http://127.0.0.1:5055", testedAddress: tested))
        // `runTest` writes the normalized form back into the field.
        #expect(SeerrTestReport.stillApplies(typed: tested.absoluteString, testedAddress: tested))
        #expect(SeerrTestReport.stillApplies(typed: "127.0.0.1:5055/", testedAddress: tested))
        #expect(!SeerrTestReport.stillApplies(typed: "http://127.0.0.1:505", testedAddress: tested))
        #expect(!SeerrTestReport.stillApplies(typed: "http://127.0.0.1:8096", testedAddress: tested))
        #expect(!SeerrTestReport.stillApplies(typed: "", testedAddress: tested))
        #expect(!SeerrTestReport.stillApplies(typed: "http://127.0.0.1:5055", testedAddress: nil))
    }
}

// MARK: - Arrival message (launch / foreground)

private let arrivalKey = SettingsKey.seerrArrivalsSeen(accountKey: "S1|A")
private let jellyfinDune = "0123456789abcdef0123456789abcdef"

/// One of my requests, approved, its media AVAILABLE.
private func arrivedJSON(_ id: Int, type: String = "movie", tmdbId: Int = 11, jellyfinId: String? = nil) -> String {
    requestJSON(id, status: 2, type: type, tmdbId: tmdbId, mediaStatus: 5, jellyfinId: jellyfinId)
}

private func isAvailableList(_ request: URLRequest) -> Bool {
    isRequestList(request) && queryValue("filter", in: request) == "available"
}

/// How many times « Voir » asked for Réglages → Demandes.
@MainActor
private final class OpenCounter {
    var count = 0
}

/// Signed in to Seerr (account mode) as Alice, Seerr id 7, with `permissions`.
@MainActor
private func arrivalWorld(
    permissions: Int = 32, config: SeerrUserConfig = enabledConfig, admin: Bool = false,
    defaults: UserDefaults = .isolatedForTesting(), routes: [String: [StubSeerrTransport.Reply]]
) async -> (SeerrSession, AppState, MockAPIClient, RoutedSeerrTransport) {
    var all = routes
    all["/settings/public"] = [settingsReply]
    all["/auth/me"] = [userReply(#"{"id":7,"permissions":\#(permissions),"jellyfinUserId":"A","displayName":"Alice"}"#)]
    let transport = RoutedSeerrTransport(all)
    let storage = MockKeychain()
    storage.saveSeerrSessions(["S1|A": bound("abc")])
    let (app, api) = signedIn(config: config)
    if admin { await promoteToAdmin(app, api) }
    let session = makeSession(transport, storage: storage, defaults: defaults, following: app)
    await session.reload(appState: app)
    return (session, app, api, transport)
}

/// One check, its toast shown the way `AppNavigation` shows it.
@MainActor
private func checkArrivals(
    _ session: SeerrSession, _ app: AppState, defaults: UserDefaults, toasts: ToastCenter,
    opened: OpenCounter = OpenCounter()
) async {
    let arrival = await SeerrArrivalWatcher.check(
        session: session, appState: app, defaults: defaults, loc: LocalizationManager(),
        openRequests: { opened.count += 1 })
    if let arrival { toasts.show(arrival) }
}

@MainActor
@Suite("Seerr — arrival message")
struct SeerrArrivalTests {
    private let loc = LocalizationManager()

    @Test("a manager hears only of HIS arrivals: requestedBy is his own Seerr id, filter available, 20")
    func managerOnlyHearsOwnArrivals() async throws {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set([Int](), forKey: arrivalKey)
        let (session, app, _, transport) = await arrivalWorld(permissions: 48, routes: [
            "/request": [requestPage([arrivedJSON(3)], total: 1)],
            "/movie/11": [movieReply(11, "Dune")],
        ])
        let toasts = ToastCenter()

        await checkArrivals(session, app, defaults: defaults, toasts: toasts)

        let sent = try #require(transport.requests.first(where: isRequestList))
        #expect(queryValue("requestedBy", in: sent) == "7")
        #expect(queryValue("filter", in: sent) == "available")
        #expect(queryValue("take", in: sent) == "20")
        #expect(queryValue("skip", in: sent) == "0")
        #expect(toasts.current?.title == loc.localized("seerr.arrival.title", "Dune"))
        #expect(!transport.exhausted)
    }

    @Test("the first check on a device seeds in silence; an arrival after it is announced")
    func firstCheckSeedsSilently() async {
        let defaults = UserDefaults.isolatedForTesting()
        let (session, app, _, transport) = await arrivalWorld(defaults: defaults, routes: [
            "/request": [
                requestPage([arrivedJSON(2), arrivedJSON(1)], total: 2),
                requestPage([arrivedJSON(3, tmdbId: 33), arrivedJSON(2), arrivedJSON(1)], total: 3),
            ],
            "/movie/33": [movieReply(33, "Arrival")],
        ])
        let toasts = ToastCenter()
        #expect(defaults.object(forKey: arrivalKey) == nil)

        await checkArrivals(session, app, defaults: defaults, toasts: toasts)

        #expect(toasts.current == nil)
        #expect(defaults.array(forKey: arrivalKey) as? [Int] == [2, 1])
        // Nothing to announce: no title was looked up.
        #expect(!transport.requests.contains { $0.url?.path.contains("/movie/") == true })

        await checkArrivals(session, app, defaults: defaults, toasts: toasts)

        #expect(toasts.current?.title == loc.localized("seerr.arrival.title", "Arrival"))
        #expect(defaults.array(forKey: arrivalKey) as? [Int] == [3, 2, 1])
        #expect(!transport.exhausted)
    }

    @Test("only what was not seen yet is announced, named by Jellyfin, with « Regarder » opening its fiche")
    func announcesOnlyNew() async throws {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set([1], forKey: arrivalKey)
        let (session, app, api, transport) = await arrivalWorld(routes: [
            "/request": [
                requestPage([arrivedJSON(2, jellyfinId: jellyfinDune), arrivedJSON(1)], total: 2),
                requestPage([arrivedJSON(2, jellyfinId: jellyfinDune), arrivedJSON(1)], total: 2),
            ],
        ])
        api.getItemHandler = { id in
            var item = BaseItemDto()
            item.id = id
            item.name = "Dune : Deuxième partie"
            return item
        }
        let toasts = ToastCenter()

        await checkArrivals(session, app, defaults: defaults, toasts: toasts)

        let toast = try #require(toasts.current)
        #expect(toast.title == loc.localized("seerr.arrival.title", "Dune : Deuxième partie"))
        #expect(toast.action?.title == loc.localized("seerr.myRequests.watch"))
        #expect(toast.duration >= 5)
        #expect(defaults.array(forKey: arrivalKey) as? [Int] == [2, 1])
        // Jellyfin named it: Seerr was not asked for its title.
        #expect(!transport.requests.contains { $0.url?.path.contains("/movie/") == true })
        toast.action?.perform()
        #expect(app.pendingDeepLinkItemId == jellyfinDune)

        toasts.dismiss()
        await checkArrivals(session, app, defaults: defaults, toasts: toasts)
        #expect(toasts.current == nil)
        #expect(!transport.exhausted)
    }

    @Test("Jellyfin failing, Seerr names it; both failing, the count says it; no fiche ⇒ « Voir »")
    func titleFallsBack() async throws {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set([Int](), forKey: arrivalKey)
        let (session, app, api, _) = await arrivalWorld(routes: [
            "/request": [
                requestPage([arrivedJSON(2, jellyfinId: jellyfinDune)], total: 1),
                requestPage([arrivedJSON(3, tmdbId: 33), arrivedJSON(2, jellyfinId: jellyfinDune)], total: 2),
            ],
            "/movie/11": [movieReply(11, "Dune")],
            "/movie/33": [notFoundReply],
        ])
        api.getItemHandler = { _ in throw URLError(.badServerResponse) }
        let toasts = ToastCenter()
        let opened = OpenCounter()

        await checkArrivals(session, app, defaults: defaults, toasts: toasts, opened: opened)
        #expect(toasts.current?.title == loc.localized("seerr.arrival.title", "Dune"))
        #expect(toasts.current?.action?.title == loc.localized("seerr.myRequests.watch"))

        await checkArrivals(session, app, defaults: defaults, toasts: toasts, opened: opened)
        let toast = try #require(toasts.current)
        #expect(toast.title == loc.counted("seerr.arrival.several", 1))
        // Seerr knows no Jellyfin id for it: no fiche to open, Mes demandes instead.
        #expect(toast.action?.title == loc.localized("seerr.arrival.view"))
        toast.action?.perform()
        #expect(opened.count == 1)
    }

    @Test("several arrivals are ONE toast, counted by title, « Voir » opening Réglages → Demandes")
    func severalBecomeOneToast() async throws {
        let defaults = UserDefaults.isolatedForTesting()
        // Stored but empty is not a first check: everything is new.
        defaults.set([Int](), forKey: arrivalKey)
        let (session, app, _, transport) = await arrivalWorld(routes: [
            "/request": [requestPage([
                arrivedJSON(1, tmdbId: 11), arrivedJSON(2, tmdbId: 12),
                arrivedJSON(3, type: "tv", tmdbId: 22), arrivedJSON(4, type: "tv", tmdbId: 22),
            ], total: 4)],
        ])
        let toasts = ToastCenter()
        let opened = OpenCounter()

        await checkArrivals(session, app, defaults: defaults, toasts: toasts, opened: opened)

        let toast = try #require(toasts.current)
        #expect(toast.title == loc.counted("seerr.arrival.several", 3))
        #expect(toast.title.contains("3"))
        #expect(toast.action?.title == loc.localized("seerr.arrival.view"))
        #expect(defaults.array(forKey: arrivalKey) as? [Int] == [1, 2, 3, 4])
        // No title looked up for a count.
        #expect(transport.requests.filter { !isRequestList($0) }.allSatisfy { $0.url?.path.contains("/movie/") != true })
        toast.action?.perform()
        #expect(opened.count == 1)
        // « Voir » once the app moved to another account opens nothing.
        app.currentUserId = "B"
        toast.action?.perform()
        #expect(opened.count == 1)
        #expect(app.pendingDeepLinkItemId == nil)
    }

    @Test("a capped account, or one Seerr is hidden for, is never checked: no call, no toast, nothing stored")
    func cappedOrHiddenNoCheck() async {
        let toasts = ToastCenter()

        // The device cap, set while connected.
        let capped = UserDefaults.isolatedForTesting()
        var (session, app, _, transport) = await arrivalWorld(defaults: capped, routes: [:])
        #expect(session.isVisible(proAllows: true, isOnline: true))
        capped.set(12, forKey: SettingsKey.privacyMaxContentAge)
        await checkArrivals(session, app, defaults: capped, toasts: toasts)
        #expect(!transport.requests.contains(where: isRequestList))
        #expect(capped.object(forKey: arrivalKey) == nil)

        // The server cap: nothing Seerr was even resolved.
        let serverCapped = UserDefaults.isolatedForTesting()
        let (cappedApp, _) = signedIn(policy: policy(maxRating: 12))
        let cappedTransport = RoutedSeerrTransport([:])
        let cappedSession = makeSession(cappedTransport, defaults: serverCapped, following: cappedApp)
        await cappedSession.reload(appState: cappedApp)
        await checkArrivals(cappedSession, cappedApp, defaults: serverCapped, toasts: toasts)
        #expect(cappedTransport.requests.isEmpty)
        #expect(serverCapped.object(forKey: arrivalKey) == nil)

        // Connected, then no Pro, then offline.
        let hidden = UserDefaults.isolatedForTesting()
        (session, app, _, transport) = await arrivalWorld(routes: [:])
        session.proAllowsProvider = { false }
        await checkArrivals(session, app, defaults: hidden, toasts: toasts)
        session.proAllowsProvider = { true }
        app.isOnlineProvider = { false }
        await checkArrivals(session, app, defaults: hidden, toasts: toasts)
        #expect(!transport.requests.contains(where: isRequestList))

        // An admin whose own switch is off: an identity, no browse surface.
        (session, app, _, transport) = await arrivalWorld(
            config: SeerrUserConfig(isEnabled: false, url: seerrURL), admin: true, routes: [:])
        #expect(session.connection == .connected(alice))
        await checkArrivals(session, app, defaults: hidden, toasts: toasts)
        #expect(!transport.requests.contains(where: isRequestList))
        #expect(hidden.object(forKey: arrivalKey) == nil)
        #expect(toasts.current == nil)
    }

    @Test("the seen list keeps what is on the page first, the newest 200 at most")
    func seenListCapped() {
        func arrived(_ id: Int) -> SeerrRequest {
            SeerrRequest(
                id: id, status: .approved, kind: .movie, createdAt: .distantPast, updatedAt: .distantPast,
                requestedBy: alice, media: SeerrRequestMedia(tmdbId: id, status: .available))
        }
        let previous = Array(1...200)
        let stored = SeerrArrivalWatcher.stored(available: [arrived(300), arrived(150)], previous: previous)
        #expect(stored.count == SeerrArrivalWatcher.maxSeen)
        #expect(Array(stored.prefix(2)) == [300, 150])
        #expect(!stored.contains(200))   // the oldest went
        #expect(stored.contains(199))
        #expect(Set(stored).count == stored.count)

        let first = SeerrArrivalWatcher.newArrivals(available: [arrived(1)], seen: nil)
        #expect(first.toAnnounce.isEmpty)
        #expect(first.seen == [1])
        let next = SeerrArrivalWatcher.newArrivals(available: [arrived(2), arrived(1)], seen: [1])
        #expect(next.toAnnounce.map(\.id) == [2])
        #expect(next.seen == [1, 2])
        for key in ["seerr.arrival.title", "seerr.arrival.view"] {
            #expect(loc.localized(key) != key, "\(key) is missing")
        }
    }
}
