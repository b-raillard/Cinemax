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
        // **Deliberately NOT a `withTaskGroup`.** A group awaits every remaining
        // child after its body returns, so `group.next()` + `cancelAll()` yields
        // the deadline's *decision* immediately but only *returns* once the probe
        // has actually finished — the deadline was advisory, not enforced. Two
        // unstructured tasks racing onto one single-resume continuation is the
        // shape that actually bounds the wait, and it is the same one
        // `PlaybackLiveActivityController.attach` uses for its enrich deadline.
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<ProbeOutcome, Never>) in
            let race = ProbeRace(continuation)
            // The loser is **not** cancelled, on purpose: `getNextUp` populates
            // its 10s `nextup-` cache only once the response lands, so cancelling
            // threw away exactly what would make the next tap on this card fast —
            // turning a one-off timeout into a repeated one, in the situation
            // where the resume offset is most wanted. It finishes unobserved.
            Task {
                race.resume(await probeNextUp(itemId: itemId, api: api, userId: userId))
            }
            Task {
                try? await Task.sleep(for: probeDeadline)
                race.resume(.timedOut)
            }
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

    /// The resume offset in seconds, or `nil` to play from the beginning.
    ///
    /// Exposed for the same reason as `isResumable`: Home's hero and its
    /// Continue Watching rail each hand a `startTime` to `PlayLink`, and both
    /// used to compute it inline — re-deriving the tick conversion **and dropping
    /// the `!isPlayed` half of the rule**. Harmless while the resume rail only
    /// returns unplayed items, but it meant one card's `PlayLink` and that same
    /// card's menu entry derived the offset from two different expressions of one
    /// rule, which is exactly the drift this type exists to prevent.
    static func resumeSeconds(positionTicks: Int, isPlayed: Bool) -> Double? {
        guard isResumable(positionTicks: positionTicks, isPlayed: isPlayed) else { return nil }
        return positionTicks.jellyfinSeconds
    }

    /// The next-up lookup, as a value. Split out of the race so the racing code
    /// reads as a race and this reads as a fetch.
    private static func probeNextUp(
        itemId: String, api: any LibraryAPI, userId: String
    ) async -> ProbeOutcome {
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
            // No `Task.isCancelled` special-case any more: nothing cancels this
            // probe, so every error reaching here is a genuine failure.
            logger.debug("Card next-up probe failed for series \(itemId, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    /// Guards a continuation so exactly one of the two racers resumes it —
    /// resuming a `CheckedContinuation` twice is a crash, and both racers can
    /// land near-simultaneously on a deadline this short.
    private final class ProbeRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ProbeOutcome, Never>?

        init(_ continuation: CheckedContinuation<ProbeOutcome, Never>) {
            self.continuation = continuation
        }

        /// First caller wins; every later one is a no-op. The continuation is
        /// resumed OUTSIDE the lock so the awaiting task can't be scheduled while
        /// this thread still holds it.
        func resume(_ outcome: ProbeOutcome) {
            let pending: CheckedContinuation<ProbeOutcome, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: outcome)
        }
    }

    /// Only the scalars pulled off the next-up episode inside the probing
    /// task — never the `BaseItemDto` itself, which is not `Sendable`
    /// and cannot cross the task boundary.
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
