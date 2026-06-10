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
            remoteURL: sanitizedRemoteURL(request.url),
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

    /// Jellyfin's negotiated download URLs can embed `api_key=<token>` as a
    /// query param (transcoding URLs do). `remoteURL` is persisted in plain
    /// JSON (`index.json`) and never re-used to launch a task — `startTask`
    /// always re-negotiates a fresh PlaybackInfo and auth travels in the
    /// `Authorization` header — so strip credentials before they hit disk.
    ///
    /// KEEP THE PREDICATE IN SYNC with `redactedURL` (CinemaxKit,
    /// JellyfinAPIClient.swift) — a new secret query param added to one but
    /// not the other means clean logs while the token leaks to disk.
    private static func sanitizedRemoteURL(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems, !items.isEmpty else { return url }
        let filtered = items.filter {
            let name = $0.name.lowercased()
            return name != "api_key" && name != "apikey" && !name.contains("token")
        }
        guard filtered.count != items.count else { return url }
        comps.queryItems = filtered.isEmpty ? nil : filtered
        return comps.url ?? url
    }
}
#endif
