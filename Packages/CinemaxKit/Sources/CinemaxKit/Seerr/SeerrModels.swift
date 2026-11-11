import Foundation

// MARK: - Decoding

/// Decoding rules shared by every Seerr response: ISO 8601 dates, with or
/// without fractional seconds (Seerr emits `2026-11-01T10:00:00.000Z`).
public enum SeerrJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let withFractions = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            if let date = try? withFractions.parse(string) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrecognised ISO 8601 date: \(string)")
        }
        return decoder
    }
}

/// Decodes a `[SeerrTitle]`, dropping people / collections, and — for
/// collection `parts` — reading a missing `mediaType` as a movie.
private struct LossyTitle: Decodable {
    let title: SeerrTitle?
    init(from decoder: Decoder) throws {
        title = try? SeerrTitle(from: decoder, defaultKind: nil)
    }
}

private struct LossyPart: Decodable {
    let title: SeerrTitle?
    init(from decoder: Decoder) throws {
        title = try? SeerrTitle(from: decoder, defaultKind: .movie)
    }
}

/// `/movie/{id}`: Seerr serves it WITHOUT `mediaType` (measured on 3.5.1,
/// 2026-11-07) — only search results and credits carry one.
struct SeerrMovieDetails: Decodable {
    let title: SeerrTitle
    init(from decoder: Decoder) throws {
        title = try SeerrTitle(from: decoder, defaultKind: .movie)
    }
}

// MARK: - Server

public struct SeerrStatusInfo: Sendable, Equatable, Decodable {
    public let version: String
    public init(version: String) { self.version = version }
}

public struct SeerrPublicSettings: Sendable, Equatable, Decodable {
    public let mediaServerType: Int
    public let mediaServerLogin: Bool
    public let newPlexLogin: Bool
    public let partialRequestsEnabled: Bool
    public let enableSpecialEpisodes: Bool
    public let cacheImages: Bool

    public var isJellyfin: Bool { mediaServerType == 2 }

    public init(
        mediaServerType: Int, mediaServerLogin: Bool = true, newPlexLogin: Bool = false,
        partialRequestsEnabled: Bool = true, enableSpecialEpisodes: Bool = false,
        cacheImages: Bool = false
    ) {
        self.mediaServerType = mediaServerType
        self.mediaServerLogin = mediaServerLogin
        self.newPlexLogin = newPlexLogin
        self.partialRequestsEnabled = partialRequestsEnabled
        self.enableSpecialEpisodes = enableSpecialEpisodes
        self.cacheImages = cacheImages
    }

    private enum CodingKeys: String, CodingKey {
        case mediaServerType, mediaServerLogin, newPlexLogin
        case partialRequestsEnabled, enableSpecialEpisodes, cacheImages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaServerType = try c.decodeIfPresent(Int.self, forKey: .mediaServerType) ?? 0
        mediaServerLogin = try c.decodeIfPresent(Bool.self, forKey: .mediaServerLogin) ?? false
        newPlexLogin = try c.decodeIfPresent(Bool.self, forKey: .newPlexLogin) ?? false
        partialRequestsEnabled = try c.decodeIfPresent(Bool.self, forKey: .partialRequestsEnabled) ?? true
        enableSpecialEpisodes = try c.decodeIfPresent(Bool.self, forKey: .enableSpecialEpisodes) ?? false
        cacheImages = try c.decodeIfPresent(Bool.self, forKey: .cacheImages) ?? false
    }
}

// MARK: - Users

public enum SeerrMediaKind: String, Sendable, Equatable, Hashable, Decodable {
    case movie, tv
}

