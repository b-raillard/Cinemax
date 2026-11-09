import Foundation
import CinemaxKit
import Observation
import OSLog

private let logger = Logger(subsystem: "com.cinemax", category: "Servers")

/// Why the route is being decided — the one detail a route-change log line
/// carries besides the class (never an address).
enum ServerRouteReason: String, Sendable {
    case launch, foreground, pathChange, serverChange, addressChanged
}

/// What a route change pushes beyond the API client: images, the libVLC
/// transport policy, the realtime socket. A seam so the tests stay off the
/// process-wide image table, the loopback proxy and its network probe.
struct RouteTransports {
    var setImageRoute: @MainActor (_ identity: URL?, _ dial: URL?) -> Void
    var configureStream: @MainActor (URL?) -> Void
    var repointSocket: @Sendable (RealtimeSocketEndpoint) async -> Void

    static var live: Self {
        Self(
            setImageRoute: { ImageRouteTable.shared.set(identity: $0, dial: $1) },
            configureStream: { StreamTransportPolicy.shared.configure(serverURL: $0) },
            repointSocket: { await JellyfinSocketHub.shared.repoint(endpoint: $0) }
        )
    }

    static var inert: Self {
        Self(setImageRoute: { _, _ in }, configureStream: { _ in }, repointSocket: { _ in })
    }
}

/// The ONE owner of the route: probes the active server's LAN address,
/// decides (`ServerRoutePolicy`), and pushes the dial URL into every transport —
/// API client, images, stream policy, socket. The public URL stays the
/// server's identity everywhere; only the transport dials the LAN.
///
/// Evaluated after the session is restored at launch (`AppState.prepareRoute`
/// → `scheduleLaunchEvaluation`, recorded synchronously so the launch's first
/// loads can wait for it through `awaitPendingProbe`),
/// on return to the foreground, on every network path change (identity first,
/// then the probe) and after every client rebuild (`AppState.onClientRepointed`,
/// which covers server AND account switches) and once each sign-in hold is
/// released. A no-op unless a session is established and no sign-in holds the
/// shared client: `setDialURL` cancels an in-flight sign-in.
@MainActor @Observable
final class ServerRouteController {
    static let shared = ServerRouteController()

    /// The LAN address being dialled; `nil` = the identity.
    private(set) var dialURL: URL?

    @ObservationIgnored var transports: RouteTransports = .live
    /// The evaluation last SCHEDULED (launch, path change, sign-in release),
    /// recorded before it starts — what `awaitPendingProbe` waits for.
    @ObservationIgnored private(set) var pendingEvaluation: Task<Void, Never>?

    private let probe: @Sendable (URL, TimeInterval) async -> LocalProbeOutcome
    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var reach: @MainActor () -> NetworkReach = { .offline }
    /// The identity `dialURL` was decided for (`transportURL(identity:)`).
    /// Observed like `dialURL`: the indication derives from both.
    private var dialIdentity: URL?
    /// Bumped by every evaluation and path change: a probe answer that is no
    /// longer the newest question is dropped.
    @ObservationIgnored private var evaluationGeneration = 0
    /// Bumped by every path change: a memoised decision belongs to one network.
    @ObservationIgnored private var pathGeneration = 0
    @ObservationIgnored private var memo: Memo?
    /// Evaluations past their gate and not yet over (applied or dropped), and
    /// who waits for the last of them (`awaitPendingProbe`).
    @ObservationIgnored private var evaluationsInFlight = 0
    @ObservationIgnored private var evaluationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var inFlightProbe: Task<LocalProbeOutcome, Never>?
    /// Socket repoints, chained so they reach the hub in decision order.
    @ObservationIgnored private var socketRepoint: Task<Void, Never>?
    /// A launch evaluation superseded (a path change right after launch) still
    /// owes the catalogue its refresh when the route it settles on is local.
    @ObservationIgnored private var owesLaunchRefresh = false

    /// How long `dialURL(for:)`'s decision stands for the same entry on the
    /// same network: one probe per switch.
    static let memoLifetime: TimeInterval = 10

    private struct Memo {
        let entryID: String
        let identity: URL
        let localURL: URL?
        let serverID: String?
        let pathGeneration: Int
        let dial: URL?
        let decidedAt: Date
    }

    private struct Session {
        let appState: AppState
        let entry: ServerEntry
    }

