import Foundation
import OSLog
import CinemaxKit
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "CardPlayTarget")

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
///
/// **Sibling, not a duplicate, of `MediaDetailScreen.resolvedPlayTarget(for:)`**:
/// the detail screen's resolver additionally owns a version pick (its
/// "Version" row), which a card has no UI for and therefore cannot carry.
/// The two intentionally coexist — don't "unify" them, since doing so would
/// drag `mediaSourceId` onto cards that have no way to choose one.
enum CardPlayTargetResolver {

    /// How long to wait for the next-up probe before falling through to the
    /// series id itself (`getPlaybackInfo` resolves Series → Episode
    /// server-side anyway). The shared client timeout is 30s and this path
    /// has zero on-screen feedback while it waits — same shape as
    /// `PlaybackLiveActivityController.attach`'s `enrichDeadline` race.
    static let seriesProbeDeadline: Duration = .milliseconds(1500)

    static func resolve(
        itemId: String,
        type: BaseItemKind?,
        title: String,
        positionTicks: Int,
        isPlayed: Bool,
        api: any LibraryAPI,
        userId: String,
        probeDeadline: Duration = seriesProbeDeadline
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
        // after a detail-screen view — but from a library grid / Home genre
        // row / search it is cold every time, and the menu offers no loading
        // affordance while this awaits. Race it against `probeDeadline`: on
        // timeout, fall through to the series id with no resume offset —
        // `getPlaybackInfo` resolves the episode server-side regardless, so
        // the only thing lost is the resume position on a slow server.
        let outcome = await withTaskGroup(of: ProbeOutcome.self) { group in
            group.addTask {
                do {
                    guard let episode = try await api.getNextUp(seriesId: itemId, userId: userId),
                          let episodeId = episode.id else {
                        return .noNextUp
                    }
                    return .episode(NextUpProbeResult(
                        episodeId: episodeId,
                        title: episode.name,
                        positionTicks: episode.userData?.playbackPositionTicks ?? 0,
                        isPlayed: episode.userData?.isPlayed ?? false
                    ))
                } catch {
                    // Cancellation is the expected shape of "the deadline won
                    // the race" (see `group.cancelAll()` below) — only log
                    // genuine failures, the timeout itself is logged once.
                    if !Task.isCancelled {
                        logger.debug("Card next-up probe failed for series \(itemId, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                    return .failed
                }
            }
            group.addTask {
                try? await Task.sleep(for: probeDeadline)
                return .timedOut
            }
            // First task to finish wins; the other is cancelled and its
            // (discarded) result still gets joined by the group's implicit
            // structured-concurrency teardown.
            let first = await group.next() ?? .failed
            group.cancelAll()
            return first
        }

        switch outcome {
        case .episode(let result):
            return CardPlayTarget(
                itemId: result.episodeId,
                title: result.title ?? title,
                startSeconds: resumeSeconds(positionTicks: result.positionTicks, isPlayed: result.isPlayed)
            )
        case .noNextUp, .failed:
            return CardPlayTarget(itemId: itemId, title: title, startSeconds: nil)
        case .timedOut:
            logger.debug("Card next-up probe timed out for series \(itemId, privacy: .public) — falling back to the series id")
            return CardPlayTarget(itemId: itemId, title: title, startSeconds: nil)
        }
    }

    /// Whether a stored position counts as a resume point.
    ///
    /// Same rule as `MediaDetailScreen.resolvedPlayTarget`: a residual position
    /// on a media already marked played does not count. Exposed rather than
    /// kept private because the context menu needs the *predicate* — to decide
    /// whether to label its entry "Resume" and offer "Play from beginning" —
    /// while the resolver needs the *offset*. Two expressions of one business
    /// rule would drift the first time it gains a condition.
    static func isResumable(positionTicks: Int, isPlayed: Bool) -> Bool {
        positionTicks > 0 && !isPlayed
    }

    private static func resumeSeconds(positionTicks: Int, isPlayed: Bool) -> Double? {
        guard isResumable(positionTicks: positionTicks, isPlayed: isPlayed) else { return nil }
        return positionTicks.jellyfinSeconds
    }

    /// Only the scalars pulled off the next-up episode inside the probing
    /// child task — never the `BaseItemDto` itself, which is not `Sendable`
    /// and cannot cross the `TaskGroup` boundary.
    private struct NextUpProbeResult: Sendable {
        let episodeId: String
        let title: String?
        let positionTicks: Int
        let isPlayed: Bool
    }

    private enum ProbeOutcome: Sendable {
        case episode(NextUpProbeResult)
        case noNextUp
        case failed
        case timedOut
    }
}
