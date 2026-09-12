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
    /// Not a real end: teardown, a media swap, or a non-HLS stream that never
    /// opened. The presenter has other machinery that owns those.
    case ignore
    /// The media genuinely reached its end — run the end-of-playback branch.
    case ended
    /// The media stopped well short of its runtime after having really opened:
    /// the upstream died. Route to the recovery the `.error` path already has.
    case unexpectedStop
    /// An HLS stream stopped before it ever produced a demuxer: its manifest
    /// never arrived. An origin HTTP/2 RST on the playlist fetch is the
    /// measured cause, and libVLC has no playlist-level retry, so this stop
    /// is final. It is a clean `.stopped` with no `.encounteredError`, so the
    /// retry used to wait out the whole open watchdog on a frozen 0:00. Route
    /// to the retry now.
    case failedOpen
    /// The same never-opened HLS stop, but inside the media-swap window, where
    /// it could still be the OUTGOING media winding down. Ask again after this
    /// delay, with the engine's state at that moment: a swap has the new media
    /// opening by then, a failed open is still stopped.
    case recheck(after: TimeInterval)
}

enum PlaybackEndPolicy {
    /// How close to the runtime counts as "the end". libVLC's last position
    /// sample is not exact, so this cannot be zero.
    static let endToleranceMs: Int64 = 2000

    /// A `.stopped` this soon after play started is a media swap, not an end.
    static let minPlayDuration: TimeInterval = 1.0

    /// How far past the swap window a `.recheck` lands, so the second reading
    /// is unambiguously outside it and can never schedule a third.
    static let recheckMargin: TimeInterval = 0.25

    /// - Parameters:
    ///   - secondsSincePlayStart: time since the CURRENT media's `play()`, or
    ///     nil while a fresh open is still on its way to `play()`: every stop
    ///     in that gap belongs to the media being replaced.
    ///   - isAdaptiveStream: the media is an HLS playlist (forced transcode).
    ///   - engineStopped: the engine is in a terminal state. Always true for a
    ///     `.stopped` event; a `.recheck` passes the engine's state at that time.
    static func decide(
        isTearingDown: Bool,
        secondsSincePlayStart: TimeInterval?,
        currentMs: Int64,
        lengthMs: Int64,
        mediaConfirmedOpen: Bool,
        isAdaptiveStream: Bool = false,
        engineStopped: Bool = true
    ) -> PlaybackEndDecision {
        // Teardown is owned elsewhere, and an engine that is opening or playing
        // again has not stopped, whatever the event that got us here said.
        guard !isTearingDown, engineStopped else { return .ignore }
        // The new media's play() has not been issued yet: this stop is the
        // outgoing media's. The failed attempt's own trailing `.stopped`, which
        // follows its `.encounteredError` once the retry has begun, lands here
        // and is not handled a second time.
        guard let secondsSincePlayStart else { return .ignore }
        // An HLS stream that never opened has failed for good: libVLC does not
        // retry a manifest. Only the swap window keeps it ambiguous.
        if !mediaConfirmedOpen, isAdaptiveStream {
            if secondsSincePlayStart > minPlayDuration { return .failedOpen }
            return .recheck(after: minPlayDuration - secondsSincePlayStart + recheckMargin)
        }
        // Media swaps must stay silent.
        guard secondsSincePlayStart > minPlayDuration else { return .ignore }
        // Without a runtime we cannot call an arrest premature — say nothing
        // rather than guess. This also covers a non-HLS stream that never
        // opened, whose recovery belongs to the open watchdog.
        guard lengthMs > 0 else { return .ignore }
        if currentMs >= lengthMs - endToleranceMs { return .ended }
        // Short of the end on a stream that really opened: the upstream died.
        // `mediaConfirmedOpen` is the same gate the loading spinner uses, and
        // it is what keeps this from double-handling a stream that never
        // produced a demuxer.
        return mediaConfirmedOpen ? .unexpectedStop : .ignore
    }
}