    init(probe: @escaping @Sendable (URL, TimeInterval) async -> LocalProbeOutcome = { url, timeout in
        await LocalRouteProbe.probe(url, timeout: timeout)
    }) {
        self.probe = probe
    }

    /// What the device's network can reach right now — the servers list's own
    /// LAN probes are decided against it (`ServersViewModel`).
    var currentReach: NetworkReach { reach() }

    func attach(appState: AppState, reach: @escaping @MainActor () -> NetworkReach) {
        self.appState = appState
        self.reach = reach
        appState.onSignInHoldReleased = { [weak self] in self?.signInHoldReleased() }
        appState.onSessionEnded = { [weak self] in self?.sessionEnded() }
    }

    /// The session ended (a logout, a confirmed-expired session): nothing is
    /// routed any more. The dial goes back to the identity, so no list or
    /// header reads a stale « Local » from a LAN dial while signed out; the memo and
    /// any evaluation still in flight belong to a session that is gone. The
    /// images and the stream policy, which a later sign-in's no-op `apply`
    /// would not touch, go back to the identity too.
    func sessionEnded() {
        evaluationGeneration &+= 1
        memo = nil
        // A refresh owed by the session that ended is not this one's to pay.
        owesLaunchRefresh = false
        let hadDial = dialURL != nil
        if hadDial { dialURL = nil }
        if dialIdentity != nil { dialIdentity = nil }
        guard hadDial else { return }
        transports.setImageRoute(nil, nil)
        transports.configureStream(appState?.serverURL)
        logger.notice("route → internet (reason: sessionEnded)")
    }

    // MARK: - Deciding

    /// Decides the active server's route and applies it. A no-op without an
    /// established session, and deferred while a sign-in holds the client (the
    /// hold's release evaluates). The answer is dropped when the active server
    /// moved, a server transition started (`serverTransitionGeneration`) or a
    /// newer evaluation started while the probe ran.
    func evaluate(_ reason: ServerRouteReason) async {
        guard case .open(let session) = gate() else { return }
        evaluationsInFlight += 1
        defer { evaluationEnded() }
        let entry = session.entry
        let transition = session.appState.serverTransitionGeneration
        evaluationGeneration &+= 1
        let generation = evaluationGeneration
        if reason == .launch { owesLaunchRefresh = true }

        let dial: URL?
        if reason == .serverChange, let remembered = memoised(for: entry) {
            // The switch already probed this target: reuse it, never a second probe.
            dial = remembered.dial
        } else {
            let timeout = reason == .launch ? LocalRouteProbe.launchTimeout : LocalRouteProbe.runtimeTimeout
            dial = await decide(for: entry, timeout: timeout)
        }

        guard generation == evaluationGeneration,
              case .open(let now) = gate(),
              now.appState.serverTransitionGeneration == transition
        else { return }
        let current = now.entry
        guard current.id == entry.id, current.url == entry.url,
              current.localURL == entry.localURL, current.serverID == entry.serverID
        else { return }
        apply(dial: dial, entry: current, reason: reason, settled: true)
    }

    /// The network changed: back on the identity AT ONCE (a LAN address from
    /// the previous network must not be dialled for a probe timeout), then
    /// probe and come back to the LAN if it still answers.
    func pathChanged() {
        pathGeneration &+= 1
        memo = nil
        // A probe started on the previous network answers for that network.
        evaluationGeneration &+= 1
        // Held by a sign-in: the client is not touched now; the release
        // evaluates. No `await` between this gate and `apply`, so no transition
        // can slip in between.
        guard case .open(let session) = gate() else { return }
        apply(dial: nil, entry: session.entry, reason: .pathChange, settled: false)
        pendingEvaluation = Task { [self] in await evaluate(.pathChange) }
    }

    /// The URL to dial for ANY registered entry — a switch target, a re-login.
    /// Decides only, never pushes; memoised for `memoLifetime` on this network.
    func dialURL(for entry: ServerEntry) async -> URL {
        if let remembered = memoised(for: entry) { return remembered.dial ?? entry.url }
        let generation = pathGeneration
        let dial = await decide(for: entry, timeout: LocalRouteProbe.runtimeTimeout)
        if generation == pathGeneration {
            memo = Memo(entryID: entry.id, identity: entry.url, localURL: entry.localURL,
                        serverID: entry.serverID, pathGeneration: generation, dial: dial, decidedAt: Date())
        }
        return dial ?? entry.url
    }

