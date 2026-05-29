import Testing
import Foundation
@testable import Cinemax

/// Regression coverage for `NativeVideoPresenter.safeResumeSeconds`, the guard
/// added so a corrupt/stale resume position can't crash AVPlayer (non-finite
/// `CMTime`) or seek past the end of a re-transcoded, shorter item.
@Suite("Resume seek clamping")
struct VideoResumeSeekTests {

    @Test("normal position within duration is unchanged")
    func normalPosition() {
        #expect(NativeVideoPresenter.safeResumeSeconds(100, duration: 1000) == 100)
    }

    @Test("position past the end clamps to just before the end")
    func pastEndClamps() {
        #expect(NativeVideoPresenter.safeResumeSeconds(1500, duration: 1000) == 999)
    }

    @Test("zero and negative positions return nil (nothing to resume)")
    func nonPositiveReturnsNil() {
        #expect(NativeVideoPresenter.safeResumeSeconds(0, duration: 1000) == nil)
        #expect(NativeVideoPresenter.safeResumeSeconds(-5, duration: 1000) == nil)
    }

    @Test("non-finite positions return nil (would make an invalid CMTime)")
    func nonFiniteReturnsNil() {
        #expect(NativeVideoPresenter.safeResumeSeconds(.nan, duration: 1000) == nil)
        #expect(NativeVideoPresenter.safeResumeSeconds(.infinity, duration: 1000) == nil)
    }

    @Test("unknown/non-finite duration falls back to the raw position")
    func unknownDurationKeepsPosition() {
        #expect(NativeVideoPresenter.safeResumeSeconds(120, duration: .nan) == 120)
        #expect(NativeVideoPresenter.safeResumeSeconds(120, duration: 0) == 120)
    }
}
