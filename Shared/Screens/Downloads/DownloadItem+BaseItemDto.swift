#if os(iOS)
import Foundation
import CinemaxKit
import JellyfinAPI

extension DownloadItem {
    /// Builds a `DownloadItem` for a single movie or episode `BaseItemDto`.
    /// Returns `nil` for kinds that aren't directly playable (series, season,
    /// folders) — those fan out via `episodes(in:)` and enqueue per-episode.
    static func from(item: BaseItemDto, request: DownloadStreamRequest) -> DownloadItem? {
        guard let id = item.id else { return nil }
        let kind: DownloadKind
        switch item.type {
        case .movie: kind = .movie
        case .episode: kind = .episode
        default: return nil
        }
        // We download the *original* file (Jellyfin's /Items/{id}/Download),
        // so the container needs to follow the source. The actual extension on
        // disk is refined post-download from the server's Content-Disposition
        // header — this value is just the initial guess used while the task is
        // still in flight (e.g. for progress UIs that show size estimates).
        let ext = (item.mediaSources?.first?.container?.split(separator: ",").first).map(String.init) ?? "mp4"
        return DownloadItem(
            id: id,
            kind: kind,
            title: item.name ?? "",
            posterTag: item.imageTags?["Primary"],
            seriesId: item.seriesID,
            seriesTitle: item.seriesName,
            seasonId: item.seasonID,
            seasonName: item.seasonName,
            seasonIndex: item.parentIndexNumber,
            episodeIndex: item.indexNumber,
            remoteURL: request.url,
            containerExt: ext,
            runtimeTicks: item.runTimeTicks,
            overview: item.overview,
            productionYear: item.productionYear,
            genres: item.genres ?? [],
            officialRating: item.officialRating,
            communityRating: item.communityRating,
            premiereDate: item.premiereDate,
            backdropItemID: item.backdropItemID
        )
    }
}
#endif
