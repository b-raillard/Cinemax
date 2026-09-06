import Foundation

/// Where a Watch Together participant opens, and where a creator's queue starts.
///
/// **RULE — in a SyncPlay session the GROUP's position is authoritative, and a
/// group at 0 beats a local resume.** The joiner used to open at its own resume
/// point: `AppNavigation`'s `onQueueChanged = { itemId, _ in … }` discarded the
/// second parameter — which *is* the group's position — so the request routed
/// through `MediaDetailScreen.consumeIntentPlaybackRequest` →
/// `resolvedPlayTarget`, whose `startSeconds` reads the **joining account's**
/// `playbackPositionTicks`. Measured on device 2026-09-06: the group carried
/// 3:39, the joiner opened on the end credits at 12:33, and nothing corrected
/// the 9 min 11 s gap — two people watching different parts of the same film
/// with no signal at all. The joiner then "finished" a film the group had just
/// started, wiping its own server-side resume as a parting gift.
///
/// **The nil-versus-zero distinction is the whole defect**, which is why it has
/// a test of its own. A group starting from the beginning carries position `0`,
/// and `0` must still win: treating it as "no position given" is exactly what
/// let a 12:33 local resume through.
///
/// **Do NOT justify the old behaviour with the "a join inherits the fidelity of
/// a tap (… resume position …)" note in CLAUDE.md.** That sentence describes
/// reused *wiring*, not an arbitration, and its original reasoning — from
/// « Lire sur… », where re-resolving locally *"lands on the same tick for this
/// app's own sender"* — is definitionally false here: the sender is a different
/// account with a different resume. Series → next-up, version pick and prev/next
/// episode navigation are inherited as before; only the start position is
/// overridden, and only when the request came from a group queue.
enum SyncPlayJoinStart {

    private static let ticksPerSecond = 10_000_000.0

    /// The start position a playback request should use, in seconds.
    ///
    /// - Parameters:
    ///   - groupStartTicks: the position carried by the group's `PlayQueue`, in
    ///     Jellyfin ticks. `nil` — and only `nil` — means the request did not
    ///     come from a Watch Together queue.
    ///   - localResumeSeconds: what the fiche's own resolution would use.
    /// - Returns: `nil` to open from the beginning.
    static func startSeconds(groupStartTicks: Int?, localResumeSeconds: Double?) -> Double? {
        guard let ticks = groupStartTicks else { return localResumeSeconds }
        guard ticks > 0 else { return nil }
        return Double(ticks) / ticksPerSecond
    }

    /// The position a newly created group's queue starts at.
    ///
    /// It used to be a hardcoded `0`, on both the queue (`setQueue(…,
    /// startPositionTicks: 0)`) and the creator's own player
    /// (`watchTogetherIntent(…, startTime: nil)`). So opening a session on a
    /// half-watched film restarted it from zero and then **overwrote the host's
    /// resume point server-side** — « 4m restantes » became « 12m restantes »
    /// after a two-minute session. Silent data loss, from an action whose
    /// purpose is not to touch the resume point at all; the Play button one row
    /// above honours it.
    static func queueStartTicks(resumeTicks: Int?) -> Int {
        max(0, resumeTicks ?? 0)
    }
}
