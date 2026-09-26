import Foundation
import Security
import CryptoKit

/// Trust for the ACTIVE server's user-approved (self-signed / private-CA)
/// certificate inside the extensions.
///
/// The app pins such a certificate per `host:port` in its PRIVATE Keychain
/// group (`trusted_certificates`), which the widget and the Top Shelf cannot
/// read — so on a server the app happily used, both showed « not connected »
/// (audit lot 6, 2026-09-25). The app now publishes the active server's pinned
/// fingerprint inside the shared session blob (`pinnedCertificateSHA256`, next
/// to the parental cap), and this delegate honours exactly that one pin.
///
/// Shared BY SOURCE (listed in both extensions and both apps, like
/// `ResumeControl.swift`): the extensions link none of our frameworks, and the
/// app targets carry it only so the decision can be tested. Same order of
/// checks as the app's `ServerCertificateTrust.decide`: a certificate the
/// system accepts needs no pin, and a pin names one host:port and one leaf.
final class ExtensionServerTrust: NSObject, URLSessionTaskDelegate, Sendable {
    /// The approved leaf for one `host:port`.
    struct Pin: Sendable, Equatable {
        let trustKey: String
        let fingerprint: String
    }

    /// Reads the current pin at challenge time — the session blob can change
    /// between two timeline refreshes (server switch, logout).
    private let currentPin: @Sendable () -> Pin?

    init(currentPin: @escaping @Sendable () -> Pin?) {
        self.currentPin = currentPin
    }

    /// The pin a published session carries, keyed like the app's
    /// `ServerCertificateTrust.trustKey(for:)` (host lowercased, default port
    /// filled in) — a test holds the two to the same answer.
    static func pin(serverURL: URL, fingerprint: String?) -> Pin? {
        guard let fingerprint, !fingerprint.isEmpty,
              let host = serverURL.host, !host.isEmpty else { return nil }
        let port = serverURL.port ?? (serverURL.scheme?.lowercased() == "http" ? 80 : 443)
        return Pin(trustKey: trustKey(host: host, port: port), fingerprint: fingerprint)
    }

    static func trustKey(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    /// Whether to accept a certificate the system refused.
    static func accepts(systemTrusts: Bool, challengeKey: String, leafFingerprint: String?, pin: Pin?) -> Bool {
        guard !systemTrusts, let pin, let leafFingerprint, !leafFingerprint.isEmpty else { return false }
        return pin.trustKey == challengeKey
            && leafFingerprint.caseInsensitiveCompare(pin.fingerprint) == .orderedSame
    }

    /// Task-level, like the app's `ServerTrustDelegate`: URLSession falls back
    /// to it for a session-level challenge when that one is not implemented.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let systemTrusts = SecTrustEvaluateWithError(trust, nil)
        var leaf: String?
        if !systemTrusts,
           let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
           let first = chain.first {
            let der = SecCertificateCopyData(first) as Data
            leaf = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        }
        if Self.accepts(
            systemTrusts: systemTrusts,
            challengeKey: Self.trustKey(host: space.host, port: space.port),
            leafFingerprint: leaf,
            pin: systemTrusts ? nil : currentPin()
        ) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
