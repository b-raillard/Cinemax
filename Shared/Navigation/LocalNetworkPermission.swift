import Foundation
#if os(iOS)
import Network
#endif

/// Whether iOS's « Réseau local » permission is what kept a LAN address from
/// answering. Asked only after a failed save probe, to word its toast. An
/// `NWConnection` to the address's host:port: denied when it enters `.waiting`
/// with `unsatisfiedReason == .localNetworkDenied`, bounded at `timeout`.
/// tvOS has no such permission: always `false`. Never logs an address.
enum LocalNetworkPermission {
    static let timeout: TimeInterval = 1

    static func isDenied(_ url: URL) async -> Bool {
        #if os(iOS)
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        let portNumber = url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
        guard (1...Int(UInt16.max)).contains(portNumber),
              let port = NWEndpoint.Port(rawValue: UInt16(portNumber)) else { return false }
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let queue = DispatchQueue(label: "com.cinemax.local-network-permission")
        let answer = OneShot()
        let denied = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            answer.arm(continuation)
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .waiting:
                    answer.resume(connection.currentPath?.unsatisfiedReason == .localNetworkDenied)
                case .ready, .failed, .cancelled:
                    answer.resume(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { answer.resume(false) }
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        return denied
        #else
        return false
        #endif
    }
}

#if os(iOS)
/// Resumes its continuation once: the state handler fires repeatedly and races
/// the timeout, and a second resume would trap.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    func arm(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ value: Bool) {
        let pending: CheckedContinuation<Bool, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
#endif
