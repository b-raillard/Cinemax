import Foundation
import CinemaxKit
import JellyfinAPI

/// What a card needs to know to start playback: what to open, under what
/// title, and at what second to resume.
struct CardPlayTarget: Sendable, Equatable {
    let itemId: String
    let title: String
    /// `nil` ⇒ play from the beginning.
    let startSeconds: Double?
}

/// Resolves the play target for a poster card.
///
/// **What this resolver deliberately does NOT do**: pick the episode of a
/// series when that information is missing. `getPlaybackInfo` already
/// resolves Series/Season → Episode server-side in CinemaxKit
/// (`resolvePlayableEpisode` — next-up first, else the first episode of the
/// first season), and duplicating that decision would create two authorities
/// that can diverge. It exists only to fetch **the resume position**, plus
/// the episode id when the next-up probe hands one over — in which case the
/// target points at the episode directly, so the offset and the item always
/// describe the same media.
///
/// Deliberately `nonisolated` and parameterized by **scalars**: passing a
/// `BaseItemDto` (non-`Sendable`) into a nonisolated async call from the
/// `@MainActor` would be a region transfer of a value the main actor still
/// holds. The caller extracts the fields on the main actor side.
enum CardPlayTargetResolver {

    static func resolve(
        itemId: String,
        type: BaseItemKind?,
        title: String,
        positionTicks: Int,
        isPlayed: Bool,
        api: any LibraryAPI,
        userId: String
    ) async -> CardPlayTarget {
        guard type == .series else {
            return CardPlayTarget(
                itemId: itemId,
                title: title,
                startSeconds: resumeSeconds(positionTicks: positionTicks, isPlayed: isPlayed)
            )
        }

        // A series card doesn't carry its next-up episode's userData: this is
        // the only case that costs a round-trip. The call is cached client-side
        // for 10s (prefix `nextup-`), so it is most often served locally right
        // after a detail-screen view.
        guard let episode = try? await api.getNextUp(seriesId: itemId, userId: userId),
              let episodeId = episode.id else {
            return CardPlayTarget(itemId: itemId, title: title, startSeconds: nil)
        }

        return CardPlayTarget(
            itemId: episodeId,
            title: episode.name ?? title,
            startSeconds: resumeSeconds(
                positionTicks: episode.userData?.playbackPositionTicks ?? 0,
                isPlayed: episode.userData?.isPlayed ?? false
            )
        )
    }

    /// Same rule as `MediaDetailScreen.resolvedPlayTarget`: a residual position
    /// on a media already marked played does not count as a resume.
    private static func resumeSeconds(positionTicks: Int, isPlayed: Bool) -> Double? {
        guard positionTicks > 0, !isPlayed else { return nil }
        return positionTicks.jellyfinSeconds
    }
}
