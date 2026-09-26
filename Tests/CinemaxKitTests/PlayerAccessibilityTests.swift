import Testing
import JellyfinAPI
import SwiftUI
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
        // There is deliberately NO paired control on a stock `UISlider`, and
        // that absence is measured rather than lazy: `accessibilityIncrement()`
        // on a DETACHED slider does not move its value (2026-09-12 — the
        // assertion `plain.value != 0.5` failed), because UIKit implements
        // adjustment on the accessibility element, which a view outside a
        // window never realises. So "what a stock slider does with the adjust
        // gesture" is not observable from a unit test; what IS observable is
        // that this subclass hands the gesture over and leaves its own value
        // alone, which is the property the presenter depends on.
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

// MARK: - Accent label contrast (audit 2026-09-22, U4)

/// A white label on the accent fill fell under 3:1 on yellow and cyan — the
/// floor WCAG sets even for large text — on « Lecture » and « Connexion ».
@Suite("Accent label contrast")
struct AccentLabelContrastTests {
    /// The picker's selection check sits on the SWATCH fill (`accentLight` /
    /// `accentDark`). White was ~1.6:1 on the dark-mode yellow and cyan swatches;
    /// every check must now clear the 3:1 floor for graphical objects.
    @Test("Every swatch check clears 3:1, yellow and cyan go dark")
    func swatchChecksReadOnTheirFill() {
        func ratio(label: UInt, fill: UInt) -> Double {
            AccentLabelContrast.contrast(AccentLabelContrast.luminance(hex: label), AccentLabelContrast.luminance(hex: fill))
        }
        for option in AccentOption.allCases where option != .rainbow {
            for fill in [option.palette.accentLight, option.palette.accentDark] {
                let label: UInt = AccentLabelContrast.prefersDarkLabel(hex: fill) ? AccentLabelContrast.darkLabel : 0xFFFFFF
                #expect(ratio(label: label, fill: fill) >= 3.0, "\(option) on \(String(fill, radix: 16))")
            }
        }
        for option in [AccentOption.yellow, .cyan] {
            #expect(AccentLabelContrast.prefersDarkLabel(hex: option.palette.accentDark), "\(option)")
            #expect(ratio(label: 0xFFFFFF, fill: option.palette.accentDark) < 2.0, "\(option): white really was unreadable")
        }
    }


    @Test("yellow, cyan and orange fills take a dark label, and it reads")
    func paleFillsGoDark() {
        for option in [AccentOption.yellow, .cyan, .orange] {
            let fill = option.palette.containerLight
            #expect(AccentLabelContrast.prefersDarkLabel(hex: fill), "\(option)")
            let ratio = AccentLabelContrast.contrast(
                AccentLabelContrast.luminance(hex: AccentLabelContrast.darkLabel),
                AccentLabelContrast.luminance(hex: fill)
            )
            #expect(ratio >= 4.5, "\(option): \(ratio)")
        }
    }

    @Test("the saturated fills keep the design's white label, at 3:1 or better")
    func saturatedFillsStayWhite() {
        for option in [AccentOption.red, .green, .blue, .indigo, .purple, .pink] {
            for fill in [option.palette.containerLight, option.palette.containerDark] {
                #expect(!AccentLabelContrast.prefersDarkLabel(hex: fill), "\(option)")
                let ratio = AccentLabelContrast.contrast(1.0, AccentLabelContrast.luminance(hex: fill))
                #expect(ratio >= 3.0, "\(option): \(ratio)")
            }
        }
    }

    @Test("every visible accent has a localized name, in both languages")
    func everyAccentIsNamed() {
        for language in ["fr", "en"] {
            let bundle = Bundle.localizedBundle(for: language)
            for option in AccentOption.allCases {
                let name = bundle.localizedString(forKey: option.nameKey, value: nil, table: nil)
                #expect(name != option.nameKey, "\(language): \(option.nameKey)")
            }
        }
    }
}


// MARK: - Toasts under VoiceOver (audit 2026-09-22, U3)

