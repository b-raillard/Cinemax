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

/// Locks what VoiceOver hears on a poster card. The overlay's check and bar are
/// hidden from accessibility, so this value is the only way a VoiceOver user
/// learns a card's state — and it is read off the same `MediaCardStatus` the
/// overlay draws. Built from the real fr / en bundles (the
/// `PlayerAccessibilityTests` shape), never the app-wide language.
@Suite("MediaCardStatus VoiceOver value")
struct MediaCardStatusAccessibilityTests {

    private let hour = 36_000_000_000  // one hour in Jellyfin ticks

    private static func value(_ status: MediaCardStatus, _ language: String) -> String? {
        let bundle = Bundle.localizedBundle(for: language)
        return status.accessibilityValue { bundle.localizedString(forKey: $0, value: nil, table: nil) }
    }

    @Test("an untouched card announces nothing beyond its label", arguments: ["fr", "en"])
    func noneHasNoValue(language: String) {
        #expect(Self.value(.none, language) == nil)
    }

    @Test("a watched card says so")
    func watched() {
        #expect(Self.value(.watched, "fr") == "Vu")
        #expect(Self.value(.watched, "en") == "Watched")
    }

    @Test("a part-watched card speaks its whole percent")
    func inProgress() {
        #expect(Self.value(.inProgress(0.35), "fr") == "35 % regardé")
        #expect(Self.value(.inProgress(0.35), "en") == "35% watched")
    }

    @Test("the spoken value follows the same derivation as the overlay")
    func followsMake() {
        let status = MediaCardStatus.make(positionTicks: hour / 4, runtimeTicks: hour, isPlayed: false)
        #expect(Self.value(status, "en") == "25% watched")
        let played = MediaCardStatus.make(positionTicks: hour / 2, runtimeTicks: hour, isPlayed: true)
        #expect(Self.value(played, "en") == "Watched")
    }

    @Test("the spoken percent stays within 1…100 and rounds to the nearest whole")
    func spokenPercentBounds() {
        #expect(MediaCardStatus.spokenPercent(0.349) == 35)
        #expect(MediaCardStatus.spokenPercent(0.001) == 1)
        #expect(MediaCardStatus.spokenPercent(0.996) == 100)
        #expect(MediaCardStatus.spokenPercent(2) == 100)
        #expect(MediaCardStatus.spokenPercent(-1) == 1)
    }

    @Test("every language resolves both keys", arguments: ["fr", "en"])
    func keysResolve(language: String) {
        for status in [MediaCardStatus.watched, .inProgress(0.5)] {
            let spoken = Self.value(status, language) ?? ""
            #expect(!spoken.isEmpty)
            // An unresolved key comes back verbatim — that is the defect class.
            #expect(!spoken.hasPrefix("card.status"), "unresolved key: \(spoken)")
        }
    }
}
