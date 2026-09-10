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
    private let loc: LocalizationManager
    private var fetchTask: Task<Void, Never>?
    /// The thumbnail-download + marker-assembly phase, parked until playback is
    /// actually running. See `fetchAndApply` for why, and
    /// `startDeferredMarkers()` for who releases it.
    private var pendingMarkers: (@MainActor () -> Void)?

    /// Concurrent chapter-image downloads. Matches every other fan-out in the
    /// app (Home's genre rows, the library's) — a 40-chapter film otherwise put
    /// 40 simultaneous authenticated GETs against a self-hosted server.
    private static let thumbnailConcurrency = 6

    init(apiClient: any LibraryAPI, userId: String, imageBuilder: ImageURLBuilder, loc: LocalizationManager) {
        self.apiClient = apiClient
        self.userId = userId
        self.imageBuilder = imageBuilder
        self.loc = loc
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
    ///
    /// The item fetch and `onSeriesNameResolved` run straight away — the
    /// end-of-series overlay depends on that name. The THUMBNAILS are parked
    /// until `startDeferredMarkers()`, the same lesson `VLCStreamPresenter`
    /// learned with `pendingChapterThumbnails`: this runs while AVKit is opening
    /// the stream, so firing one image GET per chapter here put up to ~40
    /// requests against the origin inside the window the user is waiting
    /// through for the first frame. Nothing is lost by waiting: the markers are
    /// assigned in one pass either way (AVKit is handed `navigationMarkerGroups`
    /// once), so today's bar doesn't appear until every image has landed
    /// regardless.
    func fetchAndApply(
        itemId: String,
        playerItem: AVPlayerItem,
        token: String?,
        onSeriesNameResolved: @escaping @MainActor (String?) -> Void
    ) {
        fetchTask?.cancel()
        pendingMarkers = nil
        let client = apiClient
        let uid = userId
        let builder = imageBuilder
        fetchTask = Task { @MainActor [weak self, weak playerItem] in
            guard let fullItem = try? await client.getItem(userId: uid, itemId: itemId) else { return }
            if Task.isCancelled { return }

            onSeriesNameResolved(fullItem.seriesName)

            guard let chapters = fullItem.chapters, chapters.count > 1 else { return }

            #if os(tvOS)
            guard let self else { return }
            self.pendingMarkers = { [weak self, weak playerItem] in
                guard let self else { return }
                self.fetchTask = Task { @MainActor [weak self, weak playerItem] in
                    let images = await Self.loadThumbnails(
                        chapters: chapters, itemId: itemId, builder: builder, token: token
                    )
                    if Task.isCancelled { return }
                    guard let self, let playerItem else { return }
                    self.applyMarkers(chapters: chapters, images: images, to: playerItem)
                }
            }
            #else
            _ = builder
            _ = token
            _ = playerItem
            _ = self
            #endif
        }
    }

    /// Releases the parked thumbnail phase. Called by the presenter once
    /// playback is genuinely running, so the image GETs don't compete with the
    /// stream's own opening. One-shot: the closure is dropped as it fires, so
    /// the presenter can call this from its existing 1 s tick without guarding.
    func startDeferredMarkers() {
        guard let start = pendingMarkers else { return }
        pendingMarkers = nil
        start()
    }

    func teardown() {
        fetchTask?.cancel()
        fetchTask = nil
        pendingMarkers = nil
    }

    /// Downloads the chapter thumbnails, `thumbnailConcurrency` at a time.
    /// A chapter the server has no image for is skipped outright — its marker
    /// keeps the title-only form (mirrors `VLCStreamPresenter`'s strip).
    private static func loadThumbnails(
        chapters: [ChapterInfo],
        itemId: String,
        builder: ImageURLBuilder,
        token: String?
    ) async -> [Int: Data] {
        let requests: [(index: Int, url: URL)] = chapters.enumerated().compactMap { index, chapter in
            guard let tag = chapter.imageTag, !tag.isEmpty else { return nil }
            return (index, builder.chapterImageURL(itemId: itemId, imageIndex: index, tag: tag, maxWidth: 480))
        }
        var results: [Int: Data] = [:]
        for chunk in stride(from: 0, to: requests.count, by: thumbnailConcurrency).map({
            Array(requests[$0..<min($0 + thumbnailConcurrency, requests.count)])
        }) {
            let loaded = await withTaskGroup(of: (Int, Data?).self) { group in
                for request in chunk {
                    group.addTask {
                        await Self.loadImage(url: request.url, token: token).map { (request.index, $0) }
                            ?? (request.index, nil)
                    }
                }
                var partial: [Int: Data] = [:]
                for await (idx, data) in group {
                    if let data { partial[idx] = data }
                }
                return partial
            }
            if Task.isCancelled { return results }
            results.merge(loaded) { _, new in new }
        }
        return results
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
            titleItem.value = (chapter.name ?? "\(loc.localized("player.chapter")) \(index + 1)") as NSString
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

        let group = AVNavigationMarkersGroup(title: loc.localized("player.chapters"), timedNavigationMarkers: markers)
        playerItem.navigationMarkerGroups = [group]
        #endif
    }

    /// Downloads one chapter thumbnail with the Jellyfin access token attached.
    /// Returns `nil` on HTTP error or non-image content (the pipeline fails
    /// non-2xx and empty responses for us — see `AuthenticatedImageFetch`).
    nonisolated private static func loadImage(url: URL, token: String?) async -> Data? {
        await AuthenticatedImageFetch.data(from: url, token: token)
    }
}
