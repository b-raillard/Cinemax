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
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.cinemax.networkmonitor", qos: .utility)

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
        // Seed with the current path so the first SwiftUI render already
        // reflects reality. `currentPath` is populated synchronously after
        // start returns.
        isOnline = monitor.currentPath.status == .satisfied
    }

    deinit {
        monitor.cancel()
    }
}
