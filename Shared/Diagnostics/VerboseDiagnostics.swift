import Foundation
import Network
import OSLog
import os

private let networkLog = Logger(subsystem: "com.cinemax", category: "Network")
private let lifecycleLog = Logger(subsystem: "com.cinemax", category: "Lifecycle")

/// Extra diagnostics for the builds whose Settings → Debug page is visible —
/// Xcode and TestFlight — and NEVER for the App Store build.
///
/// **Why it exists** (2026-11-09): an iPhone lost its stream through the
/// Cloudflare tunnel and retried for seven minutes, and the two documents it
/// uploaded could not say why. Nothing told whether the phone had changed
/// network (Wi-Fi → cellular), whether the user had left the app or it had
/// died, whether bytes still flowed after the relay took over, or who closed
/// the HTTP/2 stream — and the minutes after the first fault were lost with
/// the process the user killed. Each hook here answers one of those, and all
/// of them stay silent unless `isEnabled`.
///
/// **One switch, set at the app root** (`AppNavigation`) with the SAME
/// decision as the Debug page (`SettingsCategory.showsDebug`): a Debug build
/// always, otherwise only a CONFIRMED test environment. Unknown ⇒ off, so an
/// App Store install never pays for it. Read from any thread — the network
/// monitor's queue, the proxy's URLSession queue, the libVLC log task — hence
/// the lock rather than an actor.
enum VerboseDiagnostics {
    private struct State: Sendable {
        var enabled = false
        var environment: String?
        var lastPath: String?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Seconds between two `CINEMAX-FEED` lines of the VLC heartbeat.
    static let feedSampleSeconds = 10

    static var isEnabled: Bool { state.withLock { $0.enabled } }

    /// The build's test environment, for the uploaded report's header.
    static var environmentLabel: String? { state.withLock { $0.environment } }

    /// The last network path seen, for the uploaded report's header.
    static var networkSummary: String? { state.withLock { $0.lastPath } }

    /// Called by the app root whenever the decision may have changed (launch,
    /// then the App Store's verified answer). Turning it on logs the path the
    /// monitor saw before the switch flipped — the launch path is otherwise
    /// never written, the monitor having reported it before anyone listened.
    static func setEnabled(_ on: Bool, environment: String) {
        let (wasEnabled, path) = state.withLock { s -> (Bool, String?) in
            let was = s.enabled
            s.enabled = on
            s.environment = on ? environment : nil
            return (was, s.lastPath)
        }
        guard on, !wasEnabled else { return }
        lifecycleLog.notice("""
            diagnostics détaillés ▸ actifs (\(environment, privacy: .public)) \
            réseau=\(path ?? "inconnu", privacy: .public)
            """)
    }

    /// Every `NWPathMonitor` update. The summary is ALWAYS remembered (cheap,
    /// and the report header wants it) but logged only when it changed and the
    /// switch is on: the monitor repeats identical paths.
    static func notePath(_ path: NWPath) {
        let summary = PathFacts(path).summary
        let (changed, enabled) = state.withLock { s -> (Bool, Bool) in
            let changed = s.lastPath != summary
            s.lastPath = summary
            return (changed, s.enabled)
        }
        guard changed, enabled else { return }
        networkLog.notice("réseau ▸ \(summary, privacy: .public)")
    }

    /// A scene-phase change: tells "the user left the app" (`background`, the
    /// socket then closes cleanly) from "the app died" (no line, the next one
    /// is a fresh launch) when reading a log after the fact.
    static func notePhase(_ phase: String) {
        guard isEnabled else { return }
        lifecycleLog.notice("cycle de vie ▸ \(phase, privacy: .public)")
    }

    /// Pure. libVLC's HTTP/2 access dumps every frame at debug level
    /// (`"%s %s (0x%02hhx) frame of %zu bytes, flags 0x%02hhx, stream %u"`,
    /// e.g. `in RST_STREAM (0x03) frame of 4 bytes, flags 0x00, stream 43`).
    /// Kept: every frame EXCEPT the two that carry the bulk of a stream
    /// (`DATA`, `WINDOW_UPDATE`) — so a `GOAWAY` or `RST_STREAM` from the edge,
    /// the responses' `HEADERS` and the `PING`s show up, at a few lines per
    /// request instead of dozens per second.
    static func libVLCFrameLine(_ message: String) -> String? {
        guard message.contains(" frame of ") else { return nil }
        let words = message.split(separator: " ", maxSplits: 2)
        guard words.count >= 2, words[0] == "in" || words[0] == "out" else { return nil }
        if words[1] == "DATA" || words[1] == "WINDOW_UPDATE" { return nil }
        return message
    }

    /// Pure. The phone's LOCAL address reduced to what a diagnosis needs —
    /// which network it sat on — never the address itself, since the document
    /// travels to a server log: a private IPv4 keeps its /24 (the home LAN
    /// reads `192.168.1.0/24`, a carrier's NAT another one), the shared
    /// carrier range is `cgnat`, the rest is a class. `cellular=` in the same
    /// line already says which interface carried the request.
    static func localAddressClass(_ address: String?) -> String? {
        guard let address, !address.isEmpty else { return nil }
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4, !address.contains(":") {
            let (a, b) = (octets[0], octets[1])
            switch (a, b) {
            case (10, _), (192, 168), (172, 16...31):
                return "\(a).\(b).\(octets[2]).0/24"
            case (100, 64...127): return "cgnat"
            case (169, 254): return "link-local"
            case (127, _): return "loopback"
            default: return "public-ipv4"
            }
        }
        let lower = address.lowercased()
        if lower == "::1" { return "loopback" }
        if lower.hasPrefix("fe80") { return "link-local-ipv6" }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return "ula-ipv6" }
        return "public-ipv6"
    }

