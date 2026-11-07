import Testing
import Foundation
@testable import CinemaxKit
@testable import Cinemax

// MARK: - Stub transport (shared by every Seerr client suite)

/// Canned Seerr answers, served in order, and every request the client sent.
/// Reused by the endpoint suites, so it stays `internal`.
final class StubSeerrTransport: SeerrTransport, @unchecked Sendable {
    enum Reply {
        case response(status: Int, headers: [String: String] = [:], body: String = "")
        case failure(any Error)
    }

    /// Thrown when the client sends more requests than the test queued.
    struct Exhausted: Error {}

    private let lock = NSLock()
    private var replies: [Reply]
    private var sent: [URLRequest] = []

    init(_ replies: [Reply] = []) {
        self.replies = replies
    }

    func enqueue(_ reply: Reply) {
        lock.withLock { replies.append(reply) }
    }

    var requests: [URLRequest] {
        lock.withLock { sent }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply? = lock.withLock {
            sent.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        switch reply {
        case nil:
            throw Exhausted()
        case .failure(let error):
            throw error
        case .response(let status, let headers, let body):
            let url = request.url ?? URL(string: "http://stub.invalid")!
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }
}

// MARK: - Core

@Suite("Seerr client core")
struct SeerrClientCoreTests {

    /// Plain HTTP on the LAN — Seerr's default, and the case where its
    /// `Secure` CSRF cookies are hardest to read.
    private let lanURL = URL(string: "http://192.168.1.20:5055")!

    private let statusBody = #"{"version":"3.5.1"}"#
    private let searchBody = #"{"page":1,"totalPages":1,"totalResults":0,"results":[]}"#

    /// What Seerr 3.5.1 sends on `GET /status` with CSRF protection on: both
    /// cookies `Secure`, joined in ONE header value as URLSession hands them
    /// over without a cookie store.
    private let csrfCookies = [
        "Set-Cookie": "_csrf=a; Path=/; HttpOnly; Secure; SameSite=Strict, "
            + "XSRF-TOKEN=b; Path=/; Secure; SameSite=Strict",
    ]

    private struct Created: Decodable, Equatable { let id: Int }

    private func client(
        _ stub: StubSeerrTransport, base: URL? = nil, language: String? = "fr"
    ) -> SeerrClient {
        SeerrClient(baseURL: base ?? lanURL, languageCode: language, transport: stub)
    }

    private func queryItems(_ request: URLRequest?) -> [URLQueryItem] {
        guard let url = request?.url else { return [] }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    // MARK: Address

    @Test("A sub-path survives and a pasted /api/v1 is stripped")
    func subPathAndPastedAPIPrefix() async throws {
        let base = try #require(SeerrAddress.normalize("https://hote/seerr/api/v1/"))
        #expect(base.absoluteString == "https://hote/seerr")
        #expect(SeerrAddress.normalize("https://hote/seerr/api/v1")?.absoluteString == "https://hote/seerr")
        #expect(SeerrAddress.normalize("HTTPS://Hote/API/V1/")?.absoluteString == "https://hote")
        #expect(SeerrAddress.normalize("https://hote/myapi/v1")?.absoluteString == "https://hote/myapi/v1")

        let stub = StubSeerrTransport([.response(status: 200, body: searchBody)])
        let _: SeerrSearchPage = try await client(stub, base: base).get(
            "/search", query: [URLQueryItem(name: "query", value: "dune")], auth: .none, localized: true)
        let url = try #require(stub.requests.first?.url)
        #expect(url.scheme == "https")
        #expect(url.host == "hote")
        #expect(url.path == "/seerr/api/v1/search")
    }

    @Test("A bare host gets http://")
    func bareHostGetsHTTP() {
        #expect(SeerrAddress.normalize("192.168.1.20:5055")?.absoluteString == "http://192.168.1.20:5055")
        #expect(SeerrAddress.normalize("  seerr.local:5055/ ")?.absoluteString == "http://seerr.local:5055")
        #expect(SeerrAddress.normalize("https://seerr.example.com/")?.absoluteString == "https://seerr.example.com")
        #expect(SeerrAddress.normalize("http://seerr.local:5055")?.absoluteString == "http://seerr.local:5055")
        #expect(SeerrAddress.normalize("") == nil)
        #expect(SeerrAddress.normalize("ftp://seerr.local") == nil)
    }

    // MARK: Query

    @Test("language= only on localized routes")
    func languageOnlyOnLocalizedRoutes() async throws {
        let stub = StubSeerrTransport([
            .response(status: 200, body: searchBody),
            .response(status: 200, body: statusBody),
        ])
        let seerr = client(stub)
        let _: SeerrSearchPage = try await seerr.get(
            "/search", query: [URLQueryItem(name: "query", value: "dune")], auth: .none, localized: true)
        let _: SeerrStatusInfo = try await seerr.get("/status", query: [], auth: .none, localized: false)

        let search = queryItems(stub.requests.first)
        #expect(search.contains(URLQueryItem(name: "language", value: "fr")))
        #expect(search.contains(URLQueryItem(name: "query", value: "dune")))
        let status = try #require(stub.requests.last?.url)
        #expect(status.path == "/api/v1/status")
        #expect(status.query == nil)

        // No app language known ⇒ no `language=`, even on a localized route.
        let unlocalized = StubSeerrTransport([.response(status: 200, body: searchBody)])
        let _: SeerrSearchPage = try await client(unlocalized, language: nil).get(
            "/search", query: [URLQueryItem(name: "query", value: "dune")], auth: .none, localized: true)
        #expect(queryItems(unlocalized.requests.first).map(\.name) == ["query"])
    }

    @Test("Query values are percent-encoded strictly, as Seerr's validator demands")
    func queryValuesAreStrictlyEncoded() async throws {
        let stub = StubSeerrTransport([.response(status: 200, body: searchBody)])
        let _: SeerrSearchPage = try await client(stub).get(
            "/search", query: [URLQueryItem(name: "query", value: "Mission: Impossible + l'été")],
            auth: .none, localized: true)
        let url = try #require(stub.requests.first?.url)
        let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        #expect(encoded == "query=Mission%3A%20Impossible%20%2B%20l%27%C3%A9t%C3%A9&language=fr")
    }

    // MARK: Credentials

    @Test("An API key always carries its user; a lookup key never does")
    func apiKeyAlwaysCarriesUser() async throws {
        let user = #"{"id":3,"permissions":32}"#
        let stub = StubSeerrTransport([
            .response(status: 200, body: user),
            .response(status: 200, body: user),
            .response(status: 200, body: user),
        ])
        let seerr = client(stub)
        let _: SeerrUser = try await seerr.get(
            "/auth/me", query: [], auth: .credential(.apiKey(key: "k", user: SeerrUserID(rawValue: 3))),
            localized: false)
        let _: SeerrUser = try await seerr.get(
            "/user/jellyfin/abc", query: [], auth: .lookup(.adminKey("k")), localized: false)
        let _: SeerrUser = try await seerr.get(
            "/auth/me", query: [], auth: .credential(.session(cookie: "s%3Aabc.def")), localized: false)

        let key = stub.requests[0]
        #expect(key.value(forHTTPHeaderField: "X-Api-Key") == "k")
        #expect(key.value(forHTTPHeaderField: "X-API-User") == "3")
        #expect(key.value(forHTTPHeaderField: "Cookie") == nil)

        let lookup = stub.requests[1]
        #expect(lookup.value(forHTTPHeaderField: "X-Api-Key") == "k")
        #expect(lookup.value(forHTTPHeaderField: "X-API-User") == nil)

        let session = stub.requests[2]
        #expect(session.value(forHTTPHeaderField: "Cookie") == "connect.sid=s%3Aabc.def")
        #expect(session.value(forHTTPHeaderField: "X-Api-Key") == nil)
        #expect(session.value(forHTTPHeaderField: "X-API-User") == nil)
    }

    // MARK: CSRF

    @Test("A CSRF refusal refreshes the pair once, then gives up")
    func csrfRefreshedOnceThenFails() async throws {
        let csrf403 = StubSeerrTransport.Reply.response(status: 403, body: #"{"message":"invalid csrf token"}"#)
        let refresh = StubSeerrTransport.Reply.response(status: 200, headers: csrfCookies, body: statusBody)
        let stub = StubSeerrTransport([csrf403, refresh, .response(status: 201, body: #"{"id":12}"#)])
        let seerr = client(stub)

        let (created, status): (Created?, Int) = try await seerr.mutate(
            "POST", "/request", body: ["mediaType": "movie"], auth: .credential(.session(cookie: "sid")))
        #expect(status == 201)
        #expect(created == Created(id: 12))
        #expect(stub.requests.count == 3)

        let first = stub.requests[0]
        #expect(first.value(forHTTPHeaderField: "X-XSRF-TOKEN") == nil)
        #expect(first.value(forHTTPHeaderField: "Cookie") == "connect.sid=sid")
        #expect(stub.requests[1].httpMethod == "GET")
        #expect(stub.requests[1].url?.path == "/api/v1/status")
        let retry = stub.requests[2]
        #expect(retry.httpMethod == "POST")
        #expect(retry.value(forHTTPHeaderField: "Cookie")?.contains("_csrf=a") == true)
        #expect(retry.value(forHTTPHeaderField: "Cookie")?.contains("connect.sid=sid") == true)
        #expect(retry.value(forHTTPHeaderField: "X-XSRF-TOKEN") == "b")
        #expect(retry.httpBody == Data(#"{"mediaType":"movie"}"#.utf8))
        #expect(retry.value(forHTTPHeaderField: "Content-Type") == "application/json")

        // The pair is kept and reused: a key-mode mutation carries it with no
        // refresh, and a GET never carries it.
        stub.enqueue(.response(status: 200, body: #"{"id":13}"#))
        stub.enqueue(.response(status: 200, body: statusBody))
        let _: (Created?, Int) = try await seerr.mutate(
            "POST", "/request/13/approve", body: nil,
            auth: .credential(.apiKey(key: "k", user: SeerrUserID(rawValue: 3))))
        let _: SeerrStatusInfo = try await seerr.get("/status", query: [], auth: .none, localized: false)
        #expect(stub.requests.count == 5)
        let keyed = stub.requests[3]
        #expect(keyed.value(forHTTPHeaderField: "Cookie") == "_csrf=a")
        #expect(keyed.value(forHTTPHeaderField: "X-XSRF-TOKEN") == "b")
        #expect(keyed.httpBody == nil)
        let read = stub.requests[4]
        #expect(read.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(read.value(forHTTPHeaderField: "X-XSRF-TOKEN") == nil)

        // A second CSRF refusal after the refresh is final: exactly 3 requests.
        let failing = StubSeerrTransport([csrf403, refresh, csrf403])
        await #expect(throws: SeerrError.csrfRejected) {
            let _: (Created?, Int) = try await client(failing).mutate(
                "POST", "/request", body: ["mediaType": "movie"], auth: .credential(.session(cookie: "sid")))
        }
        #expect(failing.requests.count == 3)
    }

    // MARK: Statuses

    private func getFailure(_ reply: StubSeerrTransport.Reply, path: String = "/auth/me") async -> (any Error)? {
        let stub = StubSeerrTransport([reply])
        do {
            let _: SeerrStatusInfo = try await client(stub).get(
                path, query: [], auth: .credential(.session(cookie: "sid")), localized: false)
            return nil
        } catch {
            return error
        }
    }

    private func mutateFailure(_ reply: StubSeerrTransport.Reply) async -> (any Error)? {
        let stub = StubSeerrTransport([reply])
        do {
            let _: (Created?, Int) = try await client(stub).mutate(
                "POST", "/request", body: ["mediaType": "movie"], auth: .credential(.session(cookie: "sid")))
            return nil
        } catch {
            return error
        }
    }

    @Test("Statuses map to Seerr errors")
    func statusMapping() async throws {
        let redirect = StubSeerrTransport.Reply.response(
            status: 302, headers: ["Location": "https://elsewhere.example/"])
        #expect(await getFailure(redirect) as? SeerrError == .redirected)
        let refused = #"{"error":"You do not have permission to access this endpoint"}"#
        #expect(await getFailure(.response(status: 403, body: refused)) as? SeerrError == .forbidden)
        let denied = #"{"message":"Access denied."}"#
        #expect(await mutateFailure(.response(status: 403, body: denied)) as? SeerrError == .accessDenied)
        #expect(await getFailure(.response(status: 404, body: "{}")) as? SeerrError == .notFound)
        let duplicate = #"{"message":"Request for this media already exists."}"#
        #expect(await mutateFailure(.response(status: 409, body: duplicate)) as? SeerrError == .duplicate)
        #expect(await getFailure(.response(status: 401, body: #"{"message":"Unauthorized"}"#)) as? SeerrError
            == .http(401))
        #expect(await getFailure(.response(status: 500)) as? SeerrError == .http(500))
        #expect(await getFailure(.failure(URLError(.cannotConnectToHost))) as? SeerrError == .unreachable)
        #expect(await getFailure(.failure(URLError(.timedOut))) as? SeerrError == .unreachable)
        let html = "<html><body>Jellyfin</body></html>"
        #expect(await getFailure(.response(status: 200, body: html), path: "/status") as? SeerrError == .notSeerr)
        // Elsewhere an undecodable 2xx is a decoding failure, not « not Seerr ».
        #expect(await getFailure(.response(status: 200, body: html), path: "/movie/1") is DecodingError)
    }

    @Test("A cancelled request is a cancellation, never « unreachable »")
    func cancellationIsNotUnreachable() async {
        #expect(await getFailure(.failure(CancellationError())) is CancellationError)
        #expect(await getFailure(.failure(URLError(.cancelled))) is CancellationError)
    }

    @Test("mutate hands back the status, and no body for 202 / 204 / empty")
    func mutateReturnContract() async throws {
        let stub = StubSeerrTransport([
            .response(status: 202, body: #"{"message":"No seasons available to request"}"#),
            .response(status: 204),
            .response(status: 200),
        ])
        let seerr = client(stub)
        let accepted: (Created?, Int) = try await seerr.mutate(
            "POST", "/request", body: ["mediaType": "tv"], auth: .credential(.session(cookie: "sid")))
        #expect(accepted.0 == nil)
        #expect(accepted.1 == 202)
        let noContent: (Created?, Int) = try await seerr.mutate(
            "POST", "/auth/logout", body: nil, auth: .credential(.session(cookie: "sid")))
        #expect(noContent.0 == nil)
        #expect(noContent.1 == 204)
        let empty: (Created?, Int) = try await seerr.mutate(
            "POST", "/request/7/decline", body: nil, auth: .credential(.session(cookie: "sid")))
        #expect(empty.0 == nil)
        #expect(empty.1 == 200)
    }
}
