import UIKit
import AVKit
import CinemaxKit
import JellyfinAPI

/// Loads the full item metadata for the current playback, extracts its chapter
/// list, downloads each chapter thumbnail in parallel, and publishes the
/// resulting markers to `AVPlayerItem.navigationMarkerGroups` so AVKit's scrubber
/// exposes a chapters bar.
///
/// **tvOS-only marker effect** — `AVNavigationMarkersGroup` ships only on tvOS.
/// On iOS the full-item fetch still runs (so `onSeriesNameResolved` can drive
/// the end-of-series completion overlay) but marker assembly and thumbnail
/// download are skipped.
@MainActor
final class ChapterController {
    private let apiClient: any LibraryAPI
    private let userId: String
    private let imageBuilder: ImageURLBuilder
    private var fetchTask: Task<Void, Never>?

    init(apiClient: any LibraryAPI, userId: String, imageBuilder: ImageURLBuilder) {
        self.apiClient = apiClient
        self.userId = userId
        self.imageBuilder = imageBuilder
    }

    /// - Parameters:
    ///   - itemId: The effective (episode-level) item identifier.
    ///   - playerItem: The live `AVPlayerItem`. Held weakly so episode nav can
    ///     discard it between fetch and apply without a retain cycle.
    ///   - token: Jellyfin access token for authorising chapter-image requests.
    ///     Nil disables thumbnail fetch but titles still render.
    ///   - onSeriesNameResolved: Callback on the main actor once the full item
    ///     is fetched. Carries `seriesName` (nil for movies). The presenter
    ///     uses this to drive the end-of-series completion overlay.
    func fetchAndApply(
        itemId: String,
        playerItem: AVPlayerItem,
        token: String?,
        onSeriesNameResolved: @escaping @MainActor (String?) -> Void
    ) {
        fetchTask?.cancel()
        let client = apiClient
        let uid = userId
        let builder = imageBuilder
        fetchTask = Task { @MainActor [weak self, weak playerItem] in
            guard let fullItem = try? await client.getItem(userId: uid, itemId: itemId) else { return }
            if Task.isCancelled { return }

            onSeriesNameResolved(fullItem.seriesName)

            guard let chapters = fullItem.chapters, chapters.count > 1 else { return }

            #if os(tvOS)
            let images: [Int: Data] = await withTaskGroup(of: (Int, Data?).self) { group in
                for (index, _) in chapters.enumerated() {
                    let url = builder.chapterImageURL(itemId: itemId, imageIndex: index, maxWidth: 480)
                    group.addTask {
                        await Self.loadImage(url: url, token: token).map { (index, $0) } ?? (index, nil)
                    }
                }
                var results: [Int: Data] = [:]
                for await (idx, data) in group {
                    if let data { results[idx] = data }
                }
                return results
            }
            if Task.isCancelled { return }

            guard let self, let playerItem else { return }
            self.applyMarkers(chapters: chapters, images: images, to: playerItem)
            #else
            _ = builder
            _ = token
            _ = playerItem
            _ = self
            #endif
        }
    }

    func teardown() {
        fetchTask?.cancel()
        fetchTask = nil
    }

    // MARK: - Private

    /// Builds `AVTimedMetadataGroup` markers and assigns them to the player
    /// item's navigation markers. tvOS-only; iOS has no chapter scrubber UI.
    private func applyMarkers(
        chapters: [ChapterInfo],
        images: [Int: Data],
        to playerItem: AVPlayerItem
    ) {
        #if os(tvOS)
        var markers: [AVTimedMetadataGroup] = []
        markers.reserveCapacity(chapters.count)

        for (index, chapter) in chapters.enumerated() {
            let startSeconds = Double(chapter.startPositionTicks ?? 0) / 10_000_000
            let startTime = CMTime(seconds: startSeconds, preferredTimescale: 600)
            let range = CMTimeRange(start: startTime, duration: .zero)

            var items: [AVMetadataItem] = []

            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = (chapter.name ?? "Chapter \(index + 1)") as NSString
            titleItem.extendedLanguageTag = "und"
            items.append(titleItem)

            if let data = images[index] {
                let artwork = AVMutableMetadataItem()
                artwork.identifier = .commonIdentifierArtwork
                artwork.value = data as NSData
                artwork.dataType = kCMMetadataBaseDataType_JPEG as String
                artwork.extendedLanguageTag = "und"
                items.append(artwork)
            }

            markers.append(AVTimedMetadataGroup(items: items, timeRange: range))
        }

        let group = AVNavigationMarkersGroup(title: "Chapters", timedNavigationMarkers: markers)
        playerItem.navigationMarkerGroups = [group]
        #endif
    }

    /// Downloads one chapter thumbnail with the Jellyfin access token attached.
    /// Returns `nil` on HTTP error or non-image content.
    nonisolated private static func loadImage(url: URL, token: String?) async -> Data? {
        var request = URLRequest(url: url)
        if let token {
            request.addValue("MediaBrowser Token=\(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return data
    }
}
