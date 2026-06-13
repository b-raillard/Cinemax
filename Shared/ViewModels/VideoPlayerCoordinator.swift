import SwiftUI
import AVKit
import OSLog
import UIKit
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "Playback")

// MARK: - Video Player Coordinator (tvOS)

/// Coordinates playback on tvOS. Fetches the stream URL via the API client,
/// then presents the native AVPlayerViewController via NativeVideoPresenter.
#if os(tvOS)
@MainActor @Observable
final class VideoPlayerCoordinator {
    @ObservationIgnored
    @AppStorage(SettingsKey.render4K) private var render4K: Bool = SettingsKey.Default.render4K
    @ObservationIgnored
    @AppStorage(SettingsKey.autoPlayNextEpisode) private var autoPlayNextEpisode: Bool = SettingsKey.Default.autoPlayNextEpisode
    @ObservationIgnored
    @AppStorage(SettingsKey.forceNativeAVPlayer) private var forceNativeAVPlayer: Bool = SettingsKey.Default.forceNativeAVPlayer

    var localizationManager: LocalizationManager?
    /// Updated each time a playback session ends (player dismissed). MediaDetailScreen
    /// observes this to refresh its content after the user returns from the player.
    var lastDismissedAt: Date?

    /// Retained so the presenter isn't deallocated during playback.
    private var presenter: NativeVideoPresenter?
    /// VLC engine presenter (default online path). Same lifetime contract.
    private var vlcPresenter: VLCStreamPresenter?
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
        vlcPresenter = nil
        let useVLC = !forceNativeAVPlayer
        let engine: VideoPlaybackEngine = useVLC ? .vlc : .native
        currentGeneration &+= 1
        let generation = currentGeneration
        playTask = Task {
            guard let userId = appState.currentUserId else {
                logger.error("VideoPlayerCoordinator: not authenticated")
                return
            }
            do {
                let info = try await apiClient.getPlaybackInfo(itemId: itemId, userId: userId, maxBitrate: bitrate, engine: engine)
                #if DEBUG
                logger.info("tvOS play: engine=\(engine.rawValue), method=\(info.playMethod.rawValue), url=\(redactedURL(info.url))")
                #endif
                if useVLC {
                    let v = VLCStreamPresenter(
                        itemId: itemId, title: title, startTime: startTime,
                        previousEpisode: previousEpisode, nextEpisode: nextEpisode,
                        episodeNavigator: episodeNavigator,
                        apiClient: apiClient, userId: userId,
                        autoPlayNext: autoPlayNextEpisode, maxBitrate: bitrate,
                        imageBuilder: appState.imageBuilder, loc: loc,
                        onDismiss: { [weak self] in
                            guard let self, self.currentGeneration == generation else { return }
                            self.vlcPresenter = nil
                            self.lastDismissedAt = Date()
                        }
                    )
                    guard self.currentGeneration == generation else { return }
                    self.vlcPresenter = v
                    v.present(info: info)
                    return
                }
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
                // Surface the failure to the user. Without this, a thrown
                // getPlaybackInfo (no playable media, server 500, network drop,
                // or a Series/Season that never resolves to an Episode) left the
                // Play button looking dead — the #1 "some videos can't be
                // launched" report on tvOS. tvOS never mounts VideoPlayerView, so
                // there's no SwiftUI error surface here; present a native alert.
                logger.error("tvOS playback error: \(error.localizedDescription)")
                guard self.currentGeneration == generation else { return }
                self.presentPlaybackError(loc.userFacingMessage(for: error))
            }
        }
    }

    /// Presents a native error alert from the top-most view controller. Used by
    /// the play `Task`'s catch — the only user-facing failure surface on tvOS,
    /// where playback is driven by this coordinator rather than `VideoPlayerView`.
    private func presentPlaybackError(_ message: String) {
        guard let loc = localizationManager else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return
        }
        var top: UIViewController = root
        while let presented = top.presentedViewController { top = presented }
        let alert = UIAlertController(
            title: loc.localized("playback.error.title"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: loc.localized("playback.error.close"), style: .default))
        top.present(alert, animated: true)
    }
}
#endif