public struct SeerrPermissions: OptionSet, Sendable, Equatable, Hashable, Decodable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let admin = Self(rawValue: 2)
    public static let manageUsers = Self(rawValue: 8)
    public static let manageRequests = Self(rawValue: 16)
    public static let request = Self(rawValue: 32)
    public static let autoApprove = Self(rawValue: 128)
    public static let autoApproveMovie = Self(rawValue: 256)
    public static let autoApproveTV = Self(rawValue: 512)
    public static let requestView = Self(rawValue: 16384)
    public static let requestMovie = Self(rawValue: 262144)
    public static let requestTV = Self(rawValue: 524288)
    public static let manageIssues = Self(rawValue: 1048576)
    public static let createIssues = Self(rawValue: 4194304)

    /// Admins pass every check, as on the Seerr server.
    public func allows(_ p: Self) -> Bool {
        contains(.admin) || contains(p)
    }

    public var canManageRequests: Bool { allows(.manageRequests) }
    /// May report a problem on a title (`POST /issue` asks for one of the two,
    /// read in Seerr 3.5.1's issue route).
    public var canReportIssues: Bool { allows(.createIssues) || contains(.manageIssues) }
    /// May change another user's permissions (`POST /user/{id}/settings/permissions`).
    public var canManageUsers: Bool { allows(.manageUsers) }

    /// As Seerr decides when the request is created: an admin, a manager of
    /// requests and the auto-approve bits all skip « À valider » (read in
    /// Seerr 3.5.1's `MediaRequest`, which ORs `MANAGE_REQUESTS` in).
    public func autoApproves(_ kind: SeerrMediaKind) -> Bool {
        allows(.manageRequests) || grantsAutoApprove(kind)
    }

    /// Approved without review because of the bits alone — never because the
    /// user is an admin or a manager. What « Validation automatique » shows.
    public func grantsAutoApprove(_ kind: SeerrMediaKind) -> Bool {
        if contains(.autoApprove) { return true }
        switch kind {
        case .movie: return contains(.autoApproveMovie)
        case .tv: return contains(.autoApproveTV)
        }
    }

    /// The same permissions with one kind's auto-approval switched. Only the
    /// three non-4K bits move: both kinds on ⇒ `autoApprove` alone, one ⇒ its
    /// own bit; every other bit (4K, admin, request…) is kept as it was.
    public func settingAutoApprove(_ kind: SeerrMediaKind, _ on: Bool) -> Self {
        let movie = kind == .movie ? on : grantsAutoApprove(.movie)
        let tv = kind == .tv ? on : grantsAutoApprove(.tv)
        var next = subtracting([.autoApprove, .autoApproveMovie, .autoApproveTV])
        if movie && tv {
            next.insert(.autoApprove)
        } else if movie {
            next.insert(.autoApproveMovie)
        } else if tv {
            next.insert(.autoApproveTV)
        }
        return next
    }

    /// The same permissions with the right to report a problem switched: only
    /// `createIssues` moves, every other bit is kept.
    public func settingIssueReporting(_ on: Bool) -> Self {
        on ? union(.createIssues) : subtracting(.createIssues)
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }
}

public struct SeerrUserID: Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
}

public struct SeerrUser: Sendable, Equatable, Decodable {
    public let id: SeerrUserID
    public let permissions: SeerrPermissions
    public let jellyfinUserId: String?
    public let displayName: String?

    public init(
        id: SeerrUserID, permissions: SeerrPermissions,
        jellyfinUserId: String? = nil, displayName: String? = nil
    ) {
        self.id = id
        self.permissions = permissions
        self.jellyfinUserId = jellyfinUserId
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case id, permissions, jellyfinUserId, displayName, jellyfinUsername
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = SeerrUserID(rawValue: try c.decode(Int.self, forKey: .id))
        permissions = SeerrPermissions(rawValue: try c.decodeIfPresent(Int.self, forKey: .permissions) ?? 0)
        jellyfinUserId = try c.decodeIfPresent(String.self, forKey: .jellyfinUserId)
        let display = try c.decodeIfPresent(String.self, forKey: .displayName)
        let fallback = try c.decodeIfPresent(String.self, forKey: .jellyfinUsername)
        displayName = (display?.isEmpty == false) ? display : fallback
    }
}

// MARK: - Statuses

public enum SeerrMediaStatus: Int, Sendable, Equatable, Hashable, Decodable {
    case unknown = 1, pending, processing, partiallyAvailable, available, blocklisted, deleted

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public enum SeerrRequestStatus: Int, Sendable, Equatable, Hashable, Decodable {
    case pending = 1, approved, declined, failed, completed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = Self(rawValue: raw) ?? .pending
    }
}

// MARK: - Media info

public struct SeerrSeasonInfo: Sendable, Equatable, Decodable {
    public let seasonNumber: Int
    public let status: SeerrMediaStatus
    public init(seasonNumber: Int, status: SeerrMediaStatus) {
        self.seasonNumber = seasonNumber
        self.status = status
    }

    private enum CodingKeys: String, CodingKey { case seasonNumber, status }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasonNumber = try c.decode(Int.self, forKey: .seasonNumber)
        status = try c.decodeIfPresent(SeerrMediaStatus.self, forKey: .status) ?? .unknown
    }
}

public struct SeerrRequestSummary: Sendable, Equatable, Decodable {
    public let id: Int
    public let status: SeerrRequestStatus
    public let seasons: [Int]

    public init(id: Int, status: SeerrRequestStatus, seasons: [Int] = []) {
        self.id = id
        self.status = status
        self.seasons = seasons
    }

