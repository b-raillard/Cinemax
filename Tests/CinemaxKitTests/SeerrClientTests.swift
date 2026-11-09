import Testing
import Foundation
@testable import CinemaxKit
@testable import Cinemax
import Get

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
    private var ranDry = false

    /// Whether a request ever arrived with no canned answer left.
    var exhausted: Bool { lock.withLock { ranDry } }

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
            if replies.isEmpty { ranDry = true }
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

// MARK: - Endpoints

@Suite("Seerr client endpoints")
struct SeerrClientEndpointTests {

    private let lanURL = URL(string: "http://192.168.1.20:5055")!
    private let key = SeerrCredential.apiKey(key: "k", user: SeerrUserID(rawValue: 3))
    private let userJSON = #"{"id":3,"permissions":32,"jellyfinUserId":"abc","displayName":"Léa"}"#
    private let emptyPage = #"{"page":1,"totalPages":1,"totalResults":0,"results":[]}"#

    private func client(_ stub: StubSeerrTransport) -> SeerrClient {
        SeerrClient(baseURL: lanURL, languageCode: "fr", transport: stub)
    }

    private func queryString(_ request: URLRequest?) -> String? {
        request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
    }

    @Test("GET /request always sorts by modified, requestedBy only when given")
    func requestsQuery() async throws {
        let page = #"{"pageInfo":{"results":0},"results":[]}"#
        let stub = StubSeerrTransport([.response(status: 200, body: page), .response(status: 200, body: page)])
        let seerr = client(stub)
        _ = try await seerr.requests(filter: .pending, take: 20, skip: 40, requestedBy: nil, key)
        _ = try await seerr.requests(filter: .all, take: 10, skip: 0, requestedBy: SeerrUserID(rawValue: 2), key)
        #expect(stub.requests[0].httpMethod == "GET")
        #expect(stub.requests[0].url?.path == "/api/v1/request")
        #expect(queryString(stub.requests[0]) == "take=20&skip=40&filter=pending&sort=modified")
        #expect(queryString(stub.requests[1]) == "take=10&skip=0&filter=all&sort=modified&requestedBy=2")
        #expect(stub.requests[1].value(forHTTPHeaderField: "X-API-User") == "3")
        #expect(!stub.exhausted)
    }

    @Test("A TV request body carries the seasons")
    func createTVRequestBody() async throws {
        let created = """
        {"id":9,"status":1,"type":"tv","createdAt":"2026-11-01T10:00:00.000Z","updatedAt":"2026-11-01T10:00:00.000Z",
        "requestedBy":{"id":3,"permissions":32},"media":{"tmdbId":90228,"status":3},"seasons":[{"seasonNumber":4}]}
        """
        let stub = StubSeerrTransport([.response(status: 201, body: created)])
        let request = try await client(stub).createRequest(.tv(tmdbId: 90228, seasons: [4, 5]), key)
        #expect(request.id == 9)
        let sent = try #require(stub.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path == "/api/v1/request")
        let body = try #require(sent.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["mediaType"] as? String == "tv")
        #expect(object["mediaId"] as? Int == 90228)
        #expect(object["seasons"] as? [Int] == [4, 5])
        #expect(object.count == 3)
    }

    @Test("A movie request has no seasons key")
    func createMovieRequestBody() async throws {
        let created = """
        {"id":9,"status":1,"type":"movie","createdAt":"2026-11-01T10:00:00Z","updatedAt":"2026-11-01T10:00:00Z",
        "requestedBy":{"id":3,"permissions":32},"media":{"tmdbId":1,"status":3}}
        """
        let stub = StubSeerrTransport([.response(status: 201, body: created)])
        _ = try await client(stub).createRequest(.movie(tmdbId: 438631), key)
        let body = try #require(stub.requests.first?.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["mediaType"] as? String == "movie")
        #expect(object["mediaId"] as? Int == 438631)
        #expect(object.count == 2)
    }

