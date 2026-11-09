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
/// Evaluated after the session is restored at launch (`AppState.prepareRoute`),
/// on return to the foreground, on every network path change (identity first,
/// then the probe) and after every client rebuild (`AppState.onClientRepointed`,
/// which covers server AND account switches). A no-op unless a session is
/// established: `setDialURL` cancels an in-flight sign-in, so nothing is ever
/// pushed while `AppState.isAuthenticated` is false.
@MainActor @Observable
final class ServerRouteController {
    static let shared = ServerRouteController()

    /// The ACTIVE server's route, read by the servers list, Settings and the
    /// diagnostics header.
    private(set) var route: ServerRouteKind = .internet
    /// The LAN address being dialled; `nil` = the identity.
    private(set) var dialURL: URL?

    @ObservationIgnored var transports: RouteTransports = .live
    /// The evaluation `pathChanged()` started — awaited by the tests.
    @ObservationIgnored private(set) var pendingEvaluation: Task<Void, Never>?

    private let probe: @Sendable (URL, TimeInterval) async -> LocalProbeOutcome
    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var reach: @MainActor () -> NetworkReach = { .offline }
    /// The identity `dialURL` was decided for (`transportURL(identity:)`).
    @ObservationIgnored private var dialIdentity: URL?
    /// Bumped by every evaluation and path change: a probe answer that is no
    /// longer the newest question is dropped.
    @ObservationIgnored private var evaluationGeneration = 0
    /// Bumped by every path change: a memoised decision belongs to one network.
    @ObservationIgnored private var pathGeneration = 0
    @ObservationIgnored private var memo: Memo?
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

    func attach(appState: AppState, reach: @escaping @MainActor () -> NetworkReach) {
        self.appState = appState
        self.reach = reach
    }

    // MARK: - Deciding

    /// Decides the active server's route and applies it. A no-op without an
    /// established session; the answer is dropped when the active server moved
    /// or a newer evaluation started while the probe ran.
    func evaluate(_ reason: ServerRouteReason) async {
        guard let session = establishedSession() else { return }
        let entry = session.entry
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
              let current = establishedSession()?.entry,
              current.id == entry.id, current.url == entry.url,
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
        guard let session = establishedSession() else { return }
        // A probe started on the previous network answers for that network.
        evaluationGeneration &+= 1
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

    /// Waits for a probe in flight, bounded by that probe's own timeout — so a
    /// playback never opens on a route about to be abandoned.
    func awaitPendingProbe() async {
        guard let inFlightProbe else { return }
        _ = await inFlightProbe.value
    }

    // MARK: - Private

    /// The active entry, only while a session is established. `isAuthenticated`
    /// is false through every sign-in (`beginReLogin`, `beginAddServer`, the
    /// login screen until `completeSession`'s last line), which is exactly
    /// when a `setDialURL` would cancel the login in flight.
    private func establishedSession() -> Session? {
        guard let appState, appState.isAuthenticated,
              let id = appState.activeServerId,
              let entry = appState.servers.first(where: { $0.id == id }) else { return nil }
        return Session(appState: appState, entry: entry)
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
        let kind: ServerRouteKind = dial == nil ? .internet : .local
        let previousDial = dialURL
        let previousIdentity = dialIdentity
        if dialURL != dial { dialURL = dial }
        if route != kind { route = kind }
        dialIdentity = dial == nil ? nil : entry.url

        // Unchanged only when BOTH agree: the client (a `reconnect` resets it
        // to the identity behind this controller's back) and what was last
        // pushed to the other transports (images, stream, socket), which a
        // `reconnect` does not reset.
        let transportDial = client.currentDialURL().flatMap { $0 == entry.url ? nil : $0 }
        let pushedUnchanged = previousDial == dial && (dial == nil || previousIdentity == entry.url)
        guard transportDial != dial || !pushedUnchanged else { return }

        client.setDialURL(dial)
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
        // Home's first load may have gone to a dead public URL (tunnel down).
        if dial != nil, settled, reason == .launch || owedRefresh {
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: self)
        }
    }
}
