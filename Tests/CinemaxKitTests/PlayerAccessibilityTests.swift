import Testing
import UIKit
@testable import Cinemax

/// The VLC player's HUD is UIKit and needs a live engine to build, so its
/// VoiceOver strings live in `PlayerHUDAccessibility`, constructed from a
/// `localize` closure. These tests build it from the real fr / en bundles —
/// the `Localizable.strings` the app ships — without touching the app-wide
/// language a parallel test might read.
@MainActor
@Suite("PlayerAccessibility")
struct PlayerAccessibilityTests {

    private static func hud(_ language: String) -> PlayerHUDAccessibility {
        let bundle = Bundle.localizedBundle(for: language)
        return PlayerHUDAccessibility { bundle.localizedString(forKey: $0, value: nil, table: nil) }
    }

    private static func string(_ key: String, _ language: String) -> String {
        Bundle.localizedBundle(for: language).localizedString(forKey: key, value: nil, table: nil)
    }

    @Test("every HUD label is non-empty and resolved", arguments: ["fr", "en"])
    func labelsAreLocalized(language: String) {
        for label in Self.hud(language).controlLabels {
            #expect(!label.trimmingCharacters(in: .whitespaces).isEmpty)
            // An unresolved key comes back verbatim — that is the defect class.
            #expect(!label.hasPrefix("player."), "unresolved key: \(label)")
            #expect(!label.hasPrefix("action."), "unresolved key: \(label)")
        }
    }

    @Test("±10 s buttons name the interval, never the skip-segment control")
    func skipLabelsCarryTheInterval() {
        let interval = String(PlayerSkipConfig.intervalSeconds)
        for language in ["fr", "en"] {
            let hud = Self.hud(language)
            #expect(hud.skipBack.contains(interval))
            #expect(hud.skipForward.contains(interval))
            #expect(hud.skipBack != Self.string("player.skipIntro", language))
            #expect(hud.skipForward != Self.string("player.skipCredits", language))
        }
    }

    @Test("opposite controls never share a label")
    func oppositesAreDistinct() {
        for language in ["fr", "en"] {
            let hud = Self.hud(language)
            #expect(hud.play != hud.pause)
            #expect(hud.skipBack != hud.skipForward)
            #expect(hud.previousEpisode != hud.nextEpisode)
        }
    }

    @Test("French and English really differ")
    func languagesDiffer() {
        let fr = Self.hud("fr"), en = Self.hud("en")
        #expect(fr.skipBack != en.skipBack)
        #expect(fr.play != en.play)
        #expect(fr.loading != en.loading)
    }

    @Test("scrub value reads elapsed of total, elapsed alone while the runtime is unknown")
    func position() {
        #expect(Self.hud("en").position(elapsed: "4 minutes", total: "1 hour") == "4 minutes of 1 hour")
        #expect(Self.hud("fr").position(elapsed: "4 minutes", total: "1 heure") == "4 minutes sur 1 heure")
        #expect(Self.hud("en").position(elapsed: "4 minutes", total: nil) == "4 minutes")
    }

    @Test("spoken time is words in the app's language, never a clock string")
    func spokenTime() {
        let fr = PlayerTimeFormat.makeSpokenFormatter(languageCode: "fr")
        let en = PlayerTimeFormat.makeSpokenFormatter(languageCode: "en")
        let oneHourTwoMinutesThree: Int32 = 3_723_000
        #expect(PlayerTimeFormat.spoken(oneHourTwoMinutesThree, using: fr).contains("heure"))
        #expect(PlayerTimeFormat.spoken(oneHourTwoMinutesThree, using: en).contains("hour"))
        #expect(!PlayerTimeFormat.spoken(oneHourTwoMinutesThree, using: en).contains(":"))
        #expect(!PlayerTimeFormat.spoken(0, using: en).isEmpty)
    }

    @Test("the chapter under the playhead")
    func chapterUnderPlayhead() {
        #expect(PlayerChapterSelection.currentIndex(startTicks: [], positionTicks: 5) == nil)
        let starts = [50, 100, 200]
        #expect(PlayerChapterSelection.currentIndex(startTicks: starts, positionTicks: 10) == 0)
        #expect(PlayerChapterSelection.currentIndex(startTicks: starts, positionTicks: 99) == 0)
        #expect(PlayerChapterSelection.currentIndex(startTicks: starts, positionTicks: 100) == 1)
        #expect(PlayerChapterSelection.currentIndex(startTicks: starts, positionTicks: 10_000) == 2)
    }

    #if os(iOS)
    @Test("VoiceOver adjust on the scrub slider asks for a skip and leaves the value alone")
    func scrubSliderAdjust() {
        // Paired control: a plain UISlider answers the adjust gesture by moving
        // its OWN value — which the presenter never turns into a seek.
        let plain = UISlider()
        plain.value = 0.5
        plain.accessibilityIncrement()
        #expect(plain.value != 0.5)

        let slider = PlayerScrubSlider()
        slider.value = 0.5
        var steps: [Int] = []
        slider.onAccessibilityStep = { steps.append($0) }
        slider.accessibilityIncrement()
        slider.accessibilityDecrement()
        #expect(steps == [1, -1])
        #expect(slider.value == 0.5)
    }
    #endif
}
