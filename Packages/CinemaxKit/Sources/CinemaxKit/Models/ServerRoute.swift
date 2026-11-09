import Foundation

/// Which road a request travelled: the LAN address or the public one.
public enum ServerRouteKind: String, Sendable { case local, internet }

/// What the device's network can reach, as far as a LAN probe is concerned.
public enum NetworkReach: Sendable, Equatable { case lanCapable, cellularOnly, offline }

public enum LocalProbeOutcome: Equatable, Sendable {
    case answered(serverID: String, connectedAddressIsLocal: Bool)
    case failed(localNetworkDenied: Bool)
}

/// Pure route decisions. The public URL is the server's identity; the LAN
/// address is only ever a faster road to the SAME server, proven by its `Id`.
public enum ServerRoutePolicy {
    public static func shouldProbe(localURL: URL?, reach: NetworkReach) -> Bool {
        localURL != nil && reach == .lanCapable
    }

    /// The URL to dial; nil = dial the public URL. The token only goes to a
    /// machine that proved it is the expected server, over a local connection.
    public static func decide(
        localURL: URL?,
        reach: NetworkReach,
        expectedServerID: String?,
        probe: LocalProbeOutcome?
    ) -> URL? {
        guard let localURL, reach == .lanCapable,
              let expectedServerID, !expectedServerID.isEmpty,
              case .answered(let serverID, let isLocal)? = probe,
              isLocal, serverID == expectedServerID else { return nil }
        return localURL
    }

    public static func kind(ofDialURL url: URL) -> ServerRouteKind {
        guard let host = url.host(percentEncoded: false) else { return .internet }
        return LocalNetworkAddress.isEligibleHost(host) ? .local : .internet
    }

    /// Swaps identity base → dial base; nil when `url` is not under the identity base.
    public static func rewrite(_ url: URL, identityBase: URL, dialBase: URL) -> URL? {
        guard isSameOrigin(url, identityBase),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let dial = URLComponents(url: dialBase, resolvingAgainstBaseURL: false)
        else { return nil }
        let identityPath = trimmedPath(identityBase)
        let path = components.percentEncodedPath
        let remainder: String
        if identityPath.isEmpty {
            remainder = path
        } else if path == identityPath {
            remainder = ""
        } else if path.hasPrefix(identityPath + "/") {
            remainder = String(path.dropFirst(identityPath.count))
        } else {
            return nil
        }
        components.scheme = dial.scheme
        components.percentEncodedHost = dial.percentEncodedHost
        components.port = dial.port
        components.percentEncodedPath = trimmedPath(dialBase) + remainder
        return components.url
    }

    /// scheme + host + effective port.
    public static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let ls = lhs.scheme?.lowercased(), let rs = rhs.scheme?.lowercased(),
              let lh = lhs.host(percentEncoded: false)?.lowercased(),
              let rh = rhs.host(percentEncoded: false)?.lowercased() else { return false }
        return ls == rs && lh == rh && effectivePort(lhs, scheme: ls) == effectivePort(rhs, scheme: rs)
    }

    private static func effectivePort(_ url: URL, scheme: String) -> Int? {
        url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
    }

    private static func trimmedPath(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
