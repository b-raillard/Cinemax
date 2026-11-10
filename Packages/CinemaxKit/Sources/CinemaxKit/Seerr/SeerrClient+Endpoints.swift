import Foundation

// MARK: - Request types

public enum SeerrNewRequest: Sendable, Equatable {
    case movie(tmdbId: Int)
    case tv(tmdbId: Int, seasons: [Int])
}

public enum SeerrRequestFilter: String, Sendable {
    case all, pending, available
}

// MARK: - Endpoints

extension SeerrClient {
    // MARK: Server

    public func status() async throws -> SeerrStatusInfo {
        try await get("/status", query: [], auth: .none, localized: false)
    }

    public func publicSettings() async throws -> SeerrPublicSettings {
        try await get("/settings/public", query: [], auth: .none, localized: false)
    }

    // MARK: Quick Connect

    public func quickConnectInitiate() async throws -> SeerrQuickConnectCode {
        let (code, status): (SeerrQuickConnectCode?, Int) = try await mutate(
            "POST", "/auth/jellyfin/quickconnect/initiate", body: nil, auth: .none)
        guard let code else { throw SeerrError.http(status) }
        return code
    }

    public func quickConnectCheck(secret: String) async throws -> Bool {
        struct Answer: Decodable { let authenticated: Bool }
        let answer: Answer = try await get(
            "/auth/jellyfin/quickconnect/check",
            query: [URLQueryItem(name: "secret", value: secret)], auth: .none, localized: false)
        return answer.authenticated
    }

    /// The session cookie's value (`connect.sid`) and the Seerr user it belongs
    /// to. The cookie is read through `cookies(in:)`, never `HTTPCookie`
    /// directly: that drops a `Secure` cookie for an `http://` address.
    public func quickConnectAuthenticate(secret: String) async throws -> (cookie: String, user: SeerrUser) {
        struct Body: Encodable { let secret: String }
        let payload = try JSONEncoder().encode(Body(secret: secret))
        let (data, response) = try await perform(
            Call(method: "POST", path: "/auth/jellyfin/quickconnect/authenticate", body: payload))
        guard let cookie = Self.cookies(in: response)["connect.sid"], !cookie.isEmpty else {
            throw SeerrError.http(response.statusCode)
        }
        return (cookie, try SeerrJSON.decoder().decode(SeerrUser.self, from: data))
    }

    /// Best effort: a failed logout changes nothing the caller can act on.
    public func logout(cookie: String) async {
        let _: (Empty?, Int)? = try? await mutate(
            "POST", "/auth/logout", body: nil, auth: .credential(.session(cookie: cookie)))
    }

    // MARK: Users

    public func me(_ credential: SeerrCredential) async throws -> SeerrUser {
        try await get("/auth/me", query: [], auth: .credential(credential), localized: false)
    }

    /// `nil` when Seerr has no account for this Jellyfin user (404).
    public func user(forJellyfinUserId id: String, auth: SeerrLookupAuth) async throws -> SeerrUser? {
        do {
            // A path segment: an id holding `/` or `?` must not change the route.
            let segment = id.addingPercentEncoding(withAllowedCharacters: .urlPathSegmentAllowed) ?? id
            return try await get("/user/jellyfin/\(segment)", query: [], auth: .lookup(auth), localized: false)
        } catch SeerrError.notFound {
            return nil
        }
    }

    /// Another user's permissions, as stored now (MANAGE_USERS).
    public func permissions(ofUser id: SeerrUserID, _ credential: SeerrCredential) async throws -> SeerrPermissions {
        struct Answer: Decodable { let permissions: Int }
        let answer: Answer = try await get(
            "/user/\(id.rawValue)/settings/permissions", query: [], auth: .credential(credential), localized: false)
        return SeerrPermissions(rawValue: answer.permissions)
    }

    /// Replaces another user's WHOLE permission set (MANAGE_USERS): read it
    /// first and change only what is meant. Seerr refuses (403) the owner
    /// (id 1), the caller's own account, and granting `admin` unless the
    /// caller is the owner. Returns what Seerr stored.
    @discardableResult
    public func setPermissions(
        _ permissions: SeerrPermissions, ofUser id: SeerrUserID, _ credential: SeerrCredential
    ) async throws -> SeerrPermissions {
        struct Body: Codable { let permissions: Int }
        let (stored, status): (Body?, Int) = try await mutate(
            "POST", "/user/\(id.rawValue)/settings/permissions",
            body: Body(permissions: permissions.rawValue), auth: .credential(credential))
        guard let stored else { throw SeerrError.http(status) }
        return SeerrPermissions(rawValue: stored.permissions)
    }

