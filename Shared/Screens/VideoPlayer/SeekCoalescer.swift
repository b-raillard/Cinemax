import Foundation

/// Pure seek-target math for the VLC player's *coalesced* ±N skip / chapter-jump
/// logic, extracted from `VLCStreamViewController` so the clamping and
/// relative-accumulation rules are unit-testable without a live player.
///
/// The view controller still owns the debounce timer, the `pendingScrubTargetMs`
/// storage, the HUD repaint, and the engine seek — this type only answers
/// "given the current state, what absolute millisecond target should the pending
/// seek hold?".
///
/// Why this exists (see `VLCStreamViewController` MARK "Coalesced seeking"): a ±N
/// skip used to fire an immediate *relative* `player.seek(by:)` on every press,
/// and over HTTP each seek makes libVLC tear down + reopen its byte-range request
/// — so mashing the button storms a self-hosted / reverse-proxied origin into a
/// stall. Instead we accumulate an ABSOLUTE target and commit one engine seek a
/// beat after the last press. Accumulating absolutely also makes the math exact:
/// a relative `seek(by:)` raced libVLC's lagging position, so rapid taps never
/// reliably summed to N×.
enum SeekCoalescer {
    /// Near-end guard: never seek to within this many ms of the reported length.
    /// libVLC treats a seek to the very end as end-of-media, so we keep headroom.
    static let endGuardMs: Int32 = 250

    /// Clamp an absolute target into the valid range `[0, lengthMs - endGuardMs]`.
    /// `lengthMs <= 0` means "length not known yet" → only the lower bound applies.
    static func clamp(target: Int32, lengthMs: Int32) -> Int32 {
        var clamped = max(0, target)
        if lengthMs > 0 { clamped = min(clamped, max(0, lengthMs - endGuardMs)) }
        return clamped
    }

    /// Resolve the (unclamped) absolute target for a relative ±`deltaSeconds`
    /// skip. The base is the *pending* coalesced target when a skip is already in
    /// flight — so rapid taps sum exactly — else the live position. Arithmetic is
    /// done in `Int` and saturated back into `Int32` so extreme inputs can't trap.
    static func relativeTarget(deltaSeconds: Int, pendingMs: Int32?, currentMs: Int32) -> Int32 {
        let base = Int(pendingMs ?? currentMs)
        return Int32(clamping: base + deltaSeconds * 1000)
    }
}

/// Decides whether the playhead has really started moving again after a seek.
///
/// **The baseline only advances once progress is confirmed**, which is what
/// makes the test independent of how often it is sampled. The previous version
/// rewrote it on every call, and `onEngineTimeChanged` follows libVLC's time
/// updates (several per 100 ms) — so each comparison spanned 0–30 ms, never the
/// 120 ms threshold, and a seek that had *already* resumed at full speed was
/// never recognised as landed. Measured on device 2026-08-12: playback back at
/// 1× within 0.5 s of the seek, spinner held to the backstop at 20.2 s and
/// 30.0 s, HUD pinned to the scrub target throughout — which reads as "the
/// player froze after a fast-forward". Locked by `SeekSettleTrackerTests`.
struct SeekSettleTracker {
    private var baselineMs: Int32?

    /// Reports whether the playhead has advanced at least `thresholdMs` since
    /// the last confirmed baseline.
    mutating func noteProgress(positionMs: Int32, thresholdMs: Int32) -> Bool {
        guard let baseline = baselineMs else {
            baselineMs = positionMs
            return false
        }
        // A backward jump is a fresh seek, not progress: re-baseline on it.
        guard positionMs >= baseline else {
            baselineMs = positionMs
            return false
        }
        guard Int(positionMs) - Int(baseline) >= Int(thresholdMs) else {
            return false // keep the baseline so small samples accumulate
        }
        baselineMs = positionMs
        return true
    }

    mutating func reset() {
        baselineMs = nil
    }
}
