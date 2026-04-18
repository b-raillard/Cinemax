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
///
/// Single-call convenience. When building navigation for many episodes in the
/// same season, prefer `precomputeEpisodeRefs` + the overload below — that
/// path builds the refs array once and does O(1) index lookups per episode
/// instead of a fresh `compactMap` + `firstIndex` on every call.
func buildEpisodeNavigation(
    for episodeId: String,
    in episodes: [BaseItemDto],
    apiClient: any APIClientProtocol,
    userId: String
) -> (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?) {
    let (refs, indexByID) = precomputeEpisodeRefs(episodes)
    return buildEpisodeNavigation(
        for: episodeId, refs: refs, indexByID: indexByID,
        apiClient: apiClient, userId: userId
    )
}

/// Precomputes the refs array and id→index map for a season. Amortises the
/// per-episode cost of `buildEpisodeNavigation` when used to populate a
/// navigation map for many episodes at once.
func precomputeEpisodeRefs(_ episodes: [BaseItemDto]) -> (refs: [EpisodeRef], indexByID: [String: Int]) {
    var refs: [EpisodeRef] = []
    refs.reserveCapacity(episodes.count)
    var indexByID: [String: Int] = [:]
    indexByID.reserveCapacity(episodes.count)
    for item in episodes {
        guard let id = item.id else { continue }
        indexByID[id] = refs.count
        refs.append(EpisodeRef(id: id, title: item.name ?? ""))
    }
    return (refs, indexByID)
}

/// Overload for precomputed refs. Caller owns the `(refs, indexByID)` pair
/// (built once via `precomputeEpisodeRefs`) and reuses it across episodes in
/// the same season.
func buildEpisodeNavigation(
    for episodeId: String,
    refs: [EpisodeRef],
    indexByID: [String: Int],
    apiClient: any APIClientProtocol,
    userId: String
) -> (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?) {
    guard refs.count > 1, let idx = indexByID[episodeId] else {
        return (nil, nil, nil)
    }
    let prev: EpisodeRef? = idx > 0 ? refs[idx - 1] : nil
    let next: EpisodeRef? = idx < refs.count - 1 ? refs[idx + 1] : nil
    let navigator: EpisodeNavigator = { @Sendable targetId in
        guard let targetIdx = indexByID[targetId] else { return nil }
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
