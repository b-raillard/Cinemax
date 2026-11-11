import Foundation
import Testing
import CinemaxKit
@testable import Cinemax

/// A probe the test drives: a fixed outcome, a call count, and an optional
/// latch holding the answer open (the race window, never a sleep).
private final class ProbeStub: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: LocalProbeOutcome
    private var latch: TestLatch?
    private var count = 0

    init(_ outcome: LocalProbeOutcome) { self.outcome = outcome }

    var calls: Int { lock.withLock { count } }

    func set(outcome: LocalProbeOutcome? = nil, latch: TestLatch? = nil) {
        lock.withLock {
            if let outcome { self.outcome = outcome }
            self.latch = latch
        }
    }

    func probe(_ url: URL, _ timeout: TimeInterval) async -> LocalProbeOutcome {
        let gate = lock.withLock { () -> TestLatch? in
            count += 1
            return latch
        }
        await gate?.wait()
        return lock.withLock { outcome }
    }
}

/// What the controller pushed to the transports other than the API client.
@MainActor
private final class TransportLog {
    var imageRoutes: [(identity: URL?, dial: URL?)] = []
    var streamURLs: [URL?] = []

    var transports: RouteTransports {
        RouteTransports(
            setImageRoute: { [self] identity, dial in imageRoutes.append((identity, dial)) },
            configureStream: { [self] url in streamURLs.append(url) },
            repointSocket: { _ in }
        )
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@MainActor
@Suite("Adresse locale — route active")
struct ServerRouteControllerTests {

    private let identity = URL(string: "https://movies.nivadax.net")!
    private let lan = URL(string: "https://192.168.1.128:8920")!
    private let other = URL(string: "https://chalet.example.org")!

    private func entry(id: String = "E1", url: URL? = nil, serverID: String? = "S", local: Bool = true) -> ServerEntry {
        ServerEntry(id: id, name: "Maison", url: url ?? identity, serverID: serverID,
                    accessToken: "tok-\(id)", userId: "U", username: "Alice",
                    localURL: local ? lan : nil)
    }

    private func makeApp(api: MockAPIClient, keychain: MockKeychain = MockKeychain(), entries: [ServerEntry]) -> AppState {
        keychain.savedServers = entries
        keychain.savedActiveServerId = entries.first?.id
        // The client is on the active server, as after `restoreSession`.
        if let first = entries.first { api.reconnect(url: first.url, accessToken: first.accessToken ?? "") }
        let app = AppState(apiClient: api, keychain: keychain)
        app.settingsDefaults = UserDefaults.isolatedForTesting()
        app.loadServersFromKeychain()
        app.serverURL = entries.first?.url
        app.hasServer = true
        app.isAuthenticated = true
        app.accessToken = entries.first?.accessToken
        app.currentUserId = entries.first?.userId
        return app
    }

    private func makeController(
        _ stub: ProbeStub, app: AppState, reach: NetworkReach = .lanCapable
    ) -> ServerRouteController {
        let controller = ServerRouteController(probe: stub.probe)
        controller.transports = .inert
        controller.attach(appState: app, reach: { reach })
        return controller
    }

    @Test func launchAtHomeGoesLocal() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)
        let refreshes = Counter()
        let token = NotificationCenter.default.addObserver(
            forName: .cinemaxShouldRefreshCatalogue, object: controller, queue: nil
        ) { _ in refreshes.bump() }
        defer { NotificationCenter.default.removeObserver(token) }

        await controller.evaluate(.launch)

        #expect(api.dialURLs.last == lan)
        #expect(controller.route == .local)
        #expect(controller.dialURL == lan)
        #expect(refreshes.count == 1)
    }

