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

/// Overload over `EpisodeReference` — the lean (id, title) shape
/// `LibraryAPI.getEpisodeRefs` returns.
///
/// `EpisodeRef` and `EpisodeReference` carry the same two fields and are
/// deliberately not merged: `EpisodeRef` is the app-side navigation currency
/// (it travels into the players alongside an `EpisodeNavigator`), while
/// `EpisodeReference` is what CinemaxKit can return without the app's types.
/// This is the one place the two meet.
func precomputeEpisodeRefs(_ episodes: [EpisodeReference]) -> (refs: [EpisodeRef], indexByID: [String: Int]) {
    var refs: [EpisodeRef] = []
    refs.reserveCapacity(episodes.count)
    var indexByID: [String: Int] = [:]
    indexByID.reserveCapacity(episodes.count)
    for episode in episodes {
        indexByID[episode.id] = refs.count
        refs.append(EpisodeRef(id: episode.id, title: episode.name))
    }
    return (refs, indexByID)
}

// MARK: - Series-wide chain

/// The list a series episode's prev/next walks: every available episode of
/// the SERIES, season after season — never one season's list.
///
/// A navigator built on a single season ends at that season's last episode:
/// no "next" there, so autoplay stopped and the « Vous avez terminé {série} »
/// card came up at the end of EVERY season (reported 2026-11-19).
///
/// - Regular seasons are chained in season-number order, keeping the server's
///   order inside a season (the sort is made stable by the original offset).
/// - Specials (season 0) are a chain of their own: the last special is not
///   followed by S01E01, and S01E01 is not preceded by a special.
/// - An id that is not in `all` yields `[]` — the caller falls back to the
///   season's own list.
func seriesEpisodeChain(containing episodeId: String, in all: [EpisodeReference]) -> [EpisodeReference] {
    guard let target = all.first(where: { $0.id == episodeId }) else { return [] }
    return orderedSeriesChain(all, specials: target.season == 0)
}

/// The episode a series opens on when nothing is « next up » — every episode
/// watched, typically: a rewatch. The first episode of the first regular
/// season (a special only when the series has nothing else).
///
/// The sites that start a SERIES resolve this themselves instead of handing
/// the player the series id: the id plays the same episode (CinemaxKit's
/// `resolvePlayableEpisode`), but with no navigation at all — one episode,
/// then the player closed, on exactly the series one is watching again.
func seriesOpeningEpisode(in all: [EpisodeReference]) -> EpisodeReference? {
    orderedSeriesChain(all, specials: false).first ?? all.first
}

private func orderedSeriesChain(_ all: [EpisodeReference], specials: Bool) -> [EpisodeReference] {
    all.enumerated()
        .filter { ($0.element.season == 0) == specials }
        .sorted { lhs, rhs in
            let left = lhs.element.season ?? .max
            let right = rhs.element.season ?? .max
            return left == right ? lhs.offset < rhs.offset : left < right
        }
        .map(\.element)
}

/// Both chains of a series (regular seasons, specials), precomputed once —
/// for the sites that build navigation for MANY episodes of a series (Home's
/// rails, the fiche). Hand `precomputed(for:)` to `buildEpisodeNavigation`.
struct SeriesEpisodeChains {
    private let regular: (refs: [EpisodeRef], indexByID: [String: Int])
    private let specials: (refs: [EpisodeRef], indexByID: [String: Int])

    init(_ all: [EpisodeReference]) {
        regular = precomputeEpisodeRefs(orderedSeriesChain(all, specials: false))
        specials = precomputeEpisodeRefs(orderedSeriesChain(all, specials: true))
    }

    /// The chain `episodeId` belongs to; `nil` when the list does not know it.
    func precomputed(for episodeId: String) -> (refs: [EpisodeRef], indexByID: [String: Int])? {
        if regular.indexByID[episodeId] != nil { return regular }
        if specials.indexByID[episodeId] != nil { return specials }
        return nil
    }
}

