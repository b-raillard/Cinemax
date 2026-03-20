import Foundation

public struct MediaItem: Sendable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let type: MediaType
    public let overview: String?
    public let year: Int?
    public let communityRating: Double?
    public let officialRating: String?
    public let runTimeTicks: Int64?

    public init(
        id: String,
        name: String,
        type: MediaType,
        overview: String? = nil,
        year: Int? = nil,
        communityRating: Double? = nil,
        officialRating: String? = nil,
        runTimeTicks: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.overview = overview
        self.year = year
        self.communityRating = communityRating
        self.officialRating = officialRating
        self.runTimeTicks = runTimeTicks
    }

    public var runtimeMinutes: Int? {
        guard let ticks = runTimeTicks else { return nil }
        return Int(ticks / 600_000_000)
    }
}

public enum MediaType: String, Sendable, Codable {
    case movie = "Movie"
    case series = "Series"
    case episode = "Episode"
    case boxSet = "BoxSet"
    case unknown = "Unknown"
}