    /// The dial URL when it belongs to `identity`, else `identity` itself.
    func transportURL(identity: URL?) -> URL? {
        guard let identity else { return nil }
        if let dialURL, dialIdentity == identity { return dialURL }
        return identity
    }

    // MARK: - The indication (« Local » / « Internet »)

    /// The URL `entry` is dialled on right now: the LAN dial while it belongs
    /// to this entry's identity, else the identity itself.
    func effectiveDialURL(for entry: ServerEntry) -> URL {
        transportURL(identity: entry.url) ?? entry.url
    }

    /// « Local » / « Internet » of what `entry` is dialled on, DERIVED FROM
    /// THE HOST (spec: never a stored flag) — a server whose only URL is
    /// already `http://192.168.x.y` reads « Local » with no local address.
    func routeKind(for entry: ServerEntry) -> ServerRouteKind {
        ServerRoutePolicy.kind(ofDialURL: effectiveDialURL(for: entry))
    }

    /// The URL the ACTIVE server is dialled on (its entry, else the session's
    /// identity); `nil` with no server at all. Read by Settings' route line.
    var activeDialURL: URL? {
        transportURL(identity: activeAddresses?.identity ?? appState?.serverURL)
    }

    /// The ACTIVE server's indication — the servers list's active card,
    /// Settings and the diagnostics header all read this one derivation.
    var route: ServerRouteKind {
        activeDialURL.map(ServerRoutePolicy.kind(ofDialURL:)) ?? .internet
    }

    /// Waits until the route a playback — or one of the launch's first loads
    /// (Home, the library views, the remote-control socket) — is about to use
    /// is DECIDED AND APPLIED, so it never goes out on a route about to be
    /// abandoned. Not only the probe: the probe's own continuation (→ `apply`
    /// → `setDialURL`) and this one both resume on the main actor in no
    /// guaranteed order. So it also waits for the evaluation the launch, a
    /// path change or a sign-in release has scheduled (`pendingEvaluation`,
    /// possibly not started yet — and the one replacing it while waited for)
    /// and for every evaluation past its gate to end. Each is bounded by its
    /// probe's timeout (launch 1 s, none on cellular); returns at once when
    /// nothing is pending.
    func awaitPendingProbe() async {
        if let inFlightProbe { _ = await inFlightProbe.value }
        var awaited: Task<Void, Never>?
        while let pending = pendingEvaluation, pending != awaited {
            awaited = pending
            await pending.value
        }
        guard evaluationsInFlight > 0 else { return }
        await withCheckedContinuation { evaluationWaiters.append($0) }
    }

