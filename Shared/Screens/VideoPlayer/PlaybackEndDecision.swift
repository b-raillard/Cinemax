import Foundation

/// What a `.stopped` engine event means.
///
/// libVLC 4.0 has no distinct `.ended`, so teardown, media swaps, a real
/// end-of-media and an upstream death all arrive as `.stopped`. The presenter
/// used to answer that with a single `guard … else { return }`, which lumped
/// four very different situations into one silent no-op — and one of them is a
/// defect: a stream that dies mid-film produces a clean EOF from libVLC, the
/// near-end test fails, and **nothing** runs. No retry, no stop report, no
/// alert, not even the loading spinner. Measured 95 s of a fully black player
/// that only ended when connectivity was restored by hand.
///
/// Pure and separate from the presenter for the same reason as `SeekCoalescer`:
/// `VLCStreamViewController` is a private class in a 3000-line file and cannot
/// be unit-tested, but this decision can. Locked by `PlaybackEndDecisionTests`.
enum PlaybackEndDecision: Equatable {
    /// Not a real end: teardown, a media swap, or a stream that never opened.
    /// The presenter has other machinery that owns those.
    case ignore
    /// The media genuinely reached its end — run the end-of-playback branch.
    case ended
    /// The media stopped well short of its runtime after having really opened:
    /// the upstream died. Route to the recovery the `.error` path already has.
    case unexpectedStop
}

enum PlaybackEndPolicy {
    /// How close to the runtime counts as "the end". libVLC's last position
    /// sample is not exact, so this cannot be zero.
    static let endToleranceMs: Int64 = 2000

    /// A `.stopped` this soon after play started is a media swap, not an end.
    static let minPlayDuration: TimeInterval = 1.0

    static func decide(
        isTearingDown: Bool,
        secondsSincePlayStart: TimeInterval,
        currentMs: Int64,
        lengthMs: Int64,
        mediaConfirmedOpen: Bool
    ) -> PlaybackEndDecision {
        // Teardown and media swaps are owned elsewhere and must stay silent.
        guard !isTearingDown, secondsSincePlayStart > minPlayDuration else { return .ignore }
        // Without a runtime we cannot call an arrest premature — say nothing
        // rather than guess. This also covers the never-opened case, whose
        // recovery belongs to the open watchdog.
        guard lengthMs > 0 else { return .ignore }
        if currentMs >= lengthMs - endToleranceMs { return .ended }
        // Short of the end on a stream that really opened: the upstream died.
        // `mediaConfirmedOpen` is the same gate the loading spinner uses, and
        // it is what keeps this from double-handling a stream that never
        // produced a demuxer.
        return mediaConfirmedOpen ? .unexpectedStop : .ignore
    }
}
