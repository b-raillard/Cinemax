import Foundation
import Security
import CryptoKit
import os

private let trustLog = Logger(subsystem: "com.cinemax", category: "ServerTrust")

/// What the approval prompt shows about a certificate the system refused.
///
/// **Subject, serial and fingerprint only — deliberately no issuer and no
/// validity dates.** Those are not reachable through public API on iOS/tvOS
/// (`SecCertificateCopyValues` is macOS-only), and hand-rolling an X.509/ASN.1
/// parser to render two extra strings in a confirmation dialog is not a trade
/// worth making: the fingerprint is what actually identifies the certificate,
/// and the fingerprint is what gets pinned.
public struct ServerCertificateSummary: Sendable, Equatable {
    /// `host:port` — the same key the pin is stored under.
    public let trustKey: String
    /// Host alone, for display.
    public let host: String
    /// `SecCertificateCopySubjectSummary`, when the certificate carries one.
    public let subject: String?
    /// Hex serial number, when readable.
    public let serialNumber: String?
    /// SHA-256 of the leaf's DER bytes, lowercase hex, no separators.
    public let fingerprint: String

    /// Grouped, uppercase form for display (`A1:B2:…`).
    public var formattedFingerprint: String {
        ServerCertificateTrust.formatFingerprint(fingerprint)
    }

    public init(trustKey: String, host: String, subject: String?, serialNumber: String?, fingerprint: String) {
        self.trustKey = trustKey
        self.host = host
        self.subject = subject
        self.serialNumber = serialNumber
        self.fingerprint = fingerprint
    }
}

/// Pure logic of explicit server-certificate trust: fingerprints, the pin key,
/// and the decision itself.
///
/// A home server on `https://` with a self-signed certificate previously failed
/// to connect with a generic error, which pushed users onto plain `http://` —
/// strictly worse. Pinning a leaf the user *explicitly approved* is safer than
/// both, and unlike a global "ignore TLS" switch it cannot be widened by
/// accident: a pin names one host and one certificate.
public enum ServerCertificateTrust {
    /// What the delegate should answer.
    public enum Decision: Sendable, Equatable {
        /// Hand back to URLSession untouched — byte-identical to the behaviour
        /// before this feature existed. Covers a non-trust challenge, a
        /// certificate the system already accepts, and an unpinned host.
        case systemDefault
        /// The presented leaf matches the pin: accept it.
        case accept
        /// A pin exists for this host and the presented leaf is NOT it. Answered
        /// on the wire exactly like `systemDefault` (so the user sees the normal
        /// certificate error), but distinguished here because a *changed*
        /// certificate is worth a log line and must re-prompt rather than
        /// silently connect.
        case fingerprintChanged
    }

    /// The decision, with every input as a plain value so it is testable without
    /// a live `SecTrust`.
    ///
    /// **Order is load-bearing.** `systemTrusts` is consulted BEFORE the pin: a
    /// certificate the system accepts needs no pin, so a server that later moves
    /// to a real CA (or renews inside a private CA the device now trusts) keeps
    /// working without anybody clearing anything. And an unpinned host falls
    /// through to `systemDefault`, which is what makes this feature invisible to
    /// every ordinary server.
    public static func decide(
        isServerTrustMethod: Bool,
        systemTrusts: Bool,
        leafFingerprint: String?,
        expected: String?
    ) -> Decision {
        guard isServerTrustMethod else { return .systemDefault }
        guard !systemTrusts else { return .systemDefault }
        guard let expected, !expected.isEmpty else { return .systemDefault }
        guard let leafFingerprint, !leafFingerprint.isEmpty else { return .systemDefault }
        return leafFingerprint.caseInsensitiveCompare(expected) == .orderedSame
            ? .accept
            : .fingerprintChanged
    }

    // MARK: - Pin key

    /// `host:port`, lowercased, with the scheme's default port filled in.
    ///
    /// A TLS challenge hands us a host and a port, never a URL, so the pin is
    /// keyed on exactly that. The default port is made explicit on both sides so
    /// `https://nas.local` and `https://nas.local:443` cannot disagree — which
    /// is the same equivalence `ServerURLNormalizer` enforces for URLs.
    public static func trustKey(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    /// The pin key for a server URL, or `nil` when it names no host.
    public static func trustKey(for url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let port = url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
        return trustKey(host: host, port: port)
    }

    // MARK: - Fingerprints

    /// SHA-256 of the certificate's DER bytes, lowercase hex.
    public static func fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Groups a hex fingerprint in pairs for display (`A1:B2:C3…`). Anything
    /// that isn't a clean hex pair sequence is returned uppercased as-is rather
    /// than mangled.
    public static func formatFingerprint(_ hex: String) -> String {
        guard hex.count % 2 == 0, !hex.isEmpty else { return hex.uppercased() }
        return stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return hex[start..<end].uppercased()
        }.joined(separator: ":")
    }

    // MARK: - SecTrust bridging

    /// Whether the system, on its own, accepts this trust object.
    static func systemTrusts(_ trust: SecTrust) -> Bool {
        SecTrustEvaluateWithError(trust, nil)
    }

    /// The leaf certificate of a trust object. `SecTrustCopyCertificateChain`
    /// rather than the deprecated `SecTrustGetCertificateAtIndex`.
    static func leafCertificate(of trust: SecTrust) -> SecCertificate? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return nil }
        return chain.first
    }

    /// Builds the summary the approval prompt renders.
    static func summary(for trust: SecTrust, host: String, port: Int) -> ServerCertificateSummary? {
        guard let leaf = leafCertificate(of: trust) else { return nil }
        let serial = (SecCertificateCopySerialNumberData(leaf, nil) as Data?)?
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
        return ServerCertificateSummary(
            trustKey: trustKey(host: host, port: port),
            host: host,
            subject: SecCertificateCopySubjectSummary(leaf) as String?,
            serialNumber: serial,
            fingerprint: fingerprint(of: leaf)
        )
    }
}

