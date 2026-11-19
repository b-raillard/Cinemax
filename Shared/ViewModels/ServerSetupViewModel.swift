import Foundation
import Observation
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "ServerSetup")

@MainActor @Observable
final class ServerSetupViewModel {
    var serverURL: String = ""
    var isConnecting = false
    var errorMessage: String?
    var serverInfo: ServerInfo?

    /// The certificate the last failure would be approving, when that failure was
    /// about the certificate AND the trust delegate recorded the leaf it refused.
    /// `nil` for every other failure, so the ordinary error banner is unchanged.
    var pendingCertificate: ServerCertificateSummary?

    /// `true` when the host already carried an approval and is now presenting a
    /// DIFFERENT certificate — worth saying out loud rather than re-prompting as
    /// if it were the first time.
    var pendingCertificateIsRotation = false

    /// The URLSession failures that mean « the certificate is the problem ».
    ///
    /// Wider than the `-1202` the issue named, on purpose: a NAS certificate that
    /// is self-signed AND out of date reports `-1201`, a private-CA one reports
    /// `-1203`, and some stacks surface `-1200` instead. All of them are answered
    /// by the same explicit approval, and none of them is a network problem the
    /// user could fix by retrying.
    static let certificateErrorCodes: Set<Int> = [
        NSURLErrorSecureConnectionFailed,            // -1200
        NSURLErrorServerCertificateHasBadDate,       // -1201
        NSURLErrorServerCertificateUntrusted,        // -1202
        NSURLErrorServerCertificateHasUnknownRoot,   // -1203
        NSURLErrorServerCertificateNotYetValid       // -1204
    ]

    /// Whether `error` is one of those, directly or as the underlying error of a
    /// wrapper. The SDK's transport errors arrive both ways depending on the
    /// call path, and testing only the outer `NSError` misses the wrapped case.
    /// Internal so `ServerCertificateTrustTests` can lock it.
    static func isCertificateError(_ error: Error) -> Bool {
        let outer = error as NSError
        if outer.domain == NSURLErrorDomain, certificateErrorCodes.contains(outer.code) { return true }
        if let underlying = outer.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain {
            return certificateErrorCodes.contains(underlying.code)
        }
        return false
    }

    /// Records the approval and retries at once. The user has just pressed a
    /// button that says « trust this certificate »; making them press Connect
    /// again would read as the approval not having taken.
    func trustPendingCertificate(using appState: AppState, loc: LocalizationManager) async {
        guard let pending = pendingCertificate else { return }
        ServerTrustDelegate.shared.trust(fingerprint: pending.fingerprint, forTrustKey: pending.trustKey)
        pendingCertificate = nil
        pendingCertificateIsRotation = false
        await connect(using: appState, loc: loc)
    }

    func connect(using appState: AppState, loc: LocalizationManager) async {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = loc.localized("server.addressRequired")
            return
        }

        // Single source of truth for the canonical spelling of a server URL:
        // the same normalizer the registry dedups on, so the URL we connect to
        // and the URL we store as a `ServerEntry` can never disagree. It keeps
        // the historical behavior of this screen (prepend `https://` when no
        // scheme is typed, reject anything that isn't a usable http(s) URL) and
        // additionally drops the default port / trailing slash / query.
        guard let url = ServerURLNormalizer.normalize(trimmed) else {
            errorMessage = loc.localized("server.invalidURL")
            return
        }

        // Dedup, before any network call: a URL already registered **and still
        // holding a usable session** is a no-op to add — the user wants the
        // servers list, not a second card for the same server (any equivalent
        // spelling matches, the probe runs on the normalized URL).
        //
        // The gate is `hasUsableSession` (token AND user id), i.e. exactly what
        // `AppState.applyActiveServer` will accept. Anything the app would send
        // back to a login screen must NOT be refused here: signing out of your
        // only server keeps its now-credential-less entry in the registry and
        // drops you on this screen, so a broader gate would refuse the user's
        // own server and lock them out of the app entirely. The escape hatch
        // below ("My servers") covers the other direction — the user can reach
        // an existing entry instead of retyping it.
        // `ServerRegistry.upsert` dedups on the normalized URL regardless, so
        // the permissive branch still cannot create a duplicate entry.
        // A scheme-less address may land on its `http://` spelling (see
        // `handshake`), so that spelling counts as « already added » too.
        let fallbackURL = trimmed.contains("://") ? nil : Self.plainHTTPFallback(for: url)
        if [url, fallbackURL].compactMap({ $0 }).contains(where: {
            ServerRegistry.contains(url: $0, in: appState.servers)?.hasUsableSession == true
        }) {
            errorMessage = loc.localized("server.alreadyAdded")
            return
        }

        isConnecting = true
        errorMessage = nil
        pendingCertificate = nil
        pendingCertificateIsRotation = false