@Suite("Toast announcements")
struct ToastAnnouncementTests {

    @Test("the announcement is the title, then the message when there is one")
    func announcementText() {
        let bare = Toast(level: .success, title: "Ajouté aux favoris", message: nil, duration: 2.5)
        #expect(ToastCenter.announcement(for: bare) == "Ajouté aux favoris")
        let empty = Toast(level: .info, title: "Copié", message: "", duration: 2.5)
        #expect(ToastCenter.announcement(for: empty) == "Copié")
        let full = Toast(level: .error, title: "Échec", message: "Serveur injoignable", duration: 4)
        #expect(ToastCenter.announcement(for: full) == "Échec. Serveur injoignable")
    }

    @Test("under VoiceOver a toast stays at least 6 s, twice as long beyond that")
    func voiceOverDuration() {
        #expect(ToastCenter.effectiveDuration(2.5, voiceOverRunning: false) == 2.5)
        #expect(ToastCenter.effectiveDuration(2.5, voiceOverRunning: true) == 6)
        #expect(ToastCenter.effectiveDuration(4, voiceOverRunning: true) == 8)
    }
}

// MARK: - Plurals (audit 2026-09-22)

@Suite("Plural rule")
struct PluralRuleTests {

    /// Apple TV has no touch: « tirez pour actualiser » and « touchez le cœur »
    /// were shown there verbatim (audit §5, lot 9).
    @Test("tvOS variants exist in both languages and never speak of touch")
    func tvVariantsAvoidTouch() {
        let touchWords = ["tirez", "touchez", "pull down", "tap "]
        for language in ["fr", "en"] {
            let bundle = Bundle.localizedBundle(for: language)
            for key in ["favorites.empty.subtitle", "empty.home.subtitle"] {
                let tv = bundle.localizedString(forKey: key + ".tv", value: nil, table: nil)
                #expect(tv != key + ".tv", "\(language): \(key).tv")
                for word in touchWords {
                    #expect(!tv.lowercased().contains(word), "\(language): \(key).tv says « \(word) »")
                }
            }
        }
        #if os(tvOS)
        #expect(LocalizationManager.platformVariant("empty.home.subtitle") == "empty.home.subtitle.tv")
        #else
        #expect(LocalizationManager.platformVariant("empty.home.subtitle") == "empty.home.subtitle")
        #endif
    }

    @Test("French puts 0 and 1 in the singular, English only 1")
    func singularRule() {
        #expect(LocalizationManager.usesSingular(0, languageCode: "fr"))
        #expect(LocalizationManager.usesSingular(1, languageCode: "fr"))
        #expect(!LocalizationManager.usesSingular(2, languageCode: "fr"))
        #expect(!LocalizationManager.usesSingular(0, languageCode: "en"))
        #expect(LocalizationManager.usesSingular(1, languageCode: "en"))
        #expect(!LocalizationManager.usesSingular(2, languageCode: "en"))
    }

    @Test("every plural key used through `counted` has its `.one` sibling in both languages")
    func singularSiblingsExist() {
        let keys = ["library.itemCount", "detail.collection.count", "search.resultCount",
                    "home.remainingTime.minutes", "movies.count", "movies.titles", "tvShows.count",
                    "person.titleCount", "syncplay.participants", "syncplay.session.more"]
        for language in ["fr", "en"] {
            let bundle = Bundle.localizedBundle(for: language)
            for key in keys {
                let one = key + ".one"
                #expect(bundle.localizedString(forKey: one, value: nil, table: nil) != one, "\(language): \(one)")
            }
        }
    }
}

// MARK: - App locale (audit 2026-09-22, Q7)

@Suite("App locale")
struct AppLocaleTests {

    @Test("the app's language keeps the device's region")
    func languageWithRegion() {
        #expect(LocalizationManager.locale(languageCode: "fr", region: "BE").identifier == "fr_BE")
        #expect(LocalizationManager.locale(languageCode: "en", region: nil).identifier == "en")
        #expect(LocalizationManager.locale(languageCode: "en", region: "").identifier == "en")
    }

