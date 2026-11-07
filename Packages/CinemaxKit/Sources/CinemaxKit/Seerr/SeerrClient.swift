import Foundation
import OSLog

/// Method + endpoint path + status only: never a full URL, a header, a cookie,
/// a query or a body — `/settings/jellyfin`'s body carries Seerr's own
/// Jellyfin API key, and a decoding error's description embeds values.
private let logger = Logger(subsystem: "com.cinemax", category: "Seerr")

// MARK: - Credentials & errors

/// How a request is authenticated as the signed-in user.
public enum SeerrCredential: Sendable, Equatable {
    /// The `connect.sid` session cookie from the Quick Connect sign-in.
    case session(cookie: String)
    /// The admin's API key acting AS `user` (`X-API-User`). Without that header
    /// Seerr runs the request as its admin, so the type makes it impossible to
    /// forget.
    case apiKey(key: String, user: SeerrUserID)
}

/// The only authentications admitted by `/user/jellyfin/{id}` and
/// `/settings/jellyfin`, the two routes that must NOT carry `X-API-User`.
public enum SeerrLookupAuth: Sendable, Equatable {
    case session(cookie: String)
    case adminKey(String)
}

public enum SeerrError: Error, Equatable {
    /// No answer: the transport failed (DNS, refused, timeout, TLS).
    case unreachable
    /// Something answered `/status` with a 2xx that is not Seerr's.
    case notSeerr
    /// A 3xx the redirect policy refused to follow (another host, a downgrade).
    case redirected
    /// 403 — a real refusal, OR a dead session / refused key: Seerr answers
    /// both the same, so the caller probes before concluding.
    case forbidden
    /// A mutation still refused for its CSRF token after one refresh.
    case csrfRejected
    case notFound
    /// 409 — the title is already requested.
    case duplicate
    /// 202 on `POST /request` — mapped by the endpoint, not by the core.
    case noSeasonsAvailable
    /// 403 `{"message":"Access denied."}` — no Seerr account for this user.
    case accessDenied
    case http(Int)
}

// MARK: - Transport

/// Sends one request and hands back the final response, redirects already
/// resolved. Injectable so tests serve canned answers.
public protocol SeerrTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production transport: its own ephemeral session, nothing persisted.
///
/// No cookie store (the session cookie lives in the Keychain and is set by
/// hand), no `URLCache` (every answer is per-user), a bounded delay, system
/// trust only. Redirects follow the same rule as Jellyfin's authenticated
/// requests (`AuthenticatedRedirect`): same host, or an upgrade to https;
/// anything else comes back as the 3xx itself, which the client reads as
/// `.redirected`.
final class URLSessionSeerrTransport: SeerrTransport {
    static let timeout: TimeInterval = 10

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = Self.timeout
        // A task delegate, not a session one: a session retains its delegate
        // until invalidated.
        let (data, response) = try await session.data(for: request, delegate: SeerrRedirectPolicy.shared)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Follows a redirect only where the credentials may follow it.
final class SeerrRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = SeerrRedirectPolicy()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let follows = AuthenticatedRedirect.keepsCredentials(from: response.url, to: request.url)
        completionHandler(follows ? request : nil)
    }
}

// MARK: - Client

/// One Seerr server, spoken to in the app's language.
///
/// The client owns the CSRF pair Seerr requires on every mutation (spec,
/// § Spike findings 1): read from the `Set-Cookie` of any response, attached to
/// every non-GET, refreshed once with `GET /status` when Seerr refuses it.
public final class SeerrClient: Sendable {
    public let baseURL: URL
    private let languageCode: String?
    private let transport: any SeerrTransport

    /// Seerr's csurf pair: the `_csrf` cookie (the secret) and `XSRF-TOKEN`
    /// (a token for that secret, echoed as `X-XSRF-TOKEN`).
    struct CSRFPair {
        var secret: String?
        var token: String?

        var attachable: (secret: String, token: String)? {
            guard let secret, let token else { return nil }
            return (secret, token)
        }

