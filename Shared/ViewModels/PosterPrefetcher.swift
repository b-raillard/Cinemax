import Foundation
import Nuke

/// Warms Nuke's cache for card images the user is about to scroll to, so
/// posters render instantly instead of popping in (most visible on tvOS,
/// where remote-driven scrolling outruns lazy loading).
///
/// IMPORTANT: prefetched URLs must be byte-identical to what the consuming
/// card requests (same `maxWidth`, same `tag`) — Nuke keys its caches on the
/// URL, so a near-miss warms nothing. Build them with the same
/// `ImageURLBuilder` call the card uses.
///
/// `prefetched` dedupes across calls so re-renders / pagination don't requeue
/// work Nuke has already been asked for; `ImagePrefetcher` itself runs at low
/// priority and yields to on-screen requests.
@MainActor
final class PosterPrefetcher {
    private let prefetcher = ImagePrefetcher(pipeline: ImagePipeline.shared)
    private var prefetched: Set<URL> = []

    /// Queues any not-yet-seen URLs for background prefetch. Nil entries are
    /// dropped so call sites can pass optional-URL maps straight through.
    func prefetch(_ urls: [URL?]) {
        let fresh = urls.compactMap { $0 }.filter { !prefetched.contains($0) }
        guard !fresh.isEmpty else { return }
        prefetched.formUnion(fresh)
        prefetcher.startPrefetching(with: fresh)
    }

    /// Drops the in-flight queue and the dedupe set — call when the data set
    /// is replaced wholesale (catalogue refresh), so stale URLs don't keep
    /// downloading and refreshed tags re-prefetch.
    func reset() {
        prefetcher.stopPrefetching()
        prefetched.removeAll()
    }
}
