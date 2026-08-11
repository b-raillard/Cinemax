import SwiftUI
import CinemaxKit
import JellyfinAPI

// MARK: - Episode Navigation

struct EpisodeRef: Sendable {
    let id: String
    let title: String
}

/// Returns the (previous, next) refs around a given episode ID — pure index
/// lookups over the season's ref list, **no network**.
///
/// This deliberately does NOT negotiate `PlaybackInfo`. Each presenter owns
/// that call because the device profile is engine-dependent
/// (`buildVLCDeviceProfile` vs `buildAppleDeviceProfile`, chosen from
/// `forceNativeAVPlayer`), so a negotiation made here could only be right for
/// one of the two engines. It used to happen here with the default (`.native`)
/// profile: the VLC path threw that result away and re-negotiated, paying an
/// extra `getItem` + `POST /Items/{id}/PlaybackInfo` per episode transition on
/// the critical path — and leaking the live stream that negotiation opened
/// (`isAutoOpenLiveStream`), since no stop report ever referenced it.
typealias EpisodeNavigator = @Sendable (String) -> (EpisodeRef?, EpisodeRef?)?

/// Builds prev/next episode refs and a navigator from a flat episode list.
/// Returns `(nil, nil, nil)` when the episode isn't found or the season has only one episode.
///
/// Single-call convenience. When building navigation for many episodes in the
/// same season, prefer `precomputeEpisodeRefs` + the overload below — that
/// path builds the refs array once and does O(1) index lookups per episode
/// instead of a fresh `compactMap` + `firstIndex` on every call.
func buildEpisodeNavigation(
    for episodeId: String,
    in episodes: [BaseItemDto]
) -> (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?) {
    let (refs, indexByID) = precomputeEpisodeRefs(episodes)
    return buildEpisodeNavigation(for: episodeId, refs: refs, indexByID: indexByID)
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
    indexByID: [String: Int]
) -> (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?) {
    guard refs.count > 1, let idx = indexByID[episodeId] else {
        return (nil, nil, nil)
    }
    let prev: EpisodeRef? = idx > 0 ? refs[idx - 1] : nil
    let next: EpisodeRef? = idx < refs.count - 1 ? refs[idx + 1] : nil
    let navigator: EpisodeNavigator = { @Sendable targetId in
        guard let targetIdx = indexByID[targetId] else { return nil }
        let newPrev: EpisodeRef? = targetIdx > 0 ? refs[targetIdx - 1] : nil
        let newNext: EpisodeRef? = targetIdx < refs.count - 1 ? refs[targetIdx + 1] : nil
        return (newPrev, newNext)
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
    /// Pins a specific version of a multi-source item — the user's pick from
    /// the detail screen's version row. `nil` lets `MediaSourceQuality` rank
    /// and choose, which is the default for every other entry point.
    var mediaSourceId: String? = nil
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
                episodeNavigator: episodeNavigator, mediaSourceId: mediaSourceId,
                using: appState
            )
        } label: {
            label()
        }
        #else
        NavigationLink {
            VideoPlayerView(
                itemId: itemId, title: title, startTime: startTime,
                previousEpisode: previousEpisode, nextEpisode: nextEpisode,
                episodeNavigator: episodeNavigator, mediaSourceId: mediaSourceId
            )
        } label: {
            label()
        }
        #endif
    }
}
