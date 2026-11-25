import Foundation

/// What the request fiche shows beyond the card: `/movie/{id}` or `/tv/{id}`
/// read whole (measured on Seerr 3.5.1 and 3.5.2, 2026-11-22). Every field is
/// optional or lossy — a missing or malformed one empties that block of the
/// fiche, never the decode. `SeerrTitle` stays the card's model.
public struct SeerrTitleDetails: Sendable, Equatable, Decodable {
    public struct CastMember: Sendable, Equatable, Decodable {
        public let name: String
        public let character: String?
        public let profilePath: String?

        public init(name: String, character: String? = nil, profilePath: String? = nil) {
            self.name = name
            self.character = character
            self.profilePath = profilePath
        }
    }

    public let backdropPath: String?
    /// A film's `runtime`, or a series' first `episodeRunTime`.
    public let runtimeMinutes: Int?
    public let voteAverage: Double?
    public let voteCount: Int?
    /// TMDb's names, already in the language the lookup asked for.
    public let genres: [String]
    /// `originalTitle` (film) or `originalName` (series).
    public let originalTitle: String?
    /// ISO 639-1 (`en`).
    public let originalLanguage: String?
    /// `yyyy-MM-dd`: `releaseDate` (film) or `firstAirDate` (series).
    public let releaseDate: String?
    /// In TMDb's billing order, at most `castLimit`.
    public let cast: [CastMember]
    /// A film's directors, or a series' creators (`createdBy`).
    public let creators: [String]
    /// The first YouTube trailer, else the first teaser (Seerr's own `url`).
    public let trailerURL: URL?
    /// Subscription services (`flatrate`) per ISO 3166-1 region.
    public let streamingProviders: [String: [String]]

    public static let castLimit = 15

    public init(
        backdropPath: String? = nil, runtimeMinutes: Int? = nil, voteAverage: Double? = nil, voteCount: Int? = nil,
        genres: [String] = [], originalTitle: String? = nil, originalLanguage: String? = nil,
        releaseDate: String? = nil, cast: [CastMember] = [], creators: [String] = [], trailerURL: URL? = nil,
        streamingProviders: [String: [String]] = [:]
    ) {
        self.backdropPath = backdropPath
        self.runtimeMinutes = runtimeMinutes
        self.voteAverage = voteAverage
        self.voteCount = voteCount
        self.genres = genres
        self.originalTitle = originalTitle
        self.originalLanguage = originalLanguage
        self.releaseDate = releaseDate
        self.cast = cast
        self.creators = creators
        self.trailerURL = trailerURL
        self.streamingProviders = streamingProviders
    }

    private enum CodingKeys: String, CodingKey {
        case backdropPath, runtime, episodeRunTime, voteAverage, voteCount, genres
        case originalTitle, originalName, originalLanguage, releaseDate, firstAirDate
        case credits, createdBy, relatedVideos, watchProviders
    }

    private struct Named: Decodable { let name: String? }
    private struct Crew: Decodable { let name: String?; let job: String? }
    private struct Credits: Decodable {
        let cast: [Lossy<CastMember>]?
        let crew: [Lossy<Crew>]?
    }
    private struct Video: Decodable { let type: String?; let site: String?; let url: String? }
    private struct Providers: Decodable {
        let region: String?
        let flatrate: [Named]?
        enum CodingKeys: String, CodingKey { case region = "iso_3166_1", flatrate }
    }
    /// One bad element drops itself, not the list.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            guard let value = try? c.decodeIfPresent(String.self, forKey: key), !value.isEmpty else { return nil }
            return value
        }
        /// `try?` flattens: absent and malformed both read as nil.
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            try? c.decodeIfPresent(type, forKey: key)
        }
        func names(_ key: CodingKeys) -> [String] {
            (value([Lossy<Named>].self, key) ?? []).compactMap { $0.value?.name }.filter { !$0.isEmpty }
        }
        backdropPath = text(.backdropPath)
        let episodeRuntime = value([Int].self, .episodeRunTime)?.first
        runtimeMinutes = [value(Int.self, .runtime), episodeRuntime].compactMap { $0 }.first { $0 > 0 }
        let vote = value(Double.self, .voteAverage)
        voteCount = value(Int.self, .voteCount)
        voteAverage = (vote ?? 0) > 0 && (voteCount ?? 0) > 0 ? vote : nil
        genres = names(.genres)
        originalTitle = text(.originalTitle) ?? text(.originalName)
        originalLanguage = text(.originalLanguage)
        releaseDate = text(.releaseDate) ?? text(.firstAirDate)

        let credits = value(Credits.self, .credits)
        cast = Array((credits?.cast ?? []).compactMap(\.value).filter { !$0.name.isEmpty }.prefix(Self.castLimit))
        let directors = (credits?.crew ?? []).compactMap(\.value).filter { $0.job == "Director" }.compactMap(\.name)
        var seen = Set<String>()
        creators = (directors.isEmpty ? names(.createdBy) : directors).filter { !$0.isEmpty && seen.insert($0).inserted }

        let videos = (value([Lossy<Video>].self, .relatedVideos) ?? []).compactMap(\.value).filter { $0.site == "YouTube" }
        let pick = videos.first { $0.type == "Trailer" } ?? videos.first { $0.type == "Teaser" }
        trailerURL = pick?.url.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }

        var providers: [String: [String]] = [:]
        for entry in (value([Lossy<Providers>].self, .watchProviders) ?? [])
            .compactMap(\.value) {
            guard let region = entry.region?.uppercased(), !region.isEmpty else { continue }
            let names = (entry.flatrate ?? []).compactMap(\.name).filter { !$0.isEmpty }
            if !names.isEmpty { providers[region] = names }
        }
        streamingProviders = providers
    }
}
