import Darwin
import Foundation

// Shared BY SOURCE with the Widget and the Top Shelf (listed in their `sources`
// in project.yml): keep this file importing Foundation and Darwin alone.

/// Pure classification of an IP literal, and the one definition of "local"
/// (IPv4 `10/8`, `172.16/12`, `192.168/16`, `169.254/16`; IPv6 `fc00::/7`,
/// `fe80::/10`). Loopback and the CGNAT range `100.64/10` are NOT local.
public enum LocalNetworkAddress {
    public enum Kind: Equatable, Sendable {
        case privateIPv4, linkLocalIPv4, cgnatIPv4, loopbackIPv4, publicIPv4
        case uniqueLocalIPv6, linkLocalIPv6, loopbackIPv6, publicIPv6
        case notAnIPLiteral
    }

    /// Accepts bracketed IPv6 (`[fd00::1]`) and a zone suffix (`fe80::1%en0`).
    public static func kind(ofLiteral literal: String) -> Kind {
        var text = literal
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
        guard !text.isEmpty else { return .notAnIPLiteral }

        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return classify(v4: bytes)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return classify(v6: bytes)
        }
        return .notAnIPLiteral
    }

    public static func isLocal(_ literal: String) -> Bool {
        switch kind(ofLiteral: literal) {
        case .privateIPv4, .linkLocalIPv4, .uniqueLocalIPv6, .linkLocalIPv6: return true
        default: return false
        }
    }

    /// `something.local` — at least one label before the suffix.
    public static func isMDNSName(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower.hasSuffix(".local") && lower.count > ".local".count
    }

    public static func isEligibleHost(_ host: String) -> Bool {
        isLocal(host) || isMDNSName(host)
    }

    private static func classify(v4 b: [UInt8]) -> Kind {
        switch (b[0], b[1]) {
        case (10, _), (192, 168), (172, 16...31): return .privateIPv4
        case (169, 254): return .linkLocalIPv4
        case (100, 64...127): return .cgnatIPv4
        case (127, _): return .loopbackIPv4
        default: return .publicIPv4
        }
    }

    private static func classify(v6 b: [UInt8]) -> Kind {
        if b.dropLast().allSatisfy({ $0 == 0 }), b[15] == 1 { return .loopbackIPv6 }
        if b[0] & 0xFE == 0xFC { return .uniqueLocalIPv6 }
        if b[0] == 0xFE, b[1] & 0xC0 == 0x80 { return .linkLocalIPv6 }
        return .publicIPv6
    }
}
