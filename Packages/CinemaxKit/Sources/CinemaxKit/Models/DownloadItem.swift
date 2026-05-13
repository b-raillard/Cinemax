import Foundation

public enum DownloadStatus: String, Codable, Sendable {
    case queued
    case downloading
    case paused
    case completed
    case failed
}

public enum DownloadKind: String, Codable, Sendable {
    case movie
    case episode
}

/// One downloaded (or downloading) media file. Movies and episodes only —
/// downloading a Series or Season fans out into one `DownloadItem` per episode.
///
/// `id` is the Jellyfin item id so the same DTO can be queried by both
/// `DownloadStore` and `MediaDetailScreen` without translation.
///
/// The metadata block (overview, year, genres, ratings) is cached so the
/// detail screen can render a full offline view without hitting the server.
public struct DownloadItem: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let kind: DownloadKind
    public let title: String
    public let posterTag: String?

    public let seriesId: String?
    public let seriesTitle: String?
    public let seasonId: String?
    public let seasonName: String?
    public let seasonIndex: Int?
    public let episodeIndex: Int?

    public let remoteURL: URL
    /// Container extension of the on-disk file. Pre-completion this holds the
    /// catalog's initial guess (from the server media source); the manager
    /// refines it from the response headers once the file lands.
    public var containerExt: String
    public let runtimeTicks: Int?

    // Offline-render metadata — cached at enqueue time.
    public let overview: String?
    public let productionYear: Int?
    public let genres: [String]
    public let officialRating: String?
    public let communityRating: Float?
    public let premiereDate: Date?
    public let backdropItemID: String?

    public var status: DownloadStatus
    public var bytesReceived: Int64
    public var totalBytes: Int64
    /// File name within the downloads directory. `nil` until a download finishes.
    public var localFileName: String?
    /// Persisted resume data so a paused or interrupted task can be picked back
    /// up after relaunch.
    public var resumeData: Data?
    public var errorMessage: String?
    public let createdAt: Date
    public var completedAt: Date?

    public init(
        id: String,
        kind: DownloadKind,
        title: String,
        posterTag: String?,
        seriesId: String?,
        seriesTitle: String?,
        seasonId: String?,
        seasonName: String?,
        seasonIndex: Int?,
        episodeIndex: Int?,
        remoteURL: URL,
        containerExt: String,
        runtimeTicks: Int?,
        overview: String? = nil,
        productionYear: Int? = nil,
        genres: [String] = [],
        officialRating: String? = nil,
        communityRating: Float? = nil,
        premiereDate: Date? = nil,
        backdropItemID: String? = nil,
        status: DownloadStatus = .queued,
        bytesReceived: Int64 = 0,
        totalBytes: Int64 = 0,
        localFileName: String? = nil,
        resumeData: Data? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.posterTag = posterTag
        self.seriesId = seriesId
        self.seriesTitle = seriesTitle
        self.seasonId = seasonId
        self.seasonName = seasonName
        self.seasonIndex = seasonIndex
        self.episodeIndex = episodeIndex
        self.remoteURL = remoteURL
        self.containerExt = containerExt
        self.runtimeTicks = runtimeTicks
        self.overview = overview
        self.productionYear = productionYear
        self.genres = genres
        self.officialRating = officialRating
        self.communityRating = communityRating
        self.premiereDate = premiereDate
        self.backdropItemID = backdropItemID
        self.status = status
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.localFileName = localFileName
        self.resumeData = resumeData
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(bytesReceived) / Double(totalBytes))
    }

    public var isTerminal: Bool {
        status == .completed || status == .failed
    }

    /// AVKit's native demuxer supports MP4-family containers and HLS / MPEG-TS.
    /// MKV / AVI / WebM downloads complete fine but `AVPlayer` opens them as
    /// audio-only (no video track surfaced), which surprised users with the
    /// QuickTime audio icon during playback. UI surfaces use this to warn at
    /// enqueue time and to short-circuit playback with a clearer message.
    public static let avkitFriendlyContainers: Set<String> = [
        "mp4", "m4v", "m4a", "mov", "ts", "m2ts", "3gp", "3g2"
    ]

    public var isOfflinePlayable: Bool {
        Self.avkitFriendlyContainers.contains(containerExt.lowercased())
    }
}