        /// Takes both halves together or nothing, so the pair stays coherent
        /// whatever order concurrent answers land in. A GET carries no secret,
        /// so Seerr answers each with a FRESH pair; a mutation's answer only
        /// re-issues a token for the secret it carried — and tokens are
        /// reusable, so the stored one stays valid.
        mutating func absorb(_ cookies: [String: String]) {
            guard let newSecret = cookies["_csrf"], let newToken = cookies["XSRF-TOKEN"] else { return }
            secret = newSecret
            token = newToken
        }
    }

    private let lock = NSLock()
    /// The ONE unsafe field, and nothing touches it outside `withCSRF`.
    nonisolated(unsafe) private var _csrf = CSRFPair()

    private func withCSRF<T>(_ body: (inout CSRFPair) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&_csrf)
    }

    public init(
        baseURL: URL,
        languageCode: String?,
        transport: any SeerrTransport = SeerrClient.makeDefaultTransport()
    ) {
        self.baseURL = baseURL
        self.languageCode = languageCode
        self.transport = transport
    }

    public static func makeDefaultTransport() -> any SeerrTransport {
        URLSessionSeerrTransport()
    }

    enum Auth: Sendable {
        case none
        case credential(SeerrCredential)
        case lookup(SeerrLookupAuth)
    }

    /// One request, as `perform` sends it. `path` is relative to `/api/v1`.
    struct Call: Sendable {
        var method: String
        var path: String
        var query: [URLQueryItem] = []
        var body: Data?
        var auth: Auth = .none
        /// Appends `language=<app language>` (the routes the spec lists).
        var localized = false

        var isMutation: Bool {
            let verb = method.uppercased()
            return verb != "GET" && verb != "HEAD"
        }
    }

    // MARK: Building blocks for the endpoints

    /// `GET /api/v1<path>`, decoded. An undecodable 2xx on `/status` means
    /// something other than Seerr answered (`.notSeerr`); elsewhere the
    /// `DecodingError` is rethrown.
    func get<T: Decodable>(_ path: String, query: [URLQueryItem], auth: Auth, localized: Bool) async throws -> T {
        let (data, response) = try await perform(
            Call(method: "GET", path: path, query: query, auth: auth, localized: localized))
        do {
            return try SeerrJSON.decoder().decode(T.self, from: data)
        } catch {
            logger.error("GET \(path, privacy: .public) → \(response.statusCode, privacy: .public): undecodable body")
            if path == "/status" { throw SeerrError.notSeerr }
            throw error
        }
    }

    /// A non-GET with an optional JSON body. Returns the decoded body and the
    /// status: the body is `nil` for 202 (`POST /request`'s « no seasons
    /// available » — the endpoint maps that status itself), 204 and an empty
    /// body; any other non-empty 2xx body is decoded strictly.
    func mutate<T: Decodable>(_ method: String, _ path: String, body: Encodable?, auth: Auth) async throws -> (T?, Int) {
        let payload = try body.map { try JSONEncoder().encode($0) }
        let (data, response) = try await perform(Call(method: method, path: path, body: payload, auth: auth))
        let status = response.statusCode
        guard status != 202, status != 204, !data.isEmpty else { return (nil, status) }
        do {
            return (try SeerrJSON.decoder().decode(T.self, from: data), status)
        } catch {
            logger.error("\(method, privacy: .public) \(path, privacy: .public) → \(status, privacy: .public): undecodable body")
            throw error
        }
    }

    /// Sends, harvests the CSRF pair and maps the status. A mutation refused
    /// for its CSRF token refreshes the pair with `GET /status` and is retried
    /// ONCE; a second refusal surfaces as `.csrfRejected`. Returns the raw
    /// answer so an endpoint can read its headers (`connect.sid`).
    func perform(_ call: Call) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await sendOnce(call)
        } catch SeerrError.csrfRejected where call.isMutation {
            _ = try await sendOnce(Call(method: "GET", path: "/status"))
            return try await sendOnce(call)
        }
    }

    // MARK: Internals

    private func sendOnce(_ call: Call) async throws -> (Data, HTTPURLResponse) {
        let method = call.method
        let path = call.path
        guard let url = makeURL(path, query: call.query, localized: call.localized) else {
            throw SeerrError.unreachable
        }
        let request = makeRequest(call, url: url)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let code = (error as? URLError)?.code.rawValue ?? 0
            logger.notice("\(method, privacy: .public) \(path, privacy: .public) → no answer (\(code, privacy: .public))")
            throw SeerrError.unreachable
        }

        let cookies = Self.cookies(in: response)
        withCSRF { $0.absorb(cookies) }

        let status = response.statusCode
        logger.debug("\(method, privacy: .public) \(path, privacy: .public) → \(status, privacy: .public)")
        if (200..<300).contains(status) { return (data, response) }
        throw Self.error(status: status, body: data)
    }

    func makeURL(_ path: String, query: [URLQueryItem], localized: Bool) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.setEndpointPath("/api/v1" + path, preservingBasePathOf: baseURL)
        var items = query
        if localized, let languageCode {
            items.append(URLQueryItem(name: "language", value: languageCode))
        }
        components.percentEncodedQuery = items.isEmpty ? nil : items
            .map { "\(Self.encode($0.name))=\(Self.encode($0.value ?? ""))" }
            .joined(separator: "&")
        components.fragment = nil
        return components.url
    }

    /// RFC 3986 unreserved characters only — what Seerr's own web client sends
    /// (`encodeURIComponent` plus `!'()*`). Its OpenAPI validator answers 400
    /// to a reserved character left bare in a query value (`Mission: …`,
    /// `L'été`), and a bare `+` would be read as a space.
    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private func makeRequest(_ call: Call, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = call.method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = call.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var cookies: [String] = []
        switch call.auth {
        case .none:
            break
        case .credential(.session(let cookie)), .lookup(.session(let cookie)):
            cookies.append("connect.sid=\(cookie)")
        case .credential(.apiKey(let key, let user)):
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
            request.setValue(String(user.rawValue), forHTTPHeaderField: "X-API-User")
        case .lookup(.adminKey(let key)):
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        }
        if call.isMutation, let pair = withCSRF({ $0.attachable }) {
            cookies.append("_csrf=\(pair.secret)")
            request.setValue(pair.token, forHTTPHeaderField: "X-XSRF-TOKEN")
        }
        if !cookies.isEmpty {
            request.setValue(cookies.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        return request
    }

    /// Cookie name → value, from a response's `Set-Cookie`.
    ///
    /// Parsed by `HTTPCookie`, never split by hand: with no cookie store the
    /// cookies arrive joined by commas, and their `Expires=` holds commas too.
    /// The header is read case-insensitively (`HTTPCookie` only looks under
    /// the exact key `Set-Cookie`), and parsed as if the URL were `https`:
    /// `HTTPCookie` DROPS a `Secure` cookie for an `http://` URL other than
    /// localhost (measured: `_csrf=x; Secure` for `http://192.168.1.20:5055`
    /// → no cookie), and Seerr marks its CSRF pair `Secure` — which binds
    /// browsers only. Nothing parsed here is stored as a cookie: values are
    /// read by name, so the scheme changes nothing else.
    static func cookies(in response: HTTPURLResponse) -> [String: String] {
        guard let raw = response.value(forHTTPHeaderField: "Set-Cookie"), let url = response.url else { return [:] }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        let parseURL = components?.url ?? url
        var values: [String: String] = [:]
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": raw], for: parseURL) {
            values[cookie.name] = cookie.value
        }
        return values
    }

    private struct ErrorBody: Decodable {
        let message: String?
    }

    private static func error(status: Int, body: Data) -> SeerrError {
        switch status {
        case 300..<400:
            return .redirected
        case 403:
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.message?.lowercased() ?? ""
            if message.contains("csrf") { return .csrfRejected }
            if message.hasPrefix("access denied") { return .accessDenied }
            return .forbidden
        case 404:
            return .notFound
        case 409:
            return .duplicate
        default:
            return .http(status)
        }
    }
}