    /// R17 — signed out, nothing reads a stale « Local »: the route, the dial,
    /// the memo and the images go back to the identity at logout.
    @Test func logoutResetsRoute() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)
        let log = TransportLog()
        controller.transports = log.transports
        await controller.evaluate(.launch)
        #expect(controller.route == .local)
        _ = await controller.dialURL(for: entry())

        _ = await app.logout(reason: .sessionExpired)

        #expect(controller.route == .internet)
        #expect(controller.dialURL == nil)
        #expect(controller.transportURL(identity: identity) == identity)
        #expect(log.imageRoutes.last.map { $0.identity == nil && $0.dial == nil } == true)
        #expect(log.streamURLs.last == .some(identity))
        // The memo went with the session: the next decision probes again.
        let calls = stub.calls
        _ = await controller.dialURL(for: entry())
        #expect(stub.calls == calls + 1)
    }

    @Test func unchangedRouteIsNoOp() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)
        await controller.evaluate(.launch)

        await controller.evaluate(.foreground)

        #expect(stub.calls == 2)
        #expect(api.dialURLs == [lan])
    }

    @Test func cellularSkipsProbe() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app, reach: .cellularOnly)

        await controller.evaluate(.launch)

        #expect(stub.calls == 0)
        #expect(controller.route == .internet)
        #expect(api.dialURLs.isEmpty)
    }

    @Test func failedProbeKeepsInternet() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        let stub = ProbeStub(.failed(localNetworkDenied: false))
        let controller = makeController(stub, app: app)

        await controller.evaluate(.launch)

        #expect(stub.calls == 1)
        #expect(controller.route == .internet)
        #expect(controller.dialURL == nil)
        #expect(api.dialURLs.isEmpty)
    }

    @Test func pathChangeFallsBackFirst() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)
        await controller.evaluate(.launch)
        #expect(controller.route == .local)

        let latch = TestLatch()
        stub.set(latch: latch)
        controller.pathChanged()

        // Before the probe answers: back on the public URL at once.
        #expect(api.dialURLs.last == .some(nil))
        #expect(controller.route == .internet)
        #expect(controller.dialURL == nil)
        await eventually { stub.calls == 2 }

        latch.open()
        await controller.pendingEvaluation?.value

        #expect(api.dialURLs.last == lan)
        #expect(controller.route == .local)
    }

    /// R16 — a playback open waits for the DECISION, not only for the probe:
    /// the probe's own continuation (→ `apply` → `setDialURL`) and the
    /// waiter's both resume on the main actor in no guaranteed order.
    @Test func probeWaitCoversTheApply() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)
        await controller.evaluate(.launch)
        #expect(api.dialURLs.last == lan)

        // The path change falls back to the identity and schedules the
        // evaluation, which has not even started its probe yet.
        controller.pathChanged()
        #expect(api.dialURLs.last == .some(nil))
        await controller.awaitPendingProbe()

        #expect(api.dialURLs.last == lan, "the open sees the decision already applied")
        #expect(controller.route == .local)
    }

    @Test func probeWaitCoversAHeldEvaluation() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        let latch = TestLatch()
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        stub.set(latch: latch)
        let controller = makeController(stub, app: app)

        let evaluation = Task { await controller.evaluate(.launch) }
        await eventually { stub.calls == 1 }
        let waiter = Task { @MainActor in
            await controller.awaitPendingProbe()
            return api.dialURLs.last
        }
        latch.open()
        let seen = await waiter.value
        await evaluation.value

        #expect(seen == .some(lan), "applied before the waiter resumed")
    }

    @Test func probeWaitReturnsAtOnceWithNothingPending() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)

        await controller.awaitPendingProbe()

        #expect(stub.calls == 0)
        #expect(api.dialURLs.isEmpty)
    }

    @Test func staleProbeDropped() async {
        let api = MockAPIClient()
        let keychain = MockKeychain()
        let home = entry(id: "E1")
        let chalet = entry(id: "E2", url: other, serverID: "S2", local: false)
        let app = makeApp(api: api, keychain: keychain, entries: [home, chalet])
        let latch = TestLatch()
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        stub.set(latch: latch)
        let controller = makeController(stub, app: app)

        let evaluation = Task { await controller.evaluate(.launch) }
        await eventually { stub.calls == 1 }
        // The active server moves while the probe is held open.
        keychain.savedActiveServerId = "E2"
        app.loadServersFromKeychain()
        latch.open()
        await evaluation.value

        #expect(api.dialURLs.isEmpty)
        #expect(controller.route == .internet)
        #expect(controller.dialURL == nil)
    }

    @Test func accountSwitchReevaluatesRoute() async {
        let api = MockAPIClient()
        // The switch's background `fetchServerInfo` writes the server's own
        // Id back into the entry: the same server reports the same Id.
        api.stubbedServerInfo = ServerInfo(name: "Maison", serverID: "S", version: "10.11.0", url: identity)
        let home = entry()
        let app = makeApp(api: api, entries: [home])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)
        app.onClientRepointed = { Task { await controller.evaluate(.serverChange) } }
        await controller.evaluate(.launch)
        #expect(api.currentDialURL() == lan)

        // Same server: `reconnect` resets the client's dial to the identity…
        await app.applyActiveServer(home)

        // …and the repoint seam puts it back on the LAN.
        await eventually { api.dialURLs.count == 2 }
        #expect(api.dialURLs == [lan, lan])
        #expect(api.currentDialURL() == lan)
        #expect(controller.route == .local)
    }

    @Test func transportURLKeepsDialForSameIdentity() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)
        await controller.evaluate(.launch)

        #expect(controller.transportURL(identity: identity) == lan)
        #expect(controller.transportURL(identity: other) == other)
        #expect(controller.transportURL(identity: nil) == nil)
    }

    @Test func noServerIDNeverLocal() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry(serverID: nil)])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)

        await controller.evaluate(.launch)

        #expect(controller.route == .internet)
        #expect(api.dialURLs.isEmpty)
    }

    @Test func switchReusesTargetProbe() async {
        let api = MockAPIClient()
        let home = entry()
        let app = makeApp(api: api, entries: [home])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)

        let target = await controller.dialURL(for: home)
        #expect(target == lan)
        #expect(api.dialURLs.isEmpty)   // deciding never pushes

        await controller.evaluate(.serverChange)

        #expect(stub.calls == 1)
        #expect(api.dialURLs.last == lan)
        #expect(controller.route == .local)
    }

    @Test func reconnectThenInternetClearsOtherTransports() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)
        let log = TransportLog()
        controller.transports = log.transports
        await controller.evaluate(.launch)
        #expect(log.imageRoutes.last?.dial == lan)

        // A rebuilt client already dials the identity, but the image table and
        // the stream policy still point at the LAN: they must be brought back.
        api.reconnect(url: identity, accessToken: "tok-E1")
        stub.set(outcome: .failed(localNetworkDenied: false))
        await controller.evaluate(.serverChange)

        #expect(controller.route == .internet)
        #expect(log.imageRoutes.count == 2)
        #expect(log.imageRoutes.last.map { $0.identity == identity && $0.dial == nil } == true)
        #expect(log.streamURLs == [lan, identity])
    }

    @Test func reLoginHandshakeIsNeverRerouted() async {
        let api = MockAPIClient()
        let home = entry(id: "E1")
        let chalet = entry(id: "E2", url: other, serverID: "S2", local: false)
        let app = makeApp(api: api, entries: [home, chalet])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)
        await controller.evaluate(.launch)
        #expect(api.dialURLs == [lan])

        // B's handshake is held open while the session still reads as A's.
        let latch = TestLatch()
        api.connectGate = latch
        let relogin = Task { await app.beginReLogin(for: chalet) }
        await eventually { api.connectCalled }
        controller.pathChanged()
        await controller.evaluate(.foreground)
        #expect(api.dialURLs == [lan], "nothing rebuilds the client under the handshake")
        #expect(stub.calls == 1)

        latch.open()
        await relogin.value
        await controller.pendingEvaluation?.value

        #expect(api.dialURLs == [lan], "nothing applied for A after the release either")
        #expect(api.refusedDialURLs.isEmpty)
        #expect(api.identityURL == other, "the client is on B")
        #expect(api.currentDialURL() == nil, "and dials B's own identity")
        #expect(app.isAuthenticated == false)
    }

    @Test func signInHoldDefersThenEvaluatesOnce() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)
        await controller.evaluate(.launch)

        app.beginSignIn()
        controller.pathChanged()
        await controller.evaluate(.foreground)
        #expect(api.dialURLs == [lan], "held: the client is not touched")
        #expect(stub.calls == 1)

        stub.set(outcome: .failed(localNetworkDenied: false))
        app.endSignIn()
        await controller.pendingEvaluation?.value

        #expect(stub.calls == 2, "the release runs ONE evaluation")
        #expect(api.dialURLs == [lan, nil])
        #expect(controller.route == .internet)
    }

    @Test func freshSignInRoutesLocal() async {
        let api = MockAPIClient()
        api.stubbedSession = UserSession(userID: "U", username: "Alice", accessToken: "tok-new", serverID: "S")
        let app = makeApp(api: api, entries: [entry()])
        // The login screen: a server, no session yet.
        app.isAuthenticated = false
        app.currentUserId = nil
        app.accessToken = nil
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)
        let login = LoginViewModel()
        login.username = "Alice"

        await login.authenticate(using: app, loc: LocalizationManager())
        await controller.pendingEvaluation?.value

        #expect(app.isAuthenticated)
        #expect(stub.calls == 1)
        #expect(api.dialURLs.last == lan)
        #expect(controller.route == .local)
    }

    @Test func signedOutNeverApplies() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        app.isAuthenticated = false
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)

        await controller.evaluate(.launch)
        controller.pathChanged()
        await controller.pendingEvaluation?.value

        #expect(stub.calls == 0)
        #expect(api.dialURLs.isEmpty)
    }

    // MARK: - The indication, derived from the host

    @Test func lanIdentityWithNoLocalAddressReadsLocal() async {
        let api = MockAPIClient()
        let lanIdentity = URL(string: "http://192.168.1.128:8899")!
        let server = entry(url: lanIdentity, local: false)
        let app = makeApp(api: api, entries: [server])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)

        await controller.evaluate(.launch)

        #expect(stub.calls == 0, "no local address: no probe")
        #expect(controller.dialURL == nil)
        #expect(controller.route == .local)
        #expect(controller.routeKind(for: server) == .local)
        #expect(controller.activeDialURL == lanIdentity)
        // The diagnostics header reads the same derivation.
        var facts = DiagnosticsFacts.current(serverVersion: nil, engine: "vlc", lastPlayback: nil)
        facts.serverRoute = controller.route.rawValue
        #expect(DiagnosticsReport.header(facts).last == "server_route: local")
    }

    @Test func publicIdentityOnTheLANDialReadsLocal() async {
        let api = MockAPIClient()
        let server = entry()
        let app = makeApp(api: api, entries: [server])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)

        await controller.evaluate(.launch)

        #expect(controller.route == .local)
        #expect(controller.routeKind(for: server) == .local)
        #expect(controller.effectiveDialURL(for: server) == lan)
        #expect(controller.activeDialURL == lan)
        // Another server is never read through this one's dial.
        let elsewhere = entry(id: "E2", url: other, local: false)
        #expect(controller.routeKind(for: elsewhere) == .internet)
        #expect(controller.effectiveDialURL(for: elsewhere) == other)
    }

    @Test func publicIdentityOnTheIdentityReadsInternet() async {
        let api = MockAPIClient()
        let server = entry()
        let app = makeApp(api: api, entries: [server])
        let stub = ProbeStub(.failed(localNetworkDenied: false))
        let controller = makeController(stub, app: app)

        await controller.evaluate(.launch)

        #expect(controller.route == .internet)
        #expect(controller.routeKind(for: server) == .internet)
        #expect(controller.activeDialURL == identity)
        var facts = DiagnosticsFacts.current(serverVersion: nil, engine: "vlc", lastPlayback: nil)
        facts.serverRoute = controller.route.rawValue
        #expect(DiagnosticsReport.header(facts).last == "server_route: internet")
    }

    // MARK: - Launch ordering

    /// The launch evaluation is recorded BEFORE `restoreSession` returns, so
    /// the UI's first loads (Home, the views, the socket), which ask right
    /// after, wait for the launch's apply instead of going out on the identity.
    @Test func restoreSessionRecordsTheLaunchEvaluationForWaiters() async {
        let api = MockAPIClient()
        let keychain = MockKeychain()
        keychain.savedServers = [entry()]
        keychain.savedActiveServerId = "E1"
        keychain.savedServerURL = identity
        keychain.savedSession = UserSession(userID: "U", username: "Alice", accessToken: "tok-E1", serverID: "S")
        let app = AppState(apiClient: api, keychain: keychain)
        app.settingsDefaults = UserDefaults.isolatedForTesting()
        let latch = TestLatch()
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        stub.set(latch: latch)
        let controller = makeController(stub, app: app)
        app.prepareRoute = { controller.scheduleLaunchEvaluation() }
        let refreshed = TestLatch()
        app.onCurrentUserRefreshed = { refreshed.open() }

        await preservingSharedExtensionSession {
            await app.restoreSession()
            // Synchronously after the return: already recorded.
            #expect(controller.pendingEvaluation != nil)
            let waiter = Task { @MainActor in
                await controller.awaitPendingProbe()
                return api.dialURLs.last
            }
            latch.open()
            let seen = await waiter.value
            #expect(seen == .some(lan), "the waiter resumed only once the launch route was applied")
            // The background task publishes the extension session: let it end
            // before the shared item is put back.
            await refreshed.wait()
        }
        #expect(controller.route == .local)
    }

    /// The login screen that follows a session's end dials the public URL.
    @Test func sessionEndPutsTheClientBackOnTheIdentity() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        let controller = makeController(stub, app: app)
        await controller.evaluate(.launch)
        #expect(api.currentDialURL() == lan)

        app.isAuthenticated = false
        controller.sessionEnded()

        #expect(api.currentDialURL() == nil)
        #expect(controller.route == .internet)
    }

    /// Signed out with a re-login's LAN dial installed: leaving the network
    /// drops it — but never while a sign-in holds the client.
    @Test func pathChangeWhileSignedOutDropsTheDial() {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        let controller = makeController(ProbeStub(.failed(localNetworkDenied: false)), app: app)
        app.isAuthenticated = false
        api.setDialURL(lan)

        app.beginSignIn()
        controller.pathChanged()
        #expect(api.currentDialURL() == lan, "held by a sign-in: untouched")
        app.endSignIn()

        api.setDialURL(lan)
        controller.pathChanged()
        #expect(api.currentDialURL() == nil)
    }

    /// A launch refresh owed by a session that ended is not paid by the next.
    @Test func sessionEndDropsAnOwedLaunchRefresh() async {
        let api = MockAPIClient()
        let app = makeApp(api: api, entries: [entry()])
        let latch = TestLatch()
        let stub = ProbeStub(.answered(serverID: "S", connectedAddressIsLocal: true))
        stub.set(latch: latch)
        let controller = makeController(stub, app: app)
        let refreshes = Counter()
        let token = NotificationCenter.default.addObserver(
            forName: .cinemaxShouldRefreshCatalogue, object: controller, queue: nil
        ) { _ in refreshes.bump() }
        defer { NotificationCenter.default.removeObserver(token) }

        let launch = Task { await controller.evaluate(.launch) }
        await eventually { stub.calls == 1 }
        controller.sessionEnded()   // the launch's answer is dropped
        latch.open()
        await launch.value
        #expect(refreshes.count == 0)

        stub.set(latch: nil)
        await controller.evaluate(.serverChange)

        #expect(controller.route == .local)
        #expect(refreshes.count == 0, "no refresh owed by the ended session")
    }
}

/// The test host IS the app: on a signed device the shared extension session
/// is the widget's live one — put it back (root CLAUDE.md test RULE, T4).
@MainActor
private func preservingSharedExtensionSession(_ body: () async -> Void) async {
    let keychain = KeychainService()
    let original = keychain.readSharedSession()
    await body()
    if let original { keychain.saveSharedSession(original) } else { keychain.deleteSharedSession() }
}
