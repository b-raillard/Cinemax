import UIKit
import OSLog
import CinemaxKit
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "Trickplay")

/// Scrub-preview thumbnails from Jellyfin's trickplay tiles (server-generated
/// JPEG grids, available when the "Trickplay image extraction" scheduled task
/// has run). The manifest arrives on the full `BaseItemDto` (same fetch the
/// chapter strip already does); this controller resolves a playback position
/// to (tile index, crop rect), fetches + caches tile sheets, and hands back a
/// cropped `UIImage` for the preview bubble. Everything degrades to nil when
/// the server has no trickplay for the item — callers simply don't show a
/// preview image.
@MainActor
final class TrickplayController {
    private struct Manifest {
        let width: Int          // thumbnail width in px (the resolution key)
        let height: Int
        let tileWidth: Int      // thumbnails per row in a tile sheet
        let tileHeight: Int     // thumbnails per column
        let intervalMs: Int
        let thumbnailCount: Int
        let mediaSourceId: String?
    }

    private var manifest: Manifest?
    private var itemId: String?
    private var token: String?
    private var imageBuilder: ImageURLBuilder?

    /// Decoded tile sheets by tile index. A sheet is ~320×180×(10×10) ≈ small
    /// JPEG; cap the cache so a long scrub through a 3h movie can't balloon.
    private let tileCache = NSCache<NSNumber, UIImage>()
    private var inflightTiles: Set<Int> = []
    private var fetchTasks: [Task<Void, Never>] = []
    /// Bumped on every (re)configure so stale fetch completions self-discard.
    private var generation = 0

    /// Fired when a tile a preview asked for finishes loading — the caller
    /// re-requests the thumbnail for its current scrub position.
    var onTileLoaded: (() -> Void)?

    init() {
        tileCache.totalCostLimit = 64 * 1024 * 1024
    }

    var isAvailable: Bool { manifest != nil }

    /// Thumbnail aspect ratio (width/height) for sizing the preview bubble.
    var aspectRatio: CGFloat {
        guard let m = manifest, m.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(m.width) / CGFloat(m.height)
    }

    /// Picks the manifest closest to ~320px wide (the preview bubble size) —
    /// servers can generate several resolutions.
    func configure(item: BaseItemDto, itemId: String, mediaSourceId: String?, token: String?, imageBuilder: ImageURLBuilder?) {
        reset()
        self.itemId = itemId
        self.token = token
        self.imageBuilder = imageBuilder
        guard let trickplay = item.trickplay, !trickplay.isEmpty else { return }
        // Prefer the entry for the playing media source; else any source.
        let perWidth = (mediaSourceId.flatMap { trickplay[$0] }) ?? trickplay.values.first ?? [:]
        let best = perWidth.values
            .compactMap { dto -> Manifest? in
                guard let w = dto.width, let h = dto.height,
                      let tw = dto.tileWidth, let th = dto.tileHeight,
                      let interval = dto.interval, interval > 0,
                      let count = dto.thumbnailCount, count > 0 else { return nil }
                return Manifest(width: w, height: h, tileWidth: tw, tileHeight: th,
                                intervalMs: interval, thumbnailCount: count,
                                mediaSourceId: mediaSourceId)
            }
            .min { abs($0.width - 320) < abs($1.width - 320) }
        manifest = best
        if let best {
            logger.debug("Trickplay available: \(best.width)x\(best.height) every \(best.intervalMs)ms, \(best.thumbnailCount) thumbs")
        }
    }

    func reset() {
        generation += 1
        manifest = nil
        itemId = nil
        fetchTasks.forEach { $0.cancel() }
        fetchTasks = []
        inflightTiles = []
        tileCache.removeAllObjects()
    }

    /// Cropped preview for a playback position. Returns nil when trickplay is
    /// unavailable or the tile sheet isn't cached yet — in the latter case the
    /// fetch is kicked off and `onTileLoaded` fires when it lands.
    func thumbnail(atMs ms: Int32) -> UIImage? {
        guard let m = manifest else { return nil }
        let thumbIndex = min(max(0, Int(ms) / m.intervalMs), m.thumbnailCount - 1)
        let perTile = m.tileWidth * m.tileHeight
        guard perTile > 0 else { return nil }
        let tileIndex = thumbIndex / perTile
        guard let sheet = tileCache.object(forKey: NSNumber(value: tileIndex)) else {
            fetchTile(tileIndex)
            // Prefetch the neighbor in the scrub direction's likely path.
            fetchTile(tileIndex + 1)
            return nil
        }
        let pos = thumbIndex % perTile
        let col = pos % m.tileWidth
        let row = pos / m.tileWidth
        // Crop in the sheet's pixel space (UIImage scale is 1 for raw JPEG data).
        let rect = CGRect(x: col * m.width, y: row * m.height, width: m.width, height: m.height)
        guard let cg = sheet.cgImage?.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Estimates the decoded byte size of a tile sheet image for cache cost.
    private func estimatedDecodedBytes(for image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        // Fallback: estimate as RGBA (4 bytes per pixel)
        return Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    private func fetchTile(_ index: Int) {
        guard let m = manifest, let itemId, let imageBuilder, index >= 0 else { return }
        let perTile = m.tileWidth * m.tileHeight
        let maxTile = (m.thumbnailCount - 1) / max(perTile, 1)
        guard index <= maxTile,
              !inflightTiles.contains(index),
              tileCache.object(forKey: NSNumber(value: index)) == nil else { return }
        inflightTiles.insert(index)
        let url = imageBuilder.trickplayTileURL(itemId: itemId, width: m.width, index: index, mediaSourceId: m.mediaSourceId)
        let token = token
        let gen = generation
        let task = Task { @MainActor [weak self] in
            let data = await Self.loadTile(url: url, token: token)
            guard let self, self.generation == gen else { return }
            self.inflightTiles.remove(index)
            guard let data, let image = UIImage(data: data) else { return }
            let cost = self.estimatedDecodedBytes(for: image)
            self.tileCache.setObject(image, forKey: NSNumber(value: index), cost: cost)
            self.onTileLoaded?()
        }
        fetchTasks.append(task)
    }

    /// Same dual-auth pattern as the chapter thumbnails: `api_key` query param
    /// (what image endpoints accept) plus the Authorization header.
    nonisolated private static func loadTile(url: URL, token: String?) async -> Data? {
        let authed = VLCStreamPresenter.authedURL(url, token: token)
        return await AuthenticatedImageFetch.data(from: authed, token: token)
    }
}