    /// Reads `serverId` only: the rest of the body holds Seerr's own Jellyfin
    /// API key and is never logged.
    public func jellyfinServerId(adminKey: String) async throws -> String {
        struct Settings: Decodable { let serverId: String }
        let settings: Settings = try await get(
            "/settings/jellyfin", query: [], auth: .lookup(.adminKey(adminKey)), localized: false)
        return settings.serverId
    }

    // MARK: Catalogue

    public func search(_ query: String, _ credential: SeerrCredential) async throws -> [SeerrTitle] {
        try await searchPage(query, page: 1, credential).results
    }

    /// One page of matches (20, TMDb's paging) with `totalPages`: the search
    /// asks for the second only when it owns everything on the first.
    public func searchPage(_ query: String, page: Int, _ credential: SeerrCredential) async throws -> SeerrSearchPage {
        try await get(
            "/search",
            query: [URLQueryItem(name: "query", value: query), URLQueryItem(name: "page", value: String(page))],
            auth: .credential(credential), localized: true)
    }

    public func movie(tmdbId: Int, _ credential: SeerrCredential) async throws -> SeerrTitle {
        let details: SeerrMovieDetails = try await get(
            "/movie/\(tmdbId)", query: [], auth: .credential(credential), localized: true)
        return details.title
    }

    public func tv(tmdbId: Int, _ credential: SeerrCredential) async throws -> SeerrTVDetails {
        try await get("/tv/\(tmdbId)", query: [], auth: .credential(credential), localized: true)
    }

    public func collection(id: Int, _ credential: SeerrCredential) async throws -> SeerrCollection {
        try await get("/collection/\(id)", query: [], auth: .credential(credential), localized: true)
    }

    public func person(id: Int, _ credential: SeerrCredential) async throws -> SeerrPerson {
        try await get("/person/\(id)", query: [], auth: .credential(credential), localized: true)
    }

    public func combinedCredits(personId: Int, _ credential: SeerrCredential) async throws -> SeerrCombinedCredits {
        try await get(
            "/person/\(personId)/combined_credits", query: [], auth: .credential(credential), localized: true)
    }

    // MARK: Requests

    public func createRequest(_ request: SeerrNewRequest, _ credential: SeerrCredential) async throws -> SeerrRequest {
        struct Body: Encodable {
            let mediaType: String
            let mediaId: Int
            let seasons: [Int]?
        }
        let body: Body
        switch request {
        case .movie(let tmdbId): body = Body(mediaType: "movie", mediaId: tmdbId, seasons: nil)
        case .tv(let tmdbId, let seasons): body = Body(mediaType: "tv", mediaId: tmdbId, seasons: seasons)
        }
        let (created, status): (SeerrRequest?, Int) = try await mutate(
            "POST", "/request", body: body, auth: .credential(credential))
        if status == 202 { throw SeerrError.noSeasonsAvailable }
        guard let created else { throw SeerrError.http(status) }
        return created
    }

    /// `sort=modified` always; `requestedBy` only when given — My requests and
    /// the arrival pass it, the manager's queue does not.
    public func requests(
        filter: SeerrRequestFilter, take: Int, skip: Int, requestedBy: SeerrUserID?, _ credential: SeerrCredential
    ) async throws -> SeerrRequestPage {
        var query = [
            URLQueryItem(name: "take", value: String(take)),
            URLQueryItem(name: "skip", value: String(skip)),
            URLQueryItem(name: "filter", value: filter.rawValue),
            URLQueryItem(name: "sort", value: "modified")
        ]
        if let requestedBy {
            query.append(URLQueryItem(name: "requestedBy", value: String(requestedBy.rawValue)))
        }
        return try await get("/request", query: query, auth: .credential(credential), localized: false)
    }

    public func approve(requestId: Int, _ credential: SeerrCredential) async throws {
        let _: (Empty?, Int) = try await mutate(
            "POST", "/request/\(requestId)/approve", body: nil, auth: .credential(credential))
    }

    public func decline(requestId: Int, _ credential: SeerrCredential) async throws {
        let _: (Empty?, Int) = try await mutate(
            "POST", "/request/\(requestId)/decline", body: nil, auth: .credential(credential))
    }

    /// Withdraws a request. Seerr lets its asker do it only while it is
    /// PENDING (401 otherwise, measured on 3.5.1); a manager, always.
    public func deleteRequest(requestId: Int, _ credential: SeerrCredential) async throws {
        let _: (Empty?, Int) = try await mutate(
            "DELETE", "/request/\(requestId)", body: nil, auth: .credential(credential))
    }

    /// A body nobody reads (approve, decline, delete, logout): decoding it is skipped.
    struct Empty: Decodable {}
}

private extension CharacterSet {
    /// RFC 3986 `pchar` minus the sub-delimiters: `/`, `?`, `#` and the like are encoded.
    static let urlPathSegmentAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}
