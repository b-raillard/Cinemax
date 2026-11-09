import Foundation
#if !CINEMAX_EXTENSION
// App targets only (they carry this file so their test bundles can test it):
// `LocalNetworkAddress` lives in CinemaxKit there. The extensions link no
// package and compile `LocalNetworkAddress.swift` from source instead. NOT
// `canImport(CinemaxKit)`: that is TRUE in an extension too (the module sits in
// the shared build products), and importing it there fails the build on the
// package's swift-nio C shims.
import CinemaxKit
#endif

/// « At home, the LAN first » inside the widget and the Top Shelf: which base
/// URL a timeline / a shelf refresh dials.
///
/// The extensions link none of our frameworks, so this is their own small copy
/// of the app's `LocalRouteProbe` + `ServerRoutePolicy.decide`, with the same
/// rules: an unauthenticated `GET <local>/System/Info/Public`, no token, no
/// redirect followed, the answer's `Id` must be the expected server's and the
/// socket must really have reached a local peer (`LocalNetworkAddress.isLocal`).
/// The public URL stays the server's identity; the LAN is only a faster road.
///
/// Shared BY SOURCE (listed in both extensions and both apps, like
/// `ExtensionServerTrust.swift`): the app targets carry it only for the tests.
/// Never logs an address.
enum ExtensionServerRoute {
    static let probeTimeout: TimeInterval = 1.0

    /// What a dialled session fetches from, and the certificate pin that goes
    /// with THAT address — the LAN certificate is pinned on the LAN host:port,
    /// the public one on the public host:port.
    struct Endpoint: Equatable, Sendable {
        let serverURL: URL
        let pinnedCertificateSHA256: String?
    }

    /// The URL to dial: `localURL` when the probe proves it is the expected
    /// server over a local connection, `publicURL` otherwise. A missing or
    /// non-https LAN address, or no known server id, answers at once.
    static func dialURL(publicURL: URL, localURL: URL?, serverID: String?, localPin: String?) async -> URL {
        guard let localURL, localURL.scheme?.lowercased() == "https",
              let serverID, !serverID.isEmpty,
              let endpoint = probeURL(for: localURL) else { return publicURL }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = probeTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let session = makeSession(pin: ExtensionServerTrust.pin(serverURL: localURL, fingerprint: localPin))
        defer { session.finishTasksAndInvalidate() }
        let collector = MetricsCollector()
        guard let (data, response) = try? await session.data(for: request, delegate: collector),
              let http = response as? HTTPURLResponse else { return publicURL }
        let connected = collector.remoteAddress ?? ipLiteralHost(of: localURL)
        return accepts(statusCode: http.statusCode, body: data, serverID: serverID, connectedAddress: connected)
            ? localURL : publicURL
    }

    /// Pure: whether a probe answer proves the LAN address is the expected
    /// server, reached over a local connection. An unknown peer is not local.
    static func accepts(statusCode: Int, body: Data, serverID: String, connectedAddress: String?) -> Bool {
        guard statusCode == 200, !serverID.isEmpty,
              let connectedAddress, LocalNetworkAddress.isLocal(connectedAddress),
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let id = object["Id"] as? String else { return false }
        return id == serverID
    }

    /// Pure: the base URL and pin a session dialled at `dialURL` fetches with.
    static func endpoint(publicURL: URL, publicPin: String?, dialURL: URL, localPin: String?) -> Endpoint {
        dialURL == publicURL
            ? Endpoint(serverURL: publicURL, pinnedCertificateSHA256: publicPin)
            : Endpoint(serverURL: dialURL, pinnedCertificateSHA256: localPin)
    }

    /// The route class, for logs — never the address.
    static func routeClass(publicURL: URL, dialURL: URL) -> String {
        dialURL == publicURL ? "internet" : "local"
    }

    private static func probeURL(for localURL: URL) -> URL? {
        guard var components = URLComponents(url: localURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = endpointPath("/System/Info/Public", serverURL: localURL)
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func ipLiteralHost(of url: URL) -> String? {
        guard let host = url.host(percentEncoded: false),
              LocalNetworkAddress.kind(ofLiteral: host) != .notAnIPLiteral else { return nil }
        return host
    }

    /// Ephemeral, cache-less, and NEVER on cellular: « no probe on 4G » is
    /// structural, not a reachability check. The session delegate honours the
    /// LAN certificate the user approved in the app (its own host:port pin).
    private static func makeSession(pin: ExtensionServerTrust.Pin?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = probeTimeout
        configuration.timeoutIntervalForResource = probeTimeout
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let trust = ExtensionServerTrust { pin }
        return URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }

    /// Sets the request path while preserving the LAN address's base path.
    /// Mirrors `URLComponents.setEndpointPath` in CinemaxKit — this file's own
    /// copy, since the extensions cannot link the package.
    private static func endpointPath(_ endpoint: String, serverURL: URL) -> String {
        let base = serverURL.path
        if base.isEmpty || base == "/" { return endpoint }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return trimmed + endpoint
    }

    /// Per-task: refuses every redirect and records the peer address of the
    /// last transaction. Implements no challenge callback, so the TLS
    /// challenge falls back to the session's `ExtensionServerTrust`.
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