    private func evaluationEnded() {
        evaluationsInFlight -= 1
        guard evaluationsInFlight == 0, !evaluationWaiters.isEmpty else { return }
        let waiters = evaluationWaiters
        evaluationWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// The ACTIVE server's identity and LAN address, whatever the current
    /// route — what the native engine needs to never play a LAN URL
    /// (`NativeVideoPresenter.nativePlayURL`), even once the dial has gone back
    /// to the identity.
    var activeAddresses: (identity: URL, local: URL?)? {
        guard let appState, let id = appState.activeServerId,
              let entry = appState.servers.first(where: { $0.id == id }) else { return nil }
        return (entry.url, entry.localURL)
    }

    // MARK: - Private

    private enum Gate {
        /// No session: nothing to route.
        case closed
        /// A sign-in is using the shared client: nothing may rebuild it now.
        case held
        case open(Session)
    }

    /// Open only while a session is established AND no sign-in holds the
    /// client. `isAuthenticated` is false through the login screen's sign-in
    /// (until `completeSession`'s last line) and after `beginReLogin` /
    /// `beginAddServer`; the hold (`AppState.signInsInFlight`) covers the rest:
    /// `beginReLogin`'s handshake (the session still reads as the previous
    /// server's), the add-account sign-ins (password and Quick Connect) and
    /// `UserSwitchSheet`, all run while signed in. A `setDialURL` there would
    /// cancel the exchange or send the credentials down the wrong route.
    private func gate() -> Gate {
        guard let appState else { return .closed }
        if appState.isSignInInFlight { return .held }
        guard appState.isAuthenticated,
              let id = appState.activeServerId,
              let entry = appState.servers.first(where: { $0.id == id }) else { return .closed }
        return .open(Session(appState: appState, entry: entry))
    }

    /// The launch evaluation (`AppState.restoreSession`), recorded as
    /// `pendingEvaluation` BEFORE it starts: a load issued right after the
    /// session is restored waits for it (`awaitPendingProbe`) instead of
    /// going out on the identity ahead of the ~1 s probe.
    func scheduleLaunchEvaluation() -> Task<Void, Never> {
        let task = Task { [self] in await evaluate(.launch) }
        pendingEvaluation = task
        return task
    }

    /// The last sign-in hold is released: ONE evaluation — whatever was
    /// deferred meanwhile, and the route of a session that sign-in has just
    /// established (a first sign-in at home goes local right away).
    private func signInHoldReleased() {
        pendingEvaluation = Task { [self] in await evaluate(.serverChange) }
    }

    private func decide(for entry: ServerEntry, timeout: TimeInterval) async -> URL? {
        let reach = reach()
        guard ServerRoutePolicy.shouldProbe(localURL: entry.localURL, reach: reach),
              let local = entry.localURL, local.scheme?.lowercased() == "https",
              let serverID = entry.serverID, !serverID.isEmpty else { return nil }
        let outcome = await runProbe(local, timeout: timeout)
        return ServerRoutePolicy.decide(localURL: local, reach: reach, expectedServerID: serverID, probe: outcome)
    }

    private func runProbe(_ url: URL, timeout: TimeInterval) async -> LocalProbeOutcome {
        let probe = self.probe
        let task = Task<LocalProbeOutcome, Never> { await probe(url, timeout) }
        inFlightProbe = task
        let outcome = await task.value
        if inFlightProbe == task { inFlightProbe = nil }
        return outcome
    }

    private func memoised(for entry: ServerEntry) -> Memo? {
        guard let memo, memo.entryID == entry.id, memo.identity == entry.url,
              memo.localURL == entry.localURL, memo.serverID == entry.serverID,
              memo.pathGeneration == pathGeneration,
              Date().timeIntervalSince(memo.decidedAt) < Self.memoLifetime else { return nil }
        return memo
    }

    /// Pushes `dial` into every transport — a true no-op when the client
    /// already dials it. Compared against the CLIENT, not this controller's
    /// own record: a `reconnect` silently resets the client to the identity.
    /// `settled` = the answer of a probe (or a skipped one), not the
    /// path-change fallback.
    private func apply(dial: URL?, entry: ServerEntry, reason: ServerRouteReason, settled: Bool) {
        guard let appState else { return }
        let client = appState.apiClient
        let owedRefresh = owesLaunchRefresh
        if settled { owesLaunchRefresh = false }
        // The class of what is dialled, from its host — as the indication.
        let kind = ServerRoutePolicy.kind(ofDialURL: dial ?? entry.url)
        let previousDial = dialURL
        let previousIdentity = dialIdentity
        if dialURL != dial { dialURL = dial }
        let identity = dial == nil ? nil : entry.url
        if dialIdentity != identity { dialIdentity = identity }

        // Unchanged only when BOTH agree: the client (a `reconnect` resets it
        // to the identity behind this controller's back) and what was last
        // pushed to the other transports (images, stream, socket), which a
        // `reconnect` does not reset.
        let transportDial = client.currentDialURL().flatMap { $0 == entry.url ? nil : $0 }
        let pushedUnchanged = previousDial == dial && (dial == nil || previousIdentity == entry.url)
        guard transportDial != dial || !pushedUnchanged else { return }

        // Bound to the identity it was decided for: refused by the client if
        // a transition has pointed it at another server meanwhile.
        client.setDialURL(dial, forIdentity: entry.url)
        transports.setImageRoute(entry.url, dial)
        transports.configureStream(dial ?? entry.url)
        // Built AFTER `setDialURL`: the endpoint is derived from the installed dial.
        if let endpoint = client.makeRealtimeSocketEndpoint() {
            let previous = socketRepoint
            let repoint = transports.repointSocket
            socketRepoint = Task {
                await previous?.value
                await repoint(endpoint)
            }
        }
        logger.notice("route → \(kind.rawValue, privacy: .public) (reason: \(reason.rawValue, privacy: .public))")
        // A first load may have gone to a dead public URL (tunnel down) — one
        // that did not wait for this route. Home, which waits, skips it when
        // its load already went out on this dial (`HomeViewModel.needsRouteReload`).
        if dial != nil, settled, reason == .launch || owedRefresh {
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: self)
        }
    }
}
