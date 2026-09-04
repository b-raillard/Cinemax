import Testing
import Foundation
@testable import Cinemax

/// Locks the rule a poster card's watched check / progress bar reads.
///
/// The card's chrome is the only place a user sees this rule applied at a
/// glance, and it must agree with the play menu on the same card — hence the
/// shared `CardPlayTargetResolver.isResumable` underneath, and hence the
/// "played wins over a residual position" cases below.
@Suite("MediaCardStatus")
struct MediaCardStatusTests {

    private let hour = 36_000_000_000  // one hour in Jellyfin ticks

    @Test("an untouched item shows nothing")
    func untouched() {
        #expect(MediaCardStatus.make(positionTicks: 0, runtimeTicks: hour, isPlayed: false) == .none)
    }

    @Test("absent userData shows nothing rather than defaulting to watched")
    func absentUserData() {
        #expect(MediaCardStatus.make(positionTicks: nil, runtimeTicks: hour, isPlayed: nil) == .none)
    }

    @Test("a played item shows the check")
    func played() {
        #expect(MediaCardStatus.make(positionTicks: 0, runtimeTicks: hour, isPlayed: true) == .watched)
    }

    @Test("a part-watched item shows its progress")
    func inProgress() {
        let status = MediaCardStatus.make(positionTicks: hour / 4, runtimeTicks: hour, isPlayed: false)
        #expect(status == .inProgress(0.25))
    }

    /// The rule `CardPlayTargetResolver.isResumable` owns: a residual position
    /// on an item already marked played is not a resume. The card must not
    /// contradict the menu on the very same poster.
    @Test("a residual position on a played item is the check, never a bar")
    func residualPositionOnPlayedItem() {
        #expect(MediaCardStatus.make(positionTicks: hour / 2, runtimeTicks: hour, isPlayed: true) == .watched)
    }

    @Test("a sliver below one percent reads as untouched, not as a rendering artefact")
    func belowThreshold() {
        #expect(MediaCardStatus.make(positionTicks: hour / 1000, runtimeTicks: hour, isPlayed: false) == .none)
    }

    /// A series folder carries no runtime of its own, so there is no fraction to
    /// draw — but it can legitimately be fully played.
    @Test("no runtime means no bar, while the played check still stands")
    func missingRuntime() {
        #expect(MediaCardStatus.make(positionTicks: hour, runtimeTicks: nil, isPlayed: false) == .none)
        #expect(MediaCardStatus.make(positionTicks: hour, runtimeTicks: 0, isPlayed: false) == .none)
        #expect(MediaCardStatus.make(positionTicks: 0, runtimeTicks: nil, isPlayed: true) == .watched)
    }

    @Test("a position past the runtime clamps to a full bar")
    func overrun() {
        #expect(MediaCardStatus.make(positionTicks: hour * 2, runtimeTicks: hour, isPlayed: false) == .inProgress(1))
    }
}
