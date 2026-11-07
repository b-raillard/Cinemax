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
        _ replies: [StubSeerrTransport.Reply]
    ) -> (StubSeerrTransport, SeerrSession, AppState) {
        let stub = StubSeerrTransport(replies)
        let (app, _) = signedIn()
        app.serverInfo = ServerInfo(name: "Maison", serverID: "srv", version: "10.11.0", url: jellyfinURL)
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
        let (_, session, app) = keyMode([statusReply, settingsReply, userReply(), other])
        let report = await run(session, app, key: "KEY")
        #expect(report.failure == .otherJellyfin)
        #expect(report.verified.count == 1)      // the version line only
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
        let (_, session, app) = keyMode([statusReply, settingsReply, notFoundReply])
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
        let (_, session, app) = keyMode([statusReply, settingsReply, userReply(admin), seerrServerReply])
        let report = await run(session, app, key: "KEY")
        #expect(report.failure == nil)
        #expect(report.warning == nil)
        #expect(report.verified.count == 3)      // no Quick Connect line in key mode
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
}