    private enum CodingKeys: String, CodingKey { case id, status, seasons }
    private struct SeasonNumber: Decodable { let seasonNumber: Int }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        status = try c.decodeIfPresent(SeerrRequestStatus.self, forKey: .status) ?? .pending
        seasons = (try c.decodeIfPresent([SeasonNumber].self, forKey: .seasons) ?? []).map(\.seasonNumber)
    }
}

public struct SeerrMediaInfo: Sendable, Equatable, Decodable {
    public let status: SeerrMediaStatus
    public let seasons: [SeerrSeasonInfo]
    public let requests: [SeerrRequestSummary]
    public let jellyfinMediaId: String?
    /// Seerr's own id of the media — what an issue (`POST /issue`) names.
    public let id: Int?

    public init(
        status: SeerrMediaStatus, seasons: [SeerrSeasonInfo] = [],
        requests: [SeerrRequestSummary] = [], jellyfinMediaId: String? = nil, id: Int? = nil
    ) {
        self.status = status
        self.seasons = seasons
        self.requests = requests
        self.jellyfinMediaId = jellyfinMediaId
        self.id = id
    }

    private enum CodingKeys: String, CodingKey { case status, seasons, requests, jellyfinMediaId, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(SeerrMediaStatus.self, forKey: .status) ?? .unknown
        seasons = try c.decodeIfPresent([SeerrSeasonInfo].self, forKey: .seasons) ?? []
        requests = try c.decodeIfPresent([SeerrRequestSummary].self, forKey: .requests) ?? []
        jellyfinMediaId = try c.decodeIfPresent(String.self, forKey: .jellyfinMediaId)
        id = try c.decodeIfPresent(Int.self, forKey: .id)
    }
}

/// One episode of a season as Seerr (TMDb) lists it — `GET /tv/{id}/season/{n}`.
public struct SeerrEpisode: Sendable, Equatable, Decodable {
    public let episodeNumber: Int
    public let name: String
    /// `yyyy-MM-dd`, or nil / empty while TMDb has no date: not aired, as far
    /// as anyone knows.
    public let airDate: String?
    /// TMDb's still of the episode as a PATH (« /abc.jpg »), nil without one.
    /// Seerr 3.5.1 sends a whole URL here (`…/t/p/original//abc.jpg`, measured
    /// on the bench 2026-11-11): only its file name is kept, so the image goes
    /// through `SeerrImages` like every poster, sized and proxied the same way.
    public let stillPath: String?

    public init(episodeNumber: Int, name: String, airDate: String?, stillPath: String? = nil) {
        self.episodeNumber = episodeNumber
        self.name = name
        self.airDate = airDate
        self.stillPath = stillPath
    }

    private enum CodingKeys: String, CodingKey { case episodeNumber, name, airDate, stillPath }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodeNumber = try c.decode(Int.self, forKey: .episodeNumber)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        airDate = try c.decodeIfPresent(String.self, forKey: .airDate)
        stillPath = Self.imagePath(try c.decodeIfPresent(String.self, forKey: .stillPath))
    }

    /// « /abc.jpg » from a TMDb path or a whole TMDb URL; nil when empty.
    public static func imagePath(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        guard raw.lowercased().hasPrefix("http") else { return raw.hasPrefix("/") ? raw : "/" + raw }
        guard let name = raw.split(separator: "/").last, !name.isEmpty, name.contains(".") else { return nil }
        return "/" + name
    }
}

/// A season's episodes; an episode that does not decode is skipped.
public struct SeerrSeasonEpisodes: Sendable, Equatable, Decodable {
    public let episodes: [SeerrEpisode]

    private enum CodingKeys: String, CodingKey { case episodes }
    private struct Lossy: Decodable {
        let episode: SeerrEpisode?
        init(from decoder: Decoder) throws { episode = try? SeerrEpisode(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodes = try c.decodeIfPresent([Lossy].self, forKey: .episodes)?.compactMap(\.episode) ?? []
    }
}

// MARK: - Titles

public struct SeerrTitle: Sendable, Equatable, Decodable {
    public let kind: SeerrMediaKind
    public let tmdbId: Int
    public let title: String
    public let year: Int?
    public let overview: String?
    public let posterPath: String?
    public let mediaInfo: SeerrMediaInfo?

    public init(
        kind: SeerrMediaKind, tmdbId: Int, title: String, year: Int? = nil,
        overview: String? = nil, posterPath: String? = nil, mediaInfo: SeerrMediaInfo? = nil
    ) {
        self.kind = kind
        self.tmdbId = tmdbId
        self.title = title
        self.year = year
        self.overview = overview
        self.posterPath = posterPath
        self.mediaInfo = mediaInfo
    }

