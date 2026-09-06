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

// MARK: - When a participant may announce it is ready

/// Whether this client may tell the group it is ready **now**.
///
/// `Ready` is not a courtesy ping: Jellyfin reads its `PositionTicks` as "this
/// is where that participant is" and compares it against the group's own
/// position to decide whether everyone else must wait. Announcing a position
/// the engine has not reached does not merely arrive early — it tells the
/// server this session is a straggler, and the server then rebuilds the whole
/// group's clock around that lie.
///
/// Measured on 2026-09-06 against the real server, group queued at 1:36
/// (`position=964460000`):
///
/// ```
/// 18:50:18.801  engine-state opening
/// 18:50:18.934  engine-state playing        ← 133 ms later
/// 18:50:18.935  Ready envoyé position=0
/// 18:50:20.774  seek-settle now=96446 landed=true   ← where we actually were
/// ```
///
/// libVLC reports `.playing` as soon as the input starts, **before the demuxer
/// has reached the position the group asked for** — exactly the fact the
/// `clearLoadingIfOpen` / `noteMediaOpened` RULE already documents for the
/// spinner, applied to the wrong consumer. The server read `0` against its own
/// `964460000`, took `WaitingGroupState`'s "client is recovering" branch and
/// set `LastActivity = now + 96.4 s`. Every command it issued afterwards
/// carried a `When` up to 96 s in the future, and `SyncPlayController.schedule`
/// slept on each one (capped at 30 s) before applying it — so pause, ±10 s and
/// unpause all read as dead buttons, and each new command cancelled the one
/// still waiting. The group's `PositionTicks` also stopped advancing
/// (`Math.Max(elapsed, 0)` clamps a negative elapsed to zero), so the `Pause`
/// that eventually landed dragged the picture from 2:45 back to 1:36.
///
/// All three refusals are load-bearing, and so is the acceptance:
///
///   - **not open** — the playhead is not a playhead yet;
///   - **a start seek still to be emitted** — `mediaConfirmedOpen` is NOT enough
///     on its own, which a first version of this gate got wrong. The presenter
///     issues the resume seek from `onEngineTimeChanged`, once `lengthMs` is
///     known, so "open" precedes "at the right place" and the gap between them
///     is exactly where the playhead reads 0. Measured with that first version
///     in place, group at 7:04: `Ready envoyé position=0` at 19:06:30.748 and
///     again at .810, `seek-fire target=424172 from=0` only at .826;
///   - **a seek still settling** — the position is the pre-seek one, and the
///     settle has its own reporter (`SyncPlayController.reportSeekSettled`),
///     which knows the arrival position;
///   - **open, nothing pending, nothing settling** — somebody must speak, or a
///     group that starts at zero (no resume to emit, so no settle window ever
///     armed) would never leave `Waiting`.
enum SyncPlayReadyPolicy {
    static func shouldAnnounceReady(
        mediaConfirmedOpen: Bool,
        startSeekPending: Bool,
        isSeekSettling: Bool
    ) -> Bool {
        mediaConfirmedOpen && !startSeekPending && !isSeekSettling
    }
}