    @Test("202 on POST /request means no season was available")
    func acceptedWithoutSeasonsIsAFailure() async {
        let stub = StubSeerrTransport([.response(status: 202, body: #"{"message":"No seasons available to request"}"#)])
        await #expect(throws: SeerrError.noSeasonsAvailable) {
            _ = try await client(stub).createRequest(.tv(tmdbId: 1, seasons: [1]), key)
        }
    }

    @Test("Quick Connect authenticate reads connect.sid and the CSRF pair, Secure over http")
    func quickConnectAuthenticateReadsCookie() async throws {
        let cookies = "connect.sid=s%3Aabc.def; Path=/; Expires=Thu, 07 Dec 2026 06:11:38 GMT; HttpOnly; Secure, "
            + "_csrf=x; Path=/; HttpOnly; Secure; SameSite=Strict, "
            + "XSRF-TOKEN=y; Path=/; Secure; SameSite=Strict"
        let stub = StubSeerrTransport([
            .response(status: 200, headers: ["Set-Cookie": cookies], body: userJSON),
            .response(status: 200, body: "{}"),
        ])
        let seerr = client(stub)
        let result = try await seerr.quickConnectAuthenticate(secret: "shh")
        #expect(result.cookie == "s%3Aabc.def")
        #expect(result.user.id == SeerrUserID(rawValue: 3))
        let sent = try #require(stub.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path == "/api/v1/auth/jellyfin/quickconnect/authenticate")
        #expect(sent.httpBody.map { String(decoding: $0, as: UTF8.self) } == #"{"secret":"shh"}"#)

        // The pair was absorbed from that very answer: the next mutation carries it.
        await seerr.logout(cookie: "s%3Aabc.def")
        let logout = stub.requests[1]
        #expect(logout.httpMethod == "POST")
        #expect(logout.url?.path == "/api/v1/auth/logout")
        #expect(logout.value(forHTTPHeaderField: "X-XSRF-TOKEN") == "y")
        #expect(logout.value(forHTTPHeaderField: "Cookie")?.contains("_csrf=x") == true)
        #expect(logout.value(forHTTPHeaderField: "Cookie")?.contains("connect.sid=s%3Aabc.def") == true)
    }

    @Test("Without connect.sid, authenticate fails")
    func quickConnectAuthenticateWithoutCookie() async {
        let stub = StubSeerrTransport([.response(status: 200, body: userJSON)])
        await #expect(throws: SeerrError.self) {
            _ = try await client(stub).quickConnectAuthenticate(secret: "shh")
        }
    }

    @Test("A lookup answering 404 is nil; the key carries no X-API-User")
    func lookupNotFoundIsNil() async throws {
        let stub = StubSeerrTransport([
            .response(status: 404, body: "{}"),
            .response(status: 200, body: userJSON),
        ])
        let seerr = client(stub)
        #expect(try await seerr.user(forJellyfinUserId: "abc", auth: .adminKey("k")) == nil)
        let found = try await seerr.user(forJellyfinUserId: "abc", auth: .session(cookie: "sid"))
        #expect(found?.id == SeerrUserID(rawValue: 3))
        #expect(stub.requests[0].url?.path == "/api/v1/user/jellyfin/abc")
        #expect(stub.requests[0].value(forHTTPHeaderField: "X-Api-Key") == "k")
        #expect(stub.requests[0].value(forHTTPHeaderField: "X-API-User") == nil)
        #expect(stub.requests[1].value(forHTTPHeaderField: "Cookie") == "connect.sid=sid")
    }

    @Test("approve and decline are POSTs")
    func approveIsPOST() async throws {
        let stub = StubSeerrTransport([.response(status: 200, body: "{}"), .response(status: 200, body: "{}")])
        let seerr = client(stub)
        try await seerr.approve(requestId: 7, key)
        try await seerr.decline(requestId: 8, key)
        #expect(stub.requests[0].httpMethod == "POST")
        #expect(stub.requests[0].url?.path == "/api/v1/request/7/approve")
        #expect(stub.requests[1].httpMethod == "POST")
        #expect(stub.requests[1].url?.path == "/api/v1/request/8/decline")
        #expect(stub.requests[0].value(forHTTPHeaderField: "X-API-User") == "3")
    }

    @Test("Read endpoints: paths, language and credentials")
    func readEndpointPaths() async throws {
        let movie = #"{"mediaType":"movie","id":5,"title":"Dune"}"#
        let tv = #"{"id":6,"name":"Dune","seasons":[]}"#
        let collection = #"{"id":7,"name":"Saga","parts":[]}"#
        let person = #"{"knownForDepartment":"Acting"}"#
        let credits = #"{"cast":[],"crew":[]}"#
        let stub = StubSeerrTransport([
            .response(status: 200, body: #"{"version":"3.5.1"}"#),
            .response(status: 200, body: emptyPage),
            .response(status: 200, body: movie), .response(status: 200, body: tv),
            .response(status: 200, body: collection), .response(status: 200, body: person),
            .response(status: 200, body: credits), .response(status: 200, body: userJSON),
        ])
        let seerr = client(stub)
        _ = try await seerr.status()
        _ = try await seerr.search("Mission: Impossible", key)
        _ = try await seerr.movie(tmdbId: 5, key)
        _ = try await seerr.tv(tmdbId: 6, key)
        _ = try await seerr.collection(id: 7, key)
        _ = try await seerr.person(id: 8, key)
        _ = try await seerr.combinedCredits(personId: 8, key)
        _ = try await seerr.me(key)
        let r = stub.requests
        #expect(r.map { $0.url?.path } == [
            "/api/v1/status", "/api/v1/search", "/api/v1/movie/5", "/api/v1/tv/6", "/api/v1/collection/7",
            "/api/v1/person/8", "/api/v1/person/8/combined_credits", "/api/v1/auth/me",
        ])
        #expect(queryString(r[0]) == nil)
        #expect(queryString(r[1]) == "query=Mission%3A%20Impossible&page=1&language=fr")
        #expect(queryString(r[2]) == "language=fr")
        #expect(queryString(r[6]) == "language=fr")
        #expect(queryString(r[7]) == nil)
        #expect(r[0].value(forHTTPHeaderField: "X-API-User") == nil)
        #expect(r[1].value(forHTTPHeaderField: "X-API-User") == "3")
        #expect(!stub.exhausted)
    }