    private enum CodingKeys: String, CodingKey {
        case mediaType, id, title, name, releaseDate, firstAirDate, overview, posterPath, mediaInfo
    }

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, defaultKind: nil)
    }

    /// `defaultKind` stands in for a missing `mediaType` (collection `parts`).
    /// A `person` / `collection` entry, or an unknown type, throws.
    fileprivate init(from decoder: Decoder, defaultKind: SeerrMediaKind?) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try c.decodeIfPresent(String.self, forKey: .mediaType)
        let resolved: SeerrMediaKind?
        if let rawType { resolved = SeerrMediaKind(rawValue: rawType) } else { resolved = defaultKind }
        guard let resolved else {
            throw DecodingError.dataCorruptedError(
                forKey: .mediaType, in: c, debugDescription: "Not a movie or a series")
        }
        kind = resolved
        tmdbId = try c.decode(Int.self, forKey: .id)
        let main = try c.decodeIfPresent(String.self, forKey: .title)
        let alt = try c.decodeIfPresent(String.self, forKey: .name)
        title = main ?? alt ?? ""
        let date = try c.decodeIfPresent(String.self, forKey: .releaseDate)
        let airDate = try c.decodeIfPresent(String.self, forKey: .firstAirDate)
        let dateString = [date, airDate].compactMap { $0 }.first { !$0.isEmpty }
        year = dateString.flatMap { Int($0.prefix(4)) }
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
        // A malformed `mediaInfo` costs the title its status, not its place.
        mediaInfo = try? c.decodeIfPresent(SeerrMediaInfo.self, forKey: .mediaInfo)
    }
}

public struct SeerrSearchPage: Sendable, Equatable, Decodable {
    public let results: [SeerrTitle]
    public let totalPages: Int

    public init(results: [SeerrTitle], totalPages: Int) {
        self.results = results
        self.totalPages = totalPages
    }

    private enum CodingKeys: String, CodingKey { case results, totalPages }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decode([LossyTitle].self, forKey: .results).compactMap(\.title)
        totalPages = try c.decodeIfPresent(Int.self, forKey: .totalPages) ?? 1
    }
}

public struct SeerrSeason: Sendable, Equatable, Decodable {
    public let seasonNumber: Int
    public let episodeCount: Int
    /// The season's own TMDb poster (the missing-season cards); nil when TMDb has none.
    public let posterPath: String?

    public init(seasonNumber: Int, episodeCount: Int, posterPath: String? = nil) {
        self.seasonNumber = seasonNumber
        self.episodeCount = episodeCount
        self.posterPath = posterPath
    }

    private enum CodingKeys: String, CodingKey { case seasonNumber, episodeCount, posterPath }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasonNumber = try c.decode(Int.self, forKey: .seasonNumber)
        episodeCount = try c.decodeIfPresent(Int.self, forKey: .episodeCount) ?? 0
        posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
    }
}

public struct SeerrTVDetails: Sendable, Equatable, Decodable {
    public let tmdbId: Int
    public let name: String
    public let seasons: [SeerrSeason]
    public let mediaInfo: SeerrMediaInfo?
    /// The TMDb poster path (Mes demandes' rows).
    public let posterPath: String?

    public init(
        tmdbId: Int, name: String, seasons: [SeerrSeason], mediaInfo: SeerrMediaInfo? = nil,
        posterPath: String? = nil
    ) {
        self.tmdbId = tmdbId
        self.name = name
        self.seasons = seasons
        self.mediaInfo = mediaInfo
        self.posterPath = posterPath
    }

    private enum CodingKeys: String, CodingKey { case id, name, seasons, mediaInfo, posterPath }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tmdbId = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        seasons = try c.decodeIfPresent([SeerrSeason].self, forKey: .seasons) ?? []
        mediaInfo = try c.decodeIfPresent(SeerrMediaInfo.self, forKey: .mediaInfo)
        posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
    }
}

public struct SeerrCollection: Sendable, Equatable, Decodable {
    public let id: Int
    public let name: String
    public let parts: [SeerrTitle]

    public init(id: Int, name: String, parts: [SeerrTitle]) {
        self.id = id
        self.name = name
        self.parts = parts
    }

    private enum CodingKeys: String, CodingKey { case id, name, parts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        parts = (try c.decodeIfPresent([LossyPart].self, forKey: .parts) ?? []).compactMap(\.title)
    }
}

