import CinemaxKit
import Foundation
import Network
import Observation

/// Live reachability state, injected into the environment so any screen can
/// branch on `isOnline` without each one spinning up its own `NWPathMonitor`.
///
/// `NWPathMonitor` reports status synchronously after `start(queue:)` — we
/// read the first path on init so the very first frame already knows whether
/// the user is online. Subsequent updates flip `isOnline` in real time.
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isOnline: Bool = true
    /// Whether this device can reach a LAN right now (Wi-Fi / wired), only
    /// cellular, or nothing. Plain stored property: no `didSet` (root RULE).
    private(set) var reach: NetworkReach = .offline
    /// Called on the main actor when the path SIGNATURE changes (Wi-Fi ⇄
    /// cellular, Wi-Fi ⇄ another Wi-Fi). Never called for the seed in `init`.
    @ObservationIgnored var onPathChange: (@MainActor () -> Void)?
    @ObservationIgnored private var lastSignature: String
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.cinemax.networkmonitor", qos: .utility)

    init() {
        lastSignature = ""
        monitor.pathUpdateHandler = { [weak self] path in
            // Debug / TestFlight builds only: every path CHANGE (Wi-Fi ⇄
            // cellular, constrained, lost) reaches the log the uploaded
            // diagnostics carry. A no-op for the App Store build.
            VerboseDiagnostics.notePath(path)
            let online = path.status == .satisfied
            let reach = Self.reach(path)
            let signature = Self.signature(of: path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOnline = online
                self.reach = reach
                guard signature != self.lastSignature else { return }
                self.lastSignature = signature
                self.onPathChange?()
            }
        }
        monitor.start(queue: queue)
        // Seed with the current path so the first SwiftUI render already
        // reflects reality. `currentPath` is populated synchronously after
        // start returns.
        isOnline = monitor.currentPath.status == .satisfied
        reach = Self.reach(monitor.currentPath)
        lastSignature = Self.signature(of: monitor.currentPath)
    }

    nonisolated static func reach(isSatisfied: Bool, usesWiFiOrWired: Bool) -> NetworkReach {
        guard isSatisfied else { return .offline }
        return usesWiFiOrWired ? .lanCapable : .cellularOnly
    }

    nonisolated private static func reach(_ path: NWPath) -> NetworkReach {
        reach(isSatisfied: path.status == .satisfied,
              usesWiFiOrWired: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
    }

    /// Status + interface-use flags + the gateways: a Wi-Fi ⇄ Wi-Fi move
    /// keeps every flag but changes the gateway. Compared, never logged
    /// (it carries addresses).
    nonisolated static func signature(of path: NWPath) -> String {
        let flags = [NWInterface.InterfaceType.wifi, .wiredEthernet, .cellular]
            .map { path.usesInterfaceType($0) ? "1" : "0" }.joined()
        return "\(path.status)|\(flags)|\(path.gateways.map { "\($0)" }.sorted().joined(separator: ","))"
    }

    deinit {
        monitor.cancel()
    }
}