        do {
            let (info, url) = try await handshake(url, schemeTyped: trimmed.contains("://"), appState: appState)
            // Legacy-mirror discipline: while ADDING a server the mirror still
            // describes the currently-active one, and the three items must stay
            // coherent. Writing `server_url` here would leave a kill-the-app
            // window where the mirror pairs the NEW url with the OLD token /
            // user session — next launch would then reconnect to server B with
            // server A's credentials. During an add the mirror is written in
            // one go by `LoginViewModel.completeSession`; in first-run mode
            // there is no other session to contradict, so the historical
            // early write is kept (nothing reads it until a session lands).
            if !appState.isAddingServer {
                try appState.keychain.saveServerURL(url)
            }
            serverInfo = info
            appState.serverURL = url
            appState.serverInfo = info
            appState.hasServer = true
        } catch {
            logger.error("Server connect failed: \(error.localizedDescription, privacy: .public)")
            // A certificate failure is offered an explicit approval instead of a
            // dead end — the alternative the user is otherwise pushed toward is
            // plain `http://`, which is strictly worse than pinning a leaf they
            // checked. Everything else keeps the generic message verbatim.
            if Self.isCertificateError(error), let key = ServerCertificateTrust.trustKey(for: url) {
                pendingCertificateIsRotation = ServerTrustDelegate.shared.isPinned(trustKey: key)
                pendingCertificate = ServerTrustDelegate.shared.pendingApproval(forTrustKey: key)
            }
            if pendingCertificate != nil {
                errorMessage = loc.localized(
                    pendingCertificateIsRotation ? "server.certificate.changed" : "server.certificate.untrusted"
                )
            } else {
                errorMessage = loc.localized("server.connectFailed")
            }
        }

        isConnecting = false
    }

    /// Connects to `url`; when the user typed no scheme and that `https://`
    /// attempt fails, tries the same address over `http://` once — the usual
    /// home server listens on plain `http://host:8096`, and the forced https
    /// used to answer it with « Connexion au serveur impossible » (recette
    /// 2026-11-17). Never downgrades a server that DID present a certificate
    /// (the approval flow stays in charge), an address spelled with an
    /// explicit scheme, nor a host:port already known over https. A failed retry rethrows the https error, so the error
    /// handling above is unchanged.
    private func handshake(_ url: URL, schemeTyped: Bool, appState: AppState) async throws -> (ServerInfo, URL) {
        do {
            return (try await appState.apiClient.connectToServer(url: url), url)
        } catch let httpsError {
            guard !schemeTyped,
                  Self.allowsPlainHTTPFallback(for: url),
                  !Self.isKnownOverHTTPS(url, servers: appState.servers),
                  let httpURL = Self.plainHTTPFallback(for: url),
                  !Self.presentedCertificate(httpsError, url: url) else { throw httpsError }
            logger.info("https failed for a scheme-less address, retrying over http")
            do {
                return (try await appState.apiClient.connectToServer(url: httpURL), httpURL)
            } catch {
                throw httpsError
            }
        }
    }

    /// Whether a failed scheme-less address may be retried in cleartext: only a
    /// home-network host — loopback, a private / link-local IP, a `.local`
    /// name. A public hostname never is: on a hostile network, blocking 443
    /// would otherwise downgrade the connection silently and send the password
    /// unencrypted (security review of PR #369). Typing `http://` stays the
    /// explicit way in. Internal so `ServerSetupViewModelTests` can lock it.
    static func allowsPlainHTTPFallback(for url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        switch LocalNetworkAddress.kind(ofLiteral: host) {
        case .loopbackIPv4, .loopbackIPv6: return true
        default: return host == "localhost" || LocalNetworkAddress.isEligibleHost(host)
        }
    }

    /// Whether this host:port has already been reached over TLS from this
    /// device: a certificate approved for it, or a registered `https` entry
    /// (its public or its LAN address). Such an address is never retried in
    /// cleartext — on another network, whatever holds that address could reset
    /// TLS, answer over http and receive the password (audit 2026-11-19,
    /// SEC-06). Typing `http://` stays the explicit way in. Internal + the
    /// `isPinned` seam so `ServerSetupViewModelTests` can lock it.
    static func isKnownOverHTTPS(
        _ url: URL, servers: [ServerEntry],
        isPinned: (String) -> Bool = { ServerTrustDelegate.shared.isPinned(trustKey: $0) }
    ) -> Bool {
        guard let key = ServerCertificateTrust.trustKey(for: url) else { return false }
        if isPinned(key) { return true }
        return servers.contains { entry in
            [entry.url, entry.localURL].compactMap { $0 }.contains {
                $0.scheme?.lowercased() == "https" && ServerCertificateTrust.trustKey(for: $0) == key
            }
        }
    }

    /// The `http://` spelling of a scheme-less `https://` attempt, normalized
    /// like every stored URL. Internal so `ServerSetupViewModelTests` can lock it.
    static func plainHTTPFallback(for url: URL) -> URL? {
        guard url.scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "http"
        return components.url.flatMap(ServerURLNormalizer.normalize)
    }

    /// Whether the https attempt reached a TLS server whose certificate was
    /// refused — a leaf to approve, not a reason to fall back to cleartext.
    private static func presentedCertificate(_ error: Error, url: URL) -> Bool {
        guard isCertificateError(error), let key = ServerCertificateTrust.trustKey(for: url) else { return false }
        return ServerTrustDelegate.shared.pendingApproval(forTrustKey: key) != nil
    }
}