public struct SeerrPerson: Sendable, Equatable, Decodable {
    public let knownForDepartment: String?
    public init(knownForDepartment: String? = nil) { self.knownForDepartment = knownForDepartment }
}

public struct SeerrCombinedCredits: Sendable, Equatable, Decodable {
    public let cast: [SeerrTitle]
    public let crew: [SeerrTitle]

    public init(cast: [SeerrTitle], crew: [SeerrTitle]) {
        self.cast = cast
        self.crew = crew
    }

    private enum CodingKeys: String, CodingKey { case cast, crew }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cast = (try c.decodeIfPresent([LossyTitle].self, forKey: .cast) ?? []).compactMap(\.title)
        crew = (try c.decodeIfPresent([LossyTitle].self, forKey: .crew) ?? []).compactMap(\.title)
    }
}

// MARK: - Requests

public struct SeerrRequestMedia: Sendable, Equatable, Decodable {
    public let tmdbId: Int
    public let status: SeerrMediaStatus
    public let jellyfinMediaId: String?

    public init(tmdbId: Int, status: SeerrMediaStatus, jellyfinMediaId: String? = nil) {
        self.tmdbId = tmdbId
        self.status = status
        self.jellyfinMediaId = jellyfinMediaId
    }

    private enum CodingKeys: String, CodingKey { case tmdbId, status, jellyfinMediaId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tmdbId = try c.decode(Int.self, forKey: .tmdbId)
        status = try c.decodeIfPresent(SeerrMediaStatus.self, forKey: .status) ?? .unknown
        jellyfinMediaId = try c.decodeIfPresent(String.self, forKey: .jellyfinMediaId)
    }
}

public struct SeerrRequest: Sendable, Equatable, Decodable {
    public let id: Int
    public let status: SeerrRequestStatus
    public let kind: SeerrMediaKind
    public let seasons: [Int]
    public let createdAt: Date
    public let updatedAt: Date
    public let requestedBy: SeerrUser
    public let media: SeerrRequestMedia

    public init(
        id: Int, status: SeerrRequestStatus, kind: SeerrMediaKind, seasons: [Int] = [],
        createdAt: Date, updatedAt: Date, requestedBy: SeerrUser, media: SeerrRequestMedia
    ) {
        self.id = id
        self.status = status
        self.kind = kind
        self.seasons = seasons
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.requestedBy = requestedBy
        self.media = media
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, type, seasons, createdAt, updatedAt, requestedBy, media
    }
    private struct SeasonNumber: Decodable { let seasonNumber: Int }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        status = try c.decodeIfPresent(SeerrRequestStatus.self, forKey: .status) ?? .pending
        kind = try c.decode(SeerrMediaKind.self, forKey: .type)
        seasons = (try c.decodeIfPresent([SeasonNumber].self, forKey: .seasons) ?? []).map(\.seasonNumber)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        requestedBy = try c.decode(SeerrUser.self, forKey: .requestedBy)
        media = try c.decode(SeerrRequestMedia.self, forKey: .media)
    }
}

public struct SeerrRequestPage: Sendable, Equatable, Decodable {
    /// The rows that decoded: an odd one (no asker, an unknown kind…) is
    /// skipped, never fatal to the page.
    public let results: [SeerrRequest]
    public let total: Int
    /// How many rows the server SENT, skipped ones included: the next page's
    /// `skip` — counting only `results` would re-ask the skipped rows forever.
    public let served: Int

    public init(results: [SeerrRequest], total: Int, served: Int? = nil) {
        self.results = results
        self.total = total
        self.served = served ?? results.count
    }

    private enum CodingKeys: String, CodingKey { case results, pageInfo }
    private struct PageInfo: Decodable { let results: Int }
    private struct LossyRequest: Decodable {
        let request: SeerrRequest?
        init(from decoder: Decoder) throws {
            request = try? SeerrRequest(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try c.decode([LossyRequest].self, forKey: .results)
        results = rows.compactMap(\.request)
        served = rows.count
        total = try c.decode(PageInfo.self, forKey: .pageInfo).results
    }
}

// MARK: - Quick Connect

public struct SeerrQuickConnectCode: Sendable, Equatable, Decodable {
    public let code: String
    public let secret: String
    public init(code: String, secret: String) {
        self.code = code
        self.secret = secret
    }
}

// The `secret` is never logged (Seerr RULE): like the credentials, the
// descriptions print nothing of the values (`dump` / `Mirror` still would).
extension SeerrQuickConnectCode: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "SeerrQuickConnectCode(…)" }
    public var debugDescription: String { description }
}
