import SwiftUI
import CinemaxKit
import JellyfinAPI

// MARK: - Episode Navigation

struct EpisodeRef: Sendable {
    let id: String
    let title: String
}

/// Returns (new PlaybackInfo, new previousEpisode, new nextEpisode) for a given episode ID.
typealias EpisodeNavigator = @Sendable (String) async -> (PlaybackInfo, EpisodeRef?, EpisodeRef?)?

/// Builds prev/next episode refs and a navigator from a flat episode list.
/// Returns `(nil, nil, nil)` when the episode isn't found or the season has only one episode.
func buildEpisodeNavigation(
    for episodeId: String,
    in episodes: [BaseItemDto],
    apiClient: any APIClientProtocol,
    userId: String
) -> (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?) {
    let refs: [EpisodeRef] = episodes.compactMap {
        guard let id = $0.id else { return nil }
        return EpisodeRef(id: id, title: $0.name ?? "")
    }
    guard refs.count > 1, let idx = refs.firstIndex(where: { $0.id == episodeId }) else {
        return (nil, nil, nil)
    }
    let prev: EpisodeRef? = idx > 0 ? refs[idx - 1] : nil
    let next: EpisodeRef? = idx < refs.count - 1 ? refs[idx + 1] : nil
    let navigator: EpisodeNavigator = { @Sendable targetId in
        guard let targetIdx = refs.firstIndex(where: { $0.id == targetId }) else { return nil }
        guard let info = try? await apiClient.getPlaybackInfo(itemId: refs[targetIdx].id, userId: userId) else { return nil }
        let newPrev: EpisodeRef? = targetIdx > 0 ? refs[targetIdx - 1] : nil
        let newNext: EpisodeRef? = targetIdx < refs.count - 1 ? refs[targetIdx + 1] : nil
        return (info, newPrev, newNext)
    }
    return (prev, next, navigator)
}

// MARK: - Cross-platform Play Link

/// On tvOS, uses VideoPlayerCoordinator for UIKit-based modal presentation.
/// On iOS, uses a standard NavigationLink push.
struct PlayLink<Label: View>: View {
    let itemId: String
    let title: String
    var startTime: Double? = nil
    var previousEpisode: EpisodeRef? = nil
    var nextEpisode: EpisodeRef? = nil
    var episodeNavigator: EpisodeNavigator? = nil
    @ViewBuilder let label: () -> Label

    #if os(tvOS)
    @Environment(VideoPlayerCoordinator.self) private var coordinator
    @Environment(AppState.self) private var appState
    #endif

    var body: some View {
        #if os(tvOS)
        Button {
            coordinator.play(
                itemId: itemId, title: title, startTime: startTime,
                previousEpisode: previousEpisode, nextEpisode: nextEpisode,
                episodeNavigator: episodeNavigator, using: appState
            )
        } label: {
            label()
        }
        #else
        NavigationLink {
            VideoPlayerView(
                itemId: itemId, title: title, startTime: startTime,
                previousEpisode: previousEpisode, nextEpisode: nextEpisode,
                episodeNavigator: episodeNavigator
            )
        } label: {
            label()
        }
        #endif
    }
}