/// The single `URLSessionTaskDelegate` every authenticated session in the app
/// installs, so one explicit approval covers the API client, the realtime
/// socket, the reachability probe, the PlaybackInfo POST, the HLS manifest
/// loader, the loopback stream proxy and the image pipeline.
///
/// **RULE — it implements ONLY the TASK-level challenge callback
/// (`urlSession(_:task:didReceive:completionHandler:)`), never the session-level
/// one, and that is the one shape that works everywhere.** Measured against the
/// two libraries that own their own `URLSession`: `Get`'s `DataLoader` (which
/// backs `JellyfinClient`) casts the delegate we hand it to
/// `URLSessionTaskDelegate` and forwards only the task-level method, defaulting
/// to `.performDefaultHandling` when nobody answers; Nuke's `_DataLoader` does
/// the same. A delegate implementing only the session-level method would be
/// accepted by both APIs and then **silently never called** — the certificate
/// would go on being refused with no trace. For the sessions we construct
/// ourselves, URLSession falls back to the task-level method when the
/// session-level one is absent, so the single implementation serves both roles.
///
/// **RULE — never a global "ignore TLS" switch.** Trust is per host AND per
/// fingerprint: an unpinned host, and a certificate the system already accepts,
/// both fall through to `.performDefaultHandling`, i.e. exactly today's
/// behaviour. A rotated certificate stops matching and re-prompts instead of
/// connecting.
public final class ServerTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static let shared = ServerTrustDelegate()

    /// How long a pin snapshot is reused before the Keychain is consulted again.
    ///
    /// The delegate reads the store ITSELF rather than having `AppState` push a
    /// map into it — deliberately. A pushed map needs an owner, an ordering and
    /// a refresh on every load path, which is precisely the shape of the
    /// "who owns the refresh" defects this project has collected; reading behind
    /// a short cache has no initialisation order to get wrong, and a TLS
    /// challenge happens once per connection, not per request.
    private static let cacheTTL: TimeInterval = 5

    private let keychain: KeychainService
    private let lock = NSLock()
    private var cachedPins: [String: String] = [:]
    private var cachedAt: Date?
    /// Last leaf refused for a host, so the setup screen can show what it would
    /// be approving right after the connection failed.
    private var pendingApprovals: [String: ServerCertificateSummary] = [:]

    init(keychain: KeychainService = KeychainService()) {
        self.keychain = keychain
        super.init()
    }

    // MARK: - Store

    /// Records an explicit approval and drops the cache so the very next
    /// challenge sees it.
    public func trust(fingerprint: String, forTrustKey key: String) {
        lock.lock()
        var pins = keychain.getTrustedCertificates()
        pins[key] = fingerprint.lowercased()
        cachedPins = pins
        cachedAt = Date()
        pendingApprovals[key] = nil
        lock.unlock()
        keychain.saveTrustedCertificates(pins)
        trustLog.info("ServerTrust ▸ certificat approuvé pour \(key, privacy: .public)")
    }

    /// Forgets a host's pin (used when its server is removed).
    public func forget(trustKey key: String) {
        lock.lock()
        var pins = keychain.getTrustedCertificates()
        pins[key] = nil
        cachedPins = pins
        cachedAt = Date()
        lock.unlock()
        keychain.saveTrustedCertificates(pins)
    }

    /// The certificate a failed connection would be approving, if the last
    /// refusal for this host produced one.
    public func pendingApproval(forTrustKey key: String) -> ServerCertificateSummary? {
        lock.lock()
        defer { lock.unlock() }
        return pendingApprovals[key]
    }

    /// Whether this host currently carries a pin.
    public func isPinned(trustKey key: String) -> Bool {
        pin(forTrustKey: key) != nil
    }

    private func pin(forTrustKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedAt, Date().timeIntervalSince(cachedAt) < Self.cacheTTL {
            return cachedPins[key]
        }
        let pins = keychain.getTrustedCertificates()
        cachedPins = pins
        cachedAt = Date()
        return pins[key]
    }

    // MARK: - URLSessionTaskDelegate

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let isServerTrust = space.authenticationMethod == NSURLAuthenticationMethodServerTrust
        guard isServerTrust, let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let key = ServerCertificateTrust.trustKey(host: space.host, port: space.port)
        let trusted = ServerCertificateTrust.systemTrusts(trust)
        // The leaf is only needed on the paths that compare or record it —
        // skipped entirely for the overwhelmingly common case of a certificate
        // the system already accepts.
        let leaf = trusted ? nil : ServerCertificateTrust.leafCertificate(of: trust).map(ServerCertificateTrust.fingerprint(of:))

        switch ServerCertificateTrust.decide(
            isServerTrustMethod: true,
            systemTrusts: trusted,
            leafFingerprint: leaf,
            expected: pin(forTrustKey: key)
        ) {
        case .systemDefault:
            if !trusted { rememberPending(trust: trust, host: space.host, port: space.port, key: key) }
            completionHandler(.performDefaultHandling, nil)
        case .accept:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .fingerprintChanged:
            trustLog.error("ServerTrust ▸ le certificat de \(key, privacy: .public) a CHANGÉ — refusé, nouvelle approbation requise")
            rememberPending(trust: trust, host: space.host, port: space.port, key: key)
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func rememberPending(trust: SecTrust, host: String, port: Int, key: String) {
        guard let summary = ServerCertificateTrust.summary(for: trust, host: host, port: port) else { return }
        lock.lock()
        pendingApprovals[key] = summary
        lock.unlock()
    }
}
