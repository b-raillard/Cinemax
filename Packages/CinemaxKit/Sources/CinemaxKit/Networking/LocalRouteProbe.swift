import Foundation

/// Unauthenticated check that the LAN address reaches the expected server:
/// `GET <local>/System/Info/Public`, no `Authorization`, no redirect followed.
/// It reports the server `Id` and whether the socket really went to a local
/// peer; `ServerRoutePolicy.decide` turns that into a route. Never logs an address.
public enum LocalRouteProbe {
    public static let launchTimeout: TimeInterval = 1.0
    public static let runtimeTimeout: TimeInterval = 1.5

    public static func probe(_ localURL: URL, timeout: TimeInterval, session: URLSession? = nil) async -> LocalProbeOutcome {
        guard var components = URLComponents(url: localURL, resolvingAgainstBaseURL: false) else {
            return .failed(localNetworkDenied: false)
        }
        components.setEndpointPath("/System/Info/Public", preservingBasePathOf: localURL)
        components.query = nil
        components.fragment = nil
        guard let endpoint = components.url else { return .failed(localNetworkDenied: false) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let owned = session == nil
        let activeSession = session ?? makeSession(timeout: timeout)
        defer { if owned { activeSession.finishTasksAndInvalidate() } }

        let collector = MetricsCollector()
        do {
            let (data, response) = try await activeSession.data(for: request, delegate: collector)
            guard let http = response as? HTTPURLResponse else { return .failed(localNetworkDenied: false) }
            let connected = collector.remoteAddress ?? ipLiteralHost(of: localURL)
            return evaluate(statusCode: http.statusCode, body: data, connectedAddress: connected)
        } catch {
            return .failed(localNetworkDenied: false)
        }
    }

    static func evaluate(statusCode: Int, body: Data, connectedAddress: String?) -> LocalProbeOutcome {
        guard statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let id = object["Id"] as? String, !id.isEmpty else {
            return .failed(localNetworkDenied: false)
        }
        let isLocal = connectedAddress.map(LocalNetworkAddress.isLocal) ?? false
        return .answered(serverID: id, connectedAddressIsLocal: isLocal)
    }

    private static func ipLiteralHost(of url: URL) -> String? {
        guard let host = url.host(percentEncoded: false),
              LocalNetworkAddress.kind(ofLiteral: host) != .notAnIPLiteral else { return nil }
        return host
    }

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Session delegate: certificate pinning / self-signed approval go through
        // the normal trust path (the per-task delegate falls back to it).
        return URLSession(configuration: configuration, delegate: ServerTrustDelegate.shared, delegateQueue: nil)
    }

    /// Refuses every redirect and records the peer address of the last transaction.
    private final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var address: String?

        var remoteAddress: String? {
            lock.lock()
            defer { lock.unlock() }
            return address
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            let value = metrics.transactionMetrics.last?.remoteAddress
            lock.lock()
            address = value
            lock.unlock()
        }
    }
}