/// The refs to build an episode's navigation from — the SSOT every site that
/// resolves ONE episode goes through (card menus, the library hero). The
/// series-wide chain first; the season's own list when that request fails or
/// does not know the episode, so a hiccup degrades to "navigation stops at
/// the season" rather than to no navigation at all. Empty when both fail.
func episodeNavigationRefs(
    episodeId: String, seriesId: String, seasonId: String?,
    api: any LibraryAPI, userId: String
) async -> [EpisodeReference] {
    if let all = try? await api.getSeriesEpisodeRefs(seriesId: seriesId, userId: userId) {
        let chain = seriesEpisodeChain(containing: episodeId, in: all)
        if !chain.isEmpty { return chain }
    }
    guard let seasonId else { return [] }
    return (try? await api.getEpisodeRefs(seriesId: seriesId, seasonId: seasonId, userId: userId)) ?? []
}

/// Builds prev/next navigation from the lean ref list. Convenience mirror of
/// the `[BaseItemDto]` overload above.
func buildEpisodeNavigation(
    for episodeId: String,
    in episodes: [EpisodeReference]
) -> (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?) {
    let (refs, indexByID) = precomputeEpisodeRefs(episodes)
    return buildEpisodeNavigation(for: episodeId, refs: refs, indexByID: indexByID)
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
    /// Runs ONCE, when playback has really started here — the presenter's
    /// first confirmed open (VLC: the first `noteMediaOpened()`, AVPlayer: the
    /// first `.readyToPlay`), on both platforms. « Reprendre ici » stops the
    /// other device there: a negotiation that fails, a refused item or a close
    /// on « Préparation du flux… » must leave it playing (audit 2026-11-13,
    /// PL-02). Never decides whether something plays.
    var onStart: (@MainActor () -> Void)?
    /// Asked when the player OPENS, in place of `startTime` — « Reprendre ici »
    /// carries a playing source's position forward to that moment. A value
    /// computed when the card was drawn could be ~50 s old.
    var startTimeAtOpen: (@MainActor () -> Double?)?
    @ViewBuilder let label: () -> Label

    #if os(tvOS)
    @Environment(VideoPlayerCoordinator.self) private var coordinator
    @Environment(AppState.self) private var appState
    #endif

    var body: some View {
        #if os(tvOS)
        Button {
            coordinator.play(
                itemId: itemId, title: title, startTime: startTimeAtOpen?() ?? startTime,
                previousEpisode: previousEpisode, nextEpisode: nextEpisode,
                episodeNavigator: episodeNavigator, mediaSourceId: mediaSourceId,
                onPlaybackStarted: onStart,
                using: appState
            )
        } label: {
            label()
        }
        #else
        NavigationLink {
            // The destination VALUE is built with the link; its body only when
            // pushed — where `startTimeAtOpen` is asked, once.
            OpenTimeStart(fallback: startTime, provider: startTimeAtOpen) { start in
                VideoPlayerView(
                    itemId: itemId, title: title, startTime: start,
                    previousEpisode: previousEpisode, nextEpisode: nextEpisode,
                    episodeNavigator: episodeNavigator, mediaSourceId: mediaSourceId,
                    onPlaybackStarted: onStart
                )
            }
        } label: {
            label()
        }
        #endif
    }
}

#if os(iOS)
/// Freezes a start time the first time its body runs — at the push, not when
/// the link was drawn — so a re-render can never move the player's start.
private struct OpenTimeStart<Content: View>: View {
    private final class Box {
        var start: Double??
    }

    let fallback: Double?
    let provider: (@MainActor () -> Double?)?
    @ViewBuilder let content: (Double?) -> Content
    @State private var box = Box()

    var body: some View {
        if box.start == nil {
            box.start = .some(provider?() ?? fallback)
        }
        return content(box.start ?? fallback)
    }
}
#endif
