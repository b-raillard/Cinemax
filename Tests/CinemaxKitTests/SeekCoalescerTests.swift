import Testing
@testable import Cinemax

/// `SeekCoalescer` is the pure seek-target math behind the player's coalesced
/// ±N skip / chapter-jump logic. Expected values are derived directly from the
/// implementation: relative skips accumulate from the pending target (else the
/// live position) and sum exactly; absolute targets clamp to
/// `[0, lengthMs - endGuardMs]` with `endGuardMs == 250`.
@Suite("SeekCoalescer")
struct SeekCoalescerTests {

    // MARK: - clamp(target:lengthMs:)

    @Test("negative target clamps to zero")
    func clampNegative() {
        #expect(SeekCoalescer.clamp(target: -1, lengthMs: 100_000) == 0)
        #expect(SeekCoalescer.clamp(target: Int32.min, lengthMs: 100_000) == 0)
    }

    @Test("target beyond length clamps to length minus end guard")
    func clampUpperBound() {
        // 100_000 - 250 = 99_750
        #expect(SeekCoalescer.clamp(target: 100_000, lengthMs: 100_000) == 99_750)
        #expect(SeekCoalescer.clamp(target: 999_999, lengthMs: 100_000) == 99_750)
    }

    @Test("target within range is returned unchanged")
    func clampWithinRange() {
        #expect(SeekCoalescer.clamp(target: 50_000, lengthMs: 100_000) == 50_000)
        #expect(SeekCoalescer.clamp(target: 0, lengthMs: 100_000) == 0)
        // exactly on the guarded ceiling
        #expect(SeekCoalescer.clamp(target: 99_750, lengthMs: 100_000) == 99_750)
    }

    @Test("unknown length (<= 0) applies only the lower bound")
    func clampUnknownLength() {
        #expect(SeekCoalescer.clamp(target: 5_000, lengthMs: 0) == 5_000)
        #expect(SeekCoalescer.clamp(target: -5_000, lengthMs: 0) == 0)
        #expect(SeekCoalescer.clamp(target: 5_000, lengthMs: -1) == 5_000)
    }

    @Test("very short media: the end guard never produces a negative ceiling")
    func clampShortMedia() {
        // lengthMs - 250 would be negative → max(0, …) keeps the ceiling at 0
        #expect(SeekCoalescer.clamp(target: 1_000, lengthMs: 100) == 0)
        #expect(SeekCoalescer.clamp(target: 1_000, lengthMs: 250) == 0)
        // one ms above the guard window leaves a 1 ms reachable window
        #expect(SeekCoalescer.clamp(target: 1_000, lengthMs: 251) == 1)
    }

    // MARK: - relativeTarget(deltaSeconds:pendingMs:currentMs:)

    @Test("with no pending target, the base is the live position")
    func relativeFromCurrent() {
        #expect(SeekCoalescer.relativeTarget(deltaSeconds: 15, pendingMs: nil, currentMs: 10_000) == 25_000)
        #expect(SeekCoalescer.relativeTarget(deltaSeconds: -15, pendingMs: nil, currentMs: 10_000) == -5_000)
    }

    @Test("rapid taps accumulate from the pending target and sum exactly")
    func relativeAccumulatesExactly() {
        // Three quick +15s taps from 10s: each builds on the last pending target,
        // so the total is exactly 10s + 3×15s = 55s (a relative seek-by would drift).
        let cur: Int32 = 10_000
        let t1 = SeekCoalescer.relativeTarget(deltaSeconds: 15, pendingMs: nil, currentMs: cur)
        let t2 = SeekCoalescer.relativeTarget(deltaSeconds: 15, pendingMs: t1, currentMs: cur)
        let t3 = SeekCoalescer.relativeTarget(deltaSeconds: 15, pendingMs: t2, currentMs: cur)
        #expect(t1 == 25_000)
        #expect(t2 == 40_000)
        #expect(t3 == 55_000)
    }

    @Test("the relative result is not clamped — clamping is a separate stage")
    func relativeIsUnclamped() {
        // A backward skip past zero stays negative; accumulateSeek clamps next.
        #expect(SeekCoalescer.relativeTarget(deltaSeconds: -30, pendingMs: 10_000, currentMs: 0) == -20_000)
    }

    @Test("Int32 extremes saturate instead of trapping")
    func relativeNoOverflow() {
        // base + delta*1000 is computed in Int, then Int32(clamping:) saturates.
        #expect(SeekCoalescer.relativeTarget(deltaSeconds: 10_000_000, pendingMs: Int32.max, currentMs: 0) == Int32.max)
        #expect(SeekCoalescer.relativeTarget(deltaSeconds: -10_000_000, pendingMs: Int32.min, currentMs: 0) == Int32.min)
    }
}
