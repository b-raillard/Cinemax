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
}
