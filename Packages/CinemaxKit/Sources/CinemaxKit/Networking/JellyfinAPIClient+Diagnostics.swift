import Foundation
import OSLog

private let logger = Logger(subsystem: "com.cinemax", category: "Diagnostics")

public extension JellyfinAPIClient {

    /// Uploads a diagnostic document to the SERVER's own log directory
    /// (`POST /ClientLog/Document`) and returns the file name it was given.
    ///
    /// **This exists because tvOS has no way to hand a log to a human.** The
    /// diagnostics export is iOS-only — there is no share sheet on tvOS and no
    /// MetricKit — so an Apple TV's OSLog is unreachable to the person actually
    /// watching: a `logger.notice` written there might as well not exist. The
    /// server, on the other hand, is a machine they own and can read, and
    /// Jellyfin has modelled exactly this since 10.7. The file lands beside the
    /// server's own logs, named `upload_<client>_<timestamp>_<guid>.log`, and
    /// `GET /System/Logs` lists it like any other.
    ///
    /// **RULE — hand-built, and `text/plain` is the whole reason.** The SDK does
    /// generate this route (`Paths.logFile`), but its body is `Encodable` and
    /// goes through Get's JSON encoder, so the document arrives as ONE quoted,
    /// escaped line. Measured against the reference server on 2026-09-13: a
    /// JSON-encoded body was written verbatim as `"ligne 1\nligne 2 avec
    /// \"guillemets\""` — a document nobody can read, i.e. the exact opposite of
    /// the point. A raw `URLRequest` with `Content-Type: text/plain` writes the
    /// text as text.
    ///
    /// **Best effort, and deliberately silent about it.** The server's admin can
    /// turn uploads off (`AllowClientLogUpload`, default true), which answers
    /// 403 — that is the consent switch, it lives server-side where it belongs,
    /// and refusing is a legitimate configuration rather than an error to
    /// surface. A 401 here does **not** go through `notifyIfUnauthorized`: a
    /// diagnostic upload must never be the thing that drives a session-expiry
    /// cycle, and any genuinely dead token is discovered by the calls that
    /// matter.
    ///
    /// The document is scrubbed by its BUILDER (`DiagnosticsReport.document`,
    /// via `LogScrubber`), not here — the same single scrubbing point the manual
    /// export uses. What it carries beyond that is what the export carries:
    /// titles, user names and the server's own host, on a server the user
    /// administers.
    func uploadDiagnostics(_ document: String) async -> String? {
        guard !document.isEmpty,
              let client = getClient(),
              let serverURL = getServerURL(),
              var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        else { return nil }
        // Never `components.path = …`: that would drop the sub-path of a
        // sub-path-hosted server and 404 (see `URLComponents+ServerPath`).
        components.setEndpointPath("/ClientLog/Document", preservingBasePathOf: serverURL)
        components.fragment = nil
        guard let endpoint = components.url else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        // The same `MediaBrowser` header the SDK builds. `Client` is what names
        // the uploaded file server-side, which is what makes ours findable
        // among a family's other clients.
        var rawFields = [
            "DeviceId": client.configuration.deviceID,
            "Device": client.configuration.deviceName,
            "Client": client.configuration.client,
            "Version": client.configuration.version,
        ]
        if let token = client.accessToken { rawFields["Token"] = token }
        let fields = rawFields.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        request.setValue("MediaBrowser \(fields)", forHTTPHeaderField: "Authorization")

        // Bounded on both sides: a diagnostic must never hold a request open
        // behind a stalled server, and a pathological document must never be
        // what fills the server's log directory. 300 kB was verified accepted;
        // this cap sits below it and truncates from the FRONT, keeping the most
        // recent lines — the ones describing the fault.
        let payload = Self.diagnosticsPayload(document)
        request.httpBody = payload
        request.timeoutInterval = 20

        do {
            let (data, response) = try await Self.diagnosticsSession.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(status) else {
                logger.debug("Diagnostics upload refused by the server")
                return nil
            }
            var name: String?
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                name = object["FileName"] as? String
            }
            logger.notice("diagnostics uploaded as \(name ?? "?", privacy: .public)")
            return name
        } catch {
            logger.debug("Diagnostics upload failed")
            return nil
        }
    }

    /// Caps the document and keeps its TAIL. Pure + internal so the cap is
    /// unit-tested without a server.
    internal static func diagnosticsPayload(_ document: String, limit: Int = maxDiagnosticsBytes) -> Data {
        let data = Data(document.utf8)
        guard data.count > limit else { return data }
        // Cutting UTF-8 at an arbitrary byte can split a character; decode
        // leniently and re-encode rather than shipping invalid bytes.
        let tail = data.suffix(limit)
        let text = String(decoding: tail, as: UTF8.self)
        return Data("(document tronqué — seules les dernières lignes sont conservées)\n\(text)".utf8)
    }

    internal static var maxDiagnosticsBytes: Int { 256 * 1024 }

    /// Its own session, like every other request this client builds by hand:
    /// `urlCache = nil` because the document travels with the account's token in
    /// an Authorization header, and the trust delegate so an approved
    /// self-signed server is not the one place diagnostics silently fail.
    private static var diagnosticsSession: URLSession { Self.sharedDiagnosticsSession }
}

private extension JellyfinAPIClient {
    static let sharedDiagnosticsSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: ServerTrustDelegate.shared, delegateQueue: nil)
    }()
}