    fileprivate static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
}

// MARK: - Network path

extension VerboseDiagnostics {
    /// What a network path says, as one greppable line. `interfaces` is in the
    /// system's preference order, so the first one is the interface traffic
    /// actually takes — `via=cellular` while `wifi` is still listed is Wi-Fi
    /// Assist at work.
    struct PathFacts: Equatable {
        var status: String
        var interfaces: [String]
        var isExpensive: Bool
        var isConstrained: Bool
        var supportsIPv4: Bool
        var supportsIPv6: Bool
        var supportsDNS: Bool
        var unsatisfiedReason: String?

        var summary: String {
            var parts = [status]
            if let unsatisfiedReason { parts.append("reason=\(unsatisfiedReason)") }
            parts.append("via=\(interfaces.first ?? "none")")
            parts.append("interfaces=\(interfaces.isEmpty ? "none" : interfaces.joined(separator: ","))")
            parts.append("expensive=\(VerboseDiagnostics.yesNo(isExpensive))")
            parts.append("constrained=\(VerboseDiagnostics.yesNo(isConstrained))")
            parts.append("ipv4=\(VerboseDiagnostics.yesNo(supportsIPv4)) ipv6=\(VerboseDiagnostics.yesNo(supportsIPv6)) dns=\(VerboseDiagnostics.yesNo(supportsDNS))")
            return parts.joined(separator: " ")
        }
    }
}

private extension VerboseDiagnostics.PathFacts {
    init(_ path: NWPath) {
        self.init(
            status: Self.describe(path.status),
            interfaces: path.availableInterfaces.map { Self.describe($0.type) },
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            supportsDNS: path.supportsDNS,
            unsatisfiedReason: path.status == .satisfied ? nil : Self.describe(path.unsatisfiedReason)
        )
    }

    static func describe(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied: "satisfied"
        case .unsatisfied: "unsatisfied"
        case .requiresConnection: "requiresConnection"
        @unknown default: "unknown"
        }
    }

    static func describe(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: "wifi"
        case .cellular: "cellular"
        case .wiredEthernet: "ethernet"
        case .loopback: "loopback"
        case .other: "other"
        @unknown default: "unknown"
        }
    }

    static func describe(_ reason: NWPath.UnsatisfiedReason) -> String {
        switch reason {
        case .notAvailable: "notAvailable"
        case .cellularDenied: "cellularDenied"
        case .wifiDenied: "wifiDenied"
        case .localNetworkDenied: "localNetworkDenied"
        case .vpnInactive: "vpnInactive"
        @unknown default: "unknown"
        }
    }
}

// MARK: - Feed sample (VLC heartbeat)

extension VerboseDiagnostics {
    /// One line every `feedSampleSeconds` while the VLC player is open:
    /// whether bytes still arrive, on which route, and whether the picture
    /// moves — the three facts a stall document cannot reconstruct afterwards.
    /// `delta` is what the input read since the previous line; `reset` when the
    /// counter went back (a fresh open restarts it).
    struct FeedSample: Equatable {
        var positionSeconds: Int
        var state: String
        var route: String
        var readBytes: UInt64?
        var previousReadBytes: UInt64?
        var inputBitrate: Double?
        var displayedPictures: UInt64?
        var lostPictures: UInt64?

        var line: String {
            let delta: String
            switch (readBytes, previousReadBytes) {
            case let (now?, before?) where now >= before: delta = "+\(now - before)"
            case (_?, _?): delta = "reset"
            default: delta = "?"
            }
            return [
                "CINEMAX-FEED ▸ pos=\(positionSeconds)s",
                "state=\(state)",
                "route=\(route)",
                "read=\(readBytes.map(String.init) ?? "?")",
                "delta=\(delta)",
                "inputBitrate=\(inputBitrate.map { String(format: "%.1f", $0) } ?? "?")",
                "displayed=\(displayedPictures.map(String.init) ?? "?")",
                "lost=\(lostPictures.map(String.init) ?? "?")"
            ].joined(separator: " ")
        }
    }
}

// MARK: - Relay upstream (URLSession metrics)

extension VerboseDiagnostics {
    /// One upstream request of the loopback relay, from its
    /// `URLSessionTaskMetrics`: which protocol (h2 / h3), which edge address,
    /// which LOCAL network (`localAddressClass` — a home LAN vs a carrier one
    /// answers "was the phone on Wi-Fi?"), whether the connection was reused, time to first
    /// byte, and how much came down before it ended.
    struct UpstreamTransaction: Equatable {
        var status: Int?
        var protocolName: String?
        var remote: String?
        var local: String?
        var isReused: Bool
        var isCellular: Bool
        var isExpensive: Bool
        var isConstrained: Bool
        var timeToFirstByteMs: Int?
        var durationMs: Int?
        var bodyBytes: Int64
        var error: String?

        var line: String {
            var parts = [
                "upstream status=\(status.map(String.init) ?? "none")",
                "proto=\(protocolName ?? "?")",
                "remote=\(remote ?? "?")",
                "local=\(local ?? "?")",
                "reused=\(VerboseDiagnostics.yesNo(isReused))",
                "cellular=\(VerboseDiagnostics.yesNo(isCellular))",
                "expensive=\(VerboseDiagnostics.yesNo(isExpensive))",
                "constrained=\(VerboseDiagnostics.yesNo(isConstrained))",
                "ttfb=\(timeToFirstByteMs.map { "\($0)ms" } ?? "?")",
                "duration=\(durationMs.map { "\($0)ms" } ?? "?")",
                "bytes=\(bodyBytes)"
            ]
            if let error { parts.append("error=\(error)") }
            return parts.joined(separator: " ")
        }
    }
}
