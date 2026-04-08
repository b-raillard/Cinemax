import SwiftUI
import AVKit
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "Playback")

// MARK: - tvOS UIKit Video Presentation

/// Presents TVPlayerHostViewController via UIKit modal presentation,
/// completely bypassing SwiftUI's view hierarchy. This prevents
/// NavigationSplitView focus corruption on dismiss, and gives us a
/// fully custom transport bar with correct Jellyfin track metadata.
#if os(tvOS)
@MainActor
final class TVVideoPresenter {

    static func present(
        title: String,
        info: PlaybackInfo,
        startTime: Double? = nil,
        previousEpisode: EpisodeRef? = nil,
        nextEpisode: EpisodeRef? = nil,
        episodeNavigator: EpisodeNavigator? = nil,
        localizationManager: LocalizationManager,
        onTrackChange: @escaping (Int?, Int?) async -> URL?
    ) {
        guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let rootVC = windowScene.windows.first?.rootViewController else {
            logger.error("TVVideoPresenter: no root view controller")
            return
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        let playerVC = TVPlayerHostViewController(
            title: title,
            info: info,
            startTime: startTime,
            previousEpisode: previousEpisode,
            nextEpisode: nextEpisode,
            episodeNavigator: episodeNavigator,
            localizationManager: localizationManager,
            onTrackChange: onTrackChange
        )
        topVC.present(playerVC, animated: true)
    }
}
#endif

// MARK: - Video Player Coordinator (tvOS)

/// Coordinates playback on tvOS. Fetches the stream URL via the API client,
/// then hands off to TVVideoPresenter for pure-UIKit modal presentation.
#if os(tvOS)
@MainActor @Observable
final class VideoPlayerCoordinator {
    @ObservationIgnored
    @AppStorage("forceSubtitles") private var forceSubtitles: Bool = false
    @ObservationIgnored
    @AppStorage("render4K") private var render4K: Bool = true

    var localizationManager: LocalizationManager?

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
        Task {
            guard let userId = appState.currentUserId else {
                logger.error("VideoPlayerCoordinator: not authenticated")
                return
            }
            do {
                let info = try await apiClient.getPlaybackInfo(itemId: itemId, userId: userId, maxBitrate: bitrate)
                logger.info("tvOS play: method=\(info.playMethod.rawValue), url=\(info.url.absoluteString)")
                TVVideoPresenter.present(
                    title: title, info: info, startTime: startTime,
                    previousEpisode: previousEpisode, nextEpisode: nextEpisode,
                    episodeNavigator: episodeNavigator,
                    localizationManager: loc
                ) { audioIdx, subtitleIdx in
                    return try? await apiClient.getPlaybackInfo(
                        itemId: itemId, userId: userId, maxBitrate: bitrate,
                        audioStreamIndex: audioIdx, subtitleStreamIndex: subtitleIdx
                    ).url
                }
            } catch {
                logger.error("tvOS playback error: \(error.localizedDescription)")
            }
        }
    }
}
#endif