    @Test("a French app writes a decimal comma, whatever the device language")
    func frenchDecimal() {
        let fr = LocalizationManager.locale(languageCode: "fr", region: "FR")
        #expect(7.5.formatted(.number.precision(.fractionLength(1)).locale(fr)) == "7,5")
        let en = LocalizationManager.locale(languageCode: "en", region: "US")
        #expect(7.5.formatted(.number.precision(.fractionLength(1)).locale(en)) == "7.5")
    }
}

/// Audit 2026-09-22 (Q4) : la fenêtre des toasts est plein écran et laisse
/// passer tout toucher hors du toast. Si elle devenait « clé », le lecteur
/// serait présenté dedans, inutilisable. Elle ne le devient jamais, et la
/// recherche du contrôleur du haut l'ignore.
@MainActor
@Suite("Fenêtre des toasts — jamais hôte d'une présentation")
struct ToastWindowPresentationTests {
    @Test("The toast window refuses to become key")
    func toastWindowNeverKey() {
        #expect(ToastPassthroughWindow().canBecomeKey == false)
    }

    @Test("A touch outside the toast falls through; one inside is kept")
    func hitTestPassesThroughOutsideTheToast() {
        let window = ToastPassthroughWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = UIViewController()
        window.isHidden = false
        window.toastFrame = CGRect(x: 20, y: 60, width: 360, height: 80)
        #expect(window.hitTest(CGPoint(x: 200, y: 400), with: nil) == nil)
        #expect(window.hitTest(CGPoint(x: 200, y: 100), with: nil) != nil)
        window.toastFrame = .zero
        #expect(window.hitTest(CGPoint(x: 200, y: 100), with: nil) == nil)
        window.isHidden = true
    }
}

/// The « Reprendre » / « À suivre » cards announced half of what they draw —
/// Next Up the series alone, Continue Watching the episode's bare name.
@Suite("Spoken episode card label")
struct SpokenEpisodeCardLabelTests {
    private func localize(_ language: String) -> (String) -> String {
        let bundle = Bundle.localizedBundle(for: language)
        return { bundle.localizedString(forKey: $0, value: nil, table: nil) }
    }

    @Test("An episode says series, season, episode and title, in words")
    func episode() {
        var item = BaseItemDto(indexNumber: 2, name: "Deux hommes morts", parentIndexNumber: 1, seriesName: "Andor", type: .episode)
        #expect(item.spokenCardLabel(localize: localize("fr")) == "Andor, saison 1, épisode 2, Deux hommes morts")
        #expect(item.spokenCardLabel(localize: localize("en")) == "Andor, season 1, episode 2, Deux hommes morts")
        item.indexNumber = nil
        #expect(item.spokenCardLabel(localize: localize("fr")) == "Andor, Deux hommes morts")
    }

    @Test("A film says its title")
    func movie() {
        let item = BaseItemDto(name: "Sintel", type: .movie)
        #expect(item.spokenCardLabel(localize: localize("fr")) == "Sintel")
    }
}

#if os(iOS)
/// The toast window sits above the app's; its root controller must not answer
/// « status bar shown » over a player that asked for it hidden.
@MainActor
@Suite("Toast window system chrome")
struct ToastWindowChromeTests {
    private final class HidingController: UIViewController {
        override var prefersStatusBarHidden: Bool { true }
        override var prefersHomeIndicatorAutoHidden: Bool { true }
    }

    @Test("The toast host defers to the app window's top-most controller")
    func defersToAppWindow() {
        let appWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        appWindow.rootViewController = HidingController()
        let host = ToastHostingController(rootView: AnyView(EmptyView()))
        #expect(!host.prefersStatusBarHidden)
        host.appWindow = appWindow
        #expect(host.prefersStatusBarHidden)
        #expect(host.prefersHomeIndicatorAutoHidden)
    }
}
#endif
