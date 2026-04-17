import SwiftUI
import AVKit
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "Playback")

// MARK: - Video Player Coordinator (tvOS)

/// Coordinates playback on tvOS. Fetches the stream URL via the API client,
/// then presents the native AVPlayerViewController via NativeVideoPresenter.
#if os(tvOS)
@MainActor @Observable
final class VideoPlayerCoordinator {
    @ObservationIgnored
    @AppStorage("forceSubtitles") private var forceSubtitles: Bool = false
    @ObservationIgnored
    @AppStorage("render4K") private var render4K: Bool = true
    @ObservationIgnored
    @AppStorage("autoPlayNextEpisode") private var autoPlayNextEpisode: Bool = true

    var localizationManager: LocalizationManager?
    /// Updated each time a playback session ends (player dismissed). MediaDetailScreen
    /// observes this to refresh its content after the user returns from the player.
    var lastDismissedAt: Date?

    /// Retained so the presenter isn't deallocated during playback.
    private var presenter: NativeVideoPresenter?
    private var playTask: Task<Void, Never>?
    /// Monotonic counter used to identify the current play session. Incremented each
    /// time `play()` starts a new session, so a stale `onDismiss` firing after a
    /// second `play()` (e.g. dismiss delegate arriving late) can't nil out the
    /// replacement presenter.
    private var currentGeneration: UInt = 0

    var maxBitrate: Int { render4K ? 120_000_000 : 20_000_000 }

    func play(
        itemId: String, title: String, startTime: Double? = nil,
        previousEpisode: EpisodeRef? = nil, nextEpisode: EpisodeRef? = nil,
        episodeNavigator: EpisodeNavigator? = nil,
        using appState: AppState
    ) {
        guard let loc = localizationManager else {
            logger.error("VideoPlayerCoordinator: localizationManager not set")
            return
        }
        let bitrate = maxBitrate
        let apiClient = appState.apiClient
        playTask?.cancel()
        // Drop any previous presenter reference before starting a new session, so a
        // stuck presenter (onDismiss never fired — crash, hardware back, edge cases)
        // doesn't linger on the coordinator indefinitely.
        presenter = nil
        currentGeneration &+= 1
        let generation = currentGeneration
        playTask = Task {
            guard let userId = appState.currentUserId else {
                logger.error("VideoPlayerCoordinator: not authenticated")
                return
            }
            do {
                let info = try await apiClient.getPlaybackInfo(itemId: itemId, userId: userId, maxBitrate: bitrate)
                #if DEBUG
                logger.info("tvOS play: method=\(info.playMethod.rawValue), url=\(info.url.absoluteString)")
                #endif
                let p = NativeVideoPresenter(
                    itemId: itemId, title: title, startTime: startTime,
                    previousEpisode: previousEpisode, nextEpisode: nextEpisode,
                    episodeNavigator: episodeNavigator,
                    apiClient: apiClient, userId: userId,
                    maxBitrate: bitrate, loc: loc,
                    autoPlayNextEpisode: autoPlayNextEpisode,
                    imageBuilder: appState.imageBuilder,
                    onDismiss: { [weak self] in
                        guard let self, self.currentGeneration == generation else { return }
                        self.presenter = nil
                        self.lastDismissedAt = Date()
                    }
                )
                guard self.currentGeneration == generation else { return }
                self.presenter = p
                p.present(info: info)
            } catch {
                logger.error("tvOS playback error: \(error.localizedDescription)")
            }
        }
    }
}
#endif