    @Test("Quick Connect initiate, check and the server id")
    func quickConnectAndServerId() async throws {
        let stub = StubSeerrTransport([
            .response(status: 200, body: #"{"code":"123456","secret":"shh"}"#),
            .response(status: 200, body: #"{"authenticated":false}"#),
            .response(status: 200, body: #"{"authenticated":true}"#),
            .response(status: 200, body: #"{"serverId":"sid","apiKey":"top-secret","ip":"x"}"#),
        ])
        let seerr = client(stub)
        let code = try await seerr.quickConnectInitiate()
        #expect(code.code == "123456")
        #expect(stub.requests[0].httpMethod == "POST")
        #expect(stub.requests[0].url?.path == "/api/v1/auth/jellyfin/quickconnect/initiate")
        #expect(try await seerr.quickConnectCheck(secret: "shh") == false)
        #expect(try await seerr.quickConnectCheck(secret: "shh") == true)
        #expect(stub.requests[1].httpMethod == "GET")
        #expect(queryString(stub.requests[1]) == "secret=shh")
        #expect(try await seerr.jellyfinServerId(adminKey: "k") == "sid")
        #expect(stub.requests[3].url?.path == "/api/v1/settings/jellyfin")
        #expect(stub.requests[3].value(forHTTPHeaderField: "X-API-User") == nil)
        #expect(!stub.exhausted)
    }

    @Test("logout swallows every error")
    func logoutSwallowsErrors() async {
        let stub = StubSeerrTransport([.failure(URLError(.notConnectedToInternet))])
        await client(stub).logout(cookie: "sid")
        #expect(stub.requests.count == 1)
    }

    @Test("The redirect policy keeps credentials on the origin only")
    func redirectPolicyKeepsOrigin() throws {
        let origin = try #require(URL(string: "http://h:5055/api/v1/status"))
        let task = URLSession.shared.dataTask(with: origin)
        let response = try #require(HTTPURLResponse(
            url: origin, statusCode: 301, httpVersion: "HTTP/1.1", headerFields: nil))

        func follow(_ target: String) throws -> URLRequest? {
            final class Box: @unchecked Sendable { var request: URLRequest?? = .none }
            let box = Box()
            let next = URLRequest(url: try #require(URL(string: target)))
            SeerrRedirectPolicy.shared.urlSession(
                URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: next
            ) { box.request = .some($0) }
            return try #require(box.request)
        }
        #expect(try follow("http://elsewhere.example/api/v1/status") == nil)
        #expect(try follow("https://h:5055/api/v1/status")?.url?.scheme == "https")
    }

    @Test("Credentials never print their secrets")
    func credentialsNeverPrintSecrets() {
        let secrets = ["TOPSECRETKEY", "SESSIONCOOKIE", "CSRFTOKEN", "QCSECRET", "QCCODE"]
        let values: [Any] = [
            SeerrQuickConnectCode(code: "QCCODE", secret: "QCSECRET"),
            SeerrCredential.apiKey(key: "TOPSECRETKEY", user: SeerrUserID(rawValue: 3)),
            SeerrCredential.session(cookie: "SESSIONCOOKIE"),
            SeerrLookupAuth.adminKey("TOPSECRETKEY"),
            SeerrLookupAuth.session(cookie: "SESSIONCOOKIE"),
            SeerrClient.Auth.credential(.session(cookie: "SESSIONCOOKIE")),
            SeerrClient.Auth.lookup(.adminKey("TOPSECRETKEY")),
            SeerrClient.Call(
                method: "POST", path: "/x", body: Data("CSRFTOKEN".utf8),
                auth: .credential(.apiKey(key: "TOPSECRETKEY", user: SeerrUserID(rawValue: 3)))),
        ]
        for value in values {
            for text in [String(describing: value), String(reflecting: value)] {
                for secret in secrets { #expect(!text.contains(secret), "\(text)") }
            }
        }
        #expect(String(describing: SeerrCredential.apiKey(key: "TOPSECRETKEY", user: SeerrUserID(rawValue: 3)))
            == "apiKey(user: 3)")
    }
}

// MARK: - Quick Connect sign-in

/// Records what the `@Sendable` approve closure was called with.
private final class ApprovalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [String] = []
    func record(_ code: String) { lock.withLock { codes.append(code) } }
    var recorded: [String] { lock.withLock { codes } }
}

@Suite("Seerr Quick Connect sign-in")
struct SeerrQuickConnectSignInTests {

    private let lanURL = URL(string: "http://192.168.1.20:5055")!
    private let initiated = StubSeerrTransport.Reply.response(status: 200, body: #"{"code":"123456","secret":"s"}"#)
    private let approvedCheck = StubSeerrTransport.Reply.response(status: 200, body: #"{"authenticated":true}"#)
    private let pendingCheck = StubSeerrTransport.Reply.response(status: 200, body: #"{"authenticated":false}"#)
    private let userJSON = #"{"id":2,"permissions":32,"jellyfinUserId":"abc","displayName":"Léa"}"#

    private func signIn(
        _ stub: StubSeerrTransport, box: ApprovalBox = ApprovalBox(), maxChecks: Int = 10,
        approve: @escaping @Sendable (String) async throws -> Bool = { _ in true }
    ) -> SeerrQuickConnectSignIn {
        SeerrQuickConnectSignIn(
            client: SeerrClient(baseURL: lanURL, languageCode: "fr", transport: stub),
            approve: { code in
                box.record(code)
                return try await approve(code)
            },
            maxChecks: maxChecks, pause: {})
    }

    private func failure(_ signIn: SeerrQuickConnectSignIn) async -> SeerrSignInError? {
        do {
            _ = try await signIn.run()
            return nil
        } catch {
            return error
        }
    }

    @Test("Signs in without typing: initiate, approve, check, authenticate")
    func signsInWithoutTyping() async throws {
        let stub = StubSeerrTransport([
            initiated, approvedCheck,
            .response(status: 200, headers: ["Set-Cookie": "connect.sid=s%3Aabc; Path=/; HttpOnly"], body: userJSON),
        ])
        let box = ApprovalBox()
        let result = try await signIn(stub, box: box).run()
        #expect(result.cookie == "s%3Aabc")
        #expect(result.user.id == SeerrUserID(rawValue: 2))
        #expect(box.recorded == ["123456"])
        #expect(!stub.exhausted)
    }

    @Test("A 404 from Jellyfin means the code belongs to another Jellyfin")
    func approval404IsOtherJellyfin() async {
        let stub = StubSeerrTransport([initiated])
        let result = await failure(signIn(stub) { _ in throw Get.APIError.unacceptableStatusCode(404) })
        #expect(result == .otherJellyfin)
        #expect(stub.requests.count == 1)
    }

    @Test("A 403 from Jellyfin is a refusal")
    func approval403IsRefused() async {
        let stub = StubSeerrTransport([initiated])
        let result = await failure(signIn(stub) { _ in throw Get.APIError.unacceptableStatusCode(403) })
        #expect(result == .jellyfinRefused)
    }

    @Test("Approval that answers false is another Jellyfin")
    func approvalFalse() async {
        let result = await failure(signIn(StubSeerrTransport([initiated])) { _ in false })
        #expect(result == .otherJellyfin)
    }

    @Test("Any other approval failure reads as unreachable")
    func approvalOtherErrorIsUnreachable() async {
        let result = await failure(signIn(StubSeerrTransport([initiated])) { _ in throw JellyfinError.notConnected })
        #expect(result == .seerr(.unreachable))
        #expect(SeerrQuickConnectSignIn.classifyApproval(Get.APIError.unacceptableStatusCode(500)) == .seerr(.unreachable))
    }

    @Test("A Seerr user never imported is notImported")
    func unimportedUser() async {
        let stub = StubSeerrTransport([
            initiated, approvedCheck, .response(status: 403, body: #"{"message":"Access denied."}"#),
        ])
        #expect(await failure(signIn(stub)) == .notImported)
    }

    @Test("Seerr errors surface as .seerr")
    func seerrErrorsSurface() async {
        let stub = StubSeerrTransport([.response(status: 500)])
        #expect(await failure(signIn(stub)) == .seerr(.http(500)))
    }

    @Test("check gives up after maxChecks")
    func checkGivesUp() async {
        let stub = StubSeerrTransport([initiated, pendingCheck, pendingCheck, pendingCheck, pendingCheck])
        #expect(await failure(signIn(stub, maxChecks: 3)) == .timedOut)
        #expect(stub.requests.count == 4)  // initiate + 3 checks
    }

    @Test("Cancellation is not a timeout nor a Seerr error")
    func cancellationIsCancelled() async {
        let stub = StubSeerrTransport([initiated])
        let result = await failure(signIn(stub) { _ in throw CancellationError() })
        #expect(result == .cancelled)
    }
}

@Suite("Seerr path segments")
struct SeerrPathSegmentTests {
    @Test("A Jellyfin id is one path segment, whatever it holds")
    func jellyfinIdIsEscaped() async throws {
        let stub = StubSeerrTransport([.response(status: 404)])
        let seerr = SeerrClient(baseURL: URL(string: "http://h:5055/seerr")!, languageCode: nil, transport: stub)
        let found = try await seerr.user(forJellyfinUserId: "a/../b?c", auth: .adminKey("k"))
        #expect(found == nil)
        #expect(stub.requests.first?.url?.absoluteString == "http://h:5055/seerr/api/v1/user/jellyfin/a%2F..%2Fb%3Fc")
    }
}
