import UIKit
import MediaPlayer
import CinemaxKit

/// Publishes the current playback metadata to `MPNowPlayingInfoCenter` so the
/// iOS Apple TV Remote widget (Lock Screen / Control Center) — which polls the
/// tvOS device's Now Playing info center — shows the title, season/episode,
/// duration, elapsed time, playback rate, and poster artwork. Sibling of
/// `RemoteCommandController`: that one wires the buttons, this one supplies
/// the metadata the buttons sit on top of.
///
/// Same sub-controller pattern as `PlaybackReporter` / `SleepTimerController`:
/// presenter retains one instance per session, calls `attach` on play /
/// episode-nav, `update` from the existing 1 s tick + on play/pause
/// transitions, `detach` on cleanup.
///
/// Optional dependencies (`apiClient`, `userId`, `imageBuilder`, `authToken`):
/// when nil, item enrichment and artwork fetch are skipped (title + elapsed
/// still publish), no crash.
@MainActor
final class NowPlayingInfoController {
    private let apiClient: (any LibraryAPI)?
    private let userId: String?
    private let imageBuilder: ImageURLBuilder?
    private var authToken: String?

    /// Race guard. Bumped in `attach` and `detach` *before* spawning enrichment /
    /// artwork tasks; each task re-reads `generation` at the moment of writeback
    /// so a slow artwork that arrives after an episode-swap is ignored.
    private var generation: Int = 0
    private var enrichTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?

    init(apiClient: (any LibraryAPI)?, userId: String?, imageBuilder: ImageURLBuilder?, authToken: String?) {
        self.apiClient = apiClient
        self.userId = userId
        self.imageBuilder = imageBuilder
        self.authToken = authToken
    }

    /// Native player path: token isn't known at presenter `init` time (lives on
    /// `PlaybackInfo`, fetched later). Set immediately before `attach`.
    func setAuthToken(_ token: String?) {
        self.authToken = token
    }

    /// Publish the placeholder metadata (title + duration if known + elapsed=0 +
    /// rate=1.0) so the widget gets something to display within ~1 s, then kick
    /// off the item-detail fetch (series name + S×E×) and the artwork fetch.
    func attach(itemId: String, title: String, durationSeconds: Double?) {
        detach()
        generation += 1
        let gen = generation

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        if let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        startEnrichment(itemId: itemId, fallbackTitle: title, generation: gen)
        startArtworkFetch(itemId: itemId, generation: gen)
    }

    /// Cheap per-tick update: mutates elapsed, duration (if it has just become
    /// known), and rate on the existing dict. Called every second by the
    /// presenter's existing time observer + on every play/pause state change.
    /// No-ops when no session is attached, so a leftover tick firing between
    /// `detach` and the next `attach` can't publish a zombie dict with no
    /// title / artwork.
    func update(elapsed: Double, duration: Double?, rate: Double) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed)
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        if let duration, duration.isFinite, duration > 0,
           info[MPMediaItemPropertyPlaybackDuration] as? Double != duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Clears the now-playing dict and cancels any in-flight enrichment /
    /// artwork tasks. Idempotent.
    func detach() {
        generation += 1
        enrichTask?.cancel()
        enrichTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Private

    private func startEnrichment(itemId: String, fallbackTitle: String, generation gen: Int) {
        guard let apiClient, let userId else { return }
        enrichTask = Task { @MainActor [weak self] in
            guard let fullItem = try? await apiClient.getItem(userId: userId, itemId: itemId) else { return }
            guard let self, self.generation == gen, !Task.isCancelled else { return }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            if let name = fullItem.name, !name.isEmpty {
                info[MPMediaItemPropertyTitle] = name
            } else {
                info[MPMediaItemPropertyTitle] = fallbackTitle
            }
            if let seriesName = fullItem.seriesName, !seriesName.isEmpty {
                info[MPMediaItemPropertyAlbumTitle] = seriesName
            }
            if let season = fullItem.parentIndexNumber, let episode = fullItem.indexNumber {
                info[MPMediaItemPropertyArtist] = "S\(season)E\(episode)"
            }
            if let ticks = fullItem.runTimeTicks {
                let dur = Double(ticks) / 10_000_000
                if dur > 0 {
                    info[MPMediaItemPropertyPlaybackDuration] = dur
                }
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    private func startArtworkFetch(itemId: String, generation gen: Int) {
        guard let imageBuilder else { return }
        let url = imageBuilder.imageURL(itemId: itemId, imageType: .primary, maxWidth: 600)
        let token = authToken
        artworkTask = Task { @MainActor [weak self] in
            var req = URLRequest(url: url)
            if let token, !token.isEmpty {
                req.addValue("MediaBrowser Token=\(token)", forHTTPHeaderField: "Authorization")
            }
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = UIImage(data: data) else { return }
            guard let self, self.generation == gen, !Task.isCancelled else { return }
            // **Sendable closure**: MediaPlayer invokes the request handler on a
            // background queue. Without explicit `@Sendable` the trailing closure
            // inherits the enclosing `@MainActor` Task's isolation and traps on
            // tvOS 26 with `dispatch_assert_queue` ("Block was expected to
            // execute on queue …"). Capture the image by value to keep the
            // closure self-contained.
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable [image] _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
