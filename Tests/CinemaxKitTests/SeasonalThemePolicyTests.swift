import Foundation
import Testing
@testable import Cinemax

@Suite("Seasonal theme policy")
struct SeasonalThemePolicyTests {
    private func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private let halloween = SeasonalThemeCatalogue.halloween

    /// A season that wraps the New Year, the Christmas case.
    private let winter = SeasonalTheme(
        id: "test.winter", nameKey: "season.halloween.name",
        window: SeasonWindow(start: MonthDay(month: 12, day: 20), end: MonthDay(month: 1, day: 6)),
        dark: SeasonalThemeCatalogue.halloween.dark, light: nil,
        accent: SeasonalThemeCatalogue.halloween.accent, titleFont: nil, ambiance: [], row: nil, backdrop: nil
    )

    @Test("Halloween starts on 1 October at midnight, local time")
    func startBoundary() {
        let paris = calendar("Europe/Paris")
        // 23:59:59 on 30 September in Paris is 21:59:59Z.
        #expect(halloween.window.contains(date("2026-09-30T21:59:59Z"), calendar: paris) == false)
        #expect(halloween.window.contains(date("2026-09-30T22:00:00Z"), calendar: paris) == true)
    }

    @Test("Halloween ends after 2 November, local time")
    func endBoundary() {
        let paris = calendar("Europe/Paris")
        // Paris is UTC+1 after the October DST change.
        #expect(halloween.window.contains(date("2026-11-02T22:59:59Z"), calendar: paris) == true)
        #expect(halloween.window.contains(date("2026-11-02T23:00:00Z"), calendar: paris) == false)
    }

    @Test("The same instant can be in season in Tokyo and not in Paris")
    func timeZoneDecides() {
        let instant = date("2026-09-30T20:00:00Z")
        #expect(halloween.window.contains(instant, calendar: calendar("Europe/Paris")) == false)
        #expect(halloween.window.contains(instant, calendar: calendar("Asia/Tokyo")) == true)
    }

    @Test("A window can wrap the New Year")
    func wrapsNewYear() {
        let utc = calendar("UTC")
        #expect(winter.window.contains(date("2026-12-19T12:00:00Z"), calendar: utc) == false)
        #expect(winter.window.contains(date("2026-12-20T00:00:00Z"), calendar: utc) == true)
        #expect(winter.window.contains(date("2026-12-31T12:00:00Z"), calendar: utc) == true)
        #expect(winter.window.contains(date("2027-01-06T23:59:59Z"), calendar: utc) == true)
        #expect(winter.window.contains(date("2027-01-07T00:00:00Z"), calendar: utc) == false)
    }

    @Test("Automatic picks the season whose window contains the date")
    func automatic() {
        let theme = SeasonalThemePolicy.activeTheme(
            on: date("2026-10-20T12:00:00Z"), calendar: calendar("UTC"),
            setting: .automatic, forcedID: "", catalogue: [halloween]
        )
        #expect(theme?.id == "halloween")
    }

    @Test("Off means no season, even inside the window")
    func off() {
        let theme = SeasonalThemePolicy.activeTheme(
            on: date("2026-10-20T12:00:00Z"), calendar: calendar("UTC"),
            setting: .off, forcedID: "", catalogue: [halloween]
        )
        #expect(theme == nil)
    }

    @Test("A forced season wins over the date and the setting")
    func forced() {
        let theme = SeasonalThemePolicy.activeTheme(
            on: date("2026-06-01T12:00:00Z"), calendar: calendar("UTC"),
            setting: .off, forcedID: "halloween", catalogue: [halloween]
        )
        #expect(theme?.id == "halloween")
    }

    @Test("An unknown forced id is ignored")
    func unknownForced() {
        let theme = SeasonalThemePolicy.activeTheme(
            on: date("2026-06-01T12:00:00Z"), calendar: calendar("UTC"),
            setting: .automatic, forcedID: "noel-2099", catalogue: [halloween]
        )
        #expect(theme == nil)
    }

    @Test("Catalogue lookup by id")
    func lookup() {
        #expect(SeasonalThemeCatalogue.theme(id: "halloween")?.id == "halloween")
        #expect(SeasonalThemeCatalogue.theme(id: nil) == nil)
        #expect(SeasonalThemeCatalogue.theme(id: "nope") == nil)
    }

    @Test("No two catalogue windows share a day")
    func noOverlap() {
        let utc = calendar("UTC")
        let all = SeasonalThemeCatalogue.all
        var day = date("2028-01-01T12:00:00Z")   // leap year: 29 February included
        for _ in 0..<366 {
            let hits = all.filter { $0.window.contains(day, calendar: utc) }
            #expect(hits.count <= 1, "overlap on \(day)")
            day = utc.date(byAdding: .day, value: 1, to: day)!
        }
    }

    @Test("Every season's keys exist in French and English")
    func keysExist() throws {
        for lang in ["fr", "en"] {
            let path = try #require(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: lang))
            let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
            for theme in SeasonalThemeCatalogue.all {
                #expect(table[theme.nameKey] != nil, "\(lang): \(theme.nameKey)")
                if let row = theme.row { #expect(table[row.titleKey] != nil, "\(lang): \(row.titleKey)") }
            }
        }
    }

    // MARK: Contrast

    private func luminance(_ hex: UInt) -> Double {
        func channel(_ v: UInt) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 255) + 0.7152 * channel((hex >> 8) & 255) + 0.0722 * channel(hex & 255)
    }

    private func contrast(_ a: UInt, _ b: UInt) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test("Season text and accent clear 4.5:1 on every season surface")
    func contrastDark() {
        for theme in SeasonalThemeCatalogue.all {
            let p = theme.dark
            for surface in [p.surface, p.surfaceContainerLow, p.surfaceContainer, p.surfaceContainerHigh] {
                for text in [p.onSurface, p.onSurfaceVariant, p.onSurfaceMuted, theme.accent.accentDark] {
                    #expect(contrast(text, surface) >= 4.5, "\(theme.id): \(String(text, radix: 16)) on \(String(surface, radix: 16))")
                }
            }
            #expect(contrast(theme.accent.onAccentDark, theme.accent.accentDark) >= 4.5)
        }
    }

    @Test("A season without a light palette keeps a readable light-mode accent")
    func contrastLightAccent() {
        for theme in SeasonalThemeCatalogue.all where theme.light == nil {
            // CinemaColor.surface / surfaceContainer, light mode.
            #expect(contrast(theme.accent.accentLight, 0xF7F7F8) >= 4.5)
            #expect(contrast(theme.accent.accentLight, 0xEAEAEC) >= 4.4)
        }
    }

    // MARK: Ambiance + row matching

    @Test("Ambiance: season effects only when enabled and motion allowed")
    func ambiance() {
        #expect(AmbiancePolicy.effects(theme: halloween, ambianceEnabled: true, motionEnabled: true) == [.bats, .pumpkins, .focusGlow])
        #expect(AmbiancePolicy.effects(theme: halloween, ambianceEnabled: false, motionEnabled: true).isEmpty)
        #expect(AmbiancePolicy.effects(theme: nil, ambianceEnabled: true, motionEnabled: true).isEmpty)
    }

    @Test("Reduce Motion removes every effect")
    func reduceMotionRemovesEveryEffect() {
        #expect(AmbiancePolicy.effects(theme: halloween, ambianceEnabled: true, motionEnabled: false).isEmpty)
    }

    @Test("Genre matching ignores case and accents, first candidate wins")
    func matcher() {
        #expect(SeasonRowMatcher.match(candidates: ["Horror", "Horreur"], in: ["Action", "horreur"]) == "horreur")
        #expect(SeasonRowMatcher.match(candidates: ["Épouvante-horreur"], in: ["EPOUVANTE-HORREUR"]) == "EPOUVANTE-HORREUR")
        #expect(SeasonRowMatcher.match(candidates: ["Horror", "Horreur"], in: ["Horreur", "Horror"]) == "Horror")
        #expect(SeasonRowMatcher.match(candidates: ["Horror"], in: ["Comédie"]) == nil)
        #expect(SeasonRowMatcher.match(candidates: ["Horror"], in: []) == nil)
    }

    @Test("Settings summary: season name and dates, day-month order of the locale")
    @MainActor
    func windowSummary() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let fr = SeasonalSettingsText.windowSummary(
            for: halloween, name: "Nuit d'Halloween", template: "%1$@, du %2$@ au %3$@",
            locale: Locale(identifier: "fr_FR"), calendar: utc
        )
        let en = SeasonalSettingsText.windowSummary(
            for: halloween, name: "Halloween Night", template: "%1$@, %2$@ to %3$@",
            locale: Locale(identifier: "en_US"), calendar: utc
        )
        #expect(fr == "Nuit d'Halloween, du 1er octobre au 2 novembre")
        #expect(en == "Halloween Night, October 1 to November 2")
    }

    @MainActor
    @Test("The first of the month is an ordinal in French, abbreviated or not")
    func frenchFirstOfMonth() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let first = MonthDay(month: 10, day: 1)
        let fr = Locale(identifier: "fr_FR")
        #expect(SeasonalSettingsText.dayMonth(first, locale: fr, calendar: utc) == "1er octobre")
        #expect(SeasonalSettingsText.dayMonth(first, locale: fr, calendar: utc, abbreviated: true) == "1er oct.")
        #expect(SeasonalSettingsText.dayMonth(MonthDay(month: 11, day: 2), locale: fr, calendar: utc, abbreviated: true) == "2 nov.")
        #expect(SeasonalSettingsText.dayMonth(first, locale: Locale(identifier: "en_US"), calendar: utc, abbreviated: true) == "Oct 1")
    }

    // MARK: Density — an intense opening, then calm

    @Test("Full density for the first 30 s, about a third after")
    func densityIntroThenCalm() {
        #expect(AmbiancePolicy.density(elapsed: 0, isTV: false) == 1)
        #expect(AmbiancePolicy.density(elapsed: 29.9, isTV: false) == 1)
        #expect(AmbiancePolicy.density(elapsed: 30, isTV: false) < 0.4)
        #expect(AmbiancePolicy.density(elapsed: 600, isTV: false) < 0.4)
    }

    @Test("Apple TV runs at half the density")
    func densityHalvedOnTV() {
        #expect(AmbiancePolicy.density(elapsed: 0, isTV: true) == 0.5)
        #expect(AmbiancePolicy.density(elapsed: 60, isTV: true) < 0.2)
    }

    @Test("Bat counts follow the density, never below one")
    func batCounts() {
        #expect(AmbiancePolicy.batCount(dense: 8, elapsed: 0, isTV: false) == 8)
        #expect(AmbiancePolicy.batCount(dense: 8, elapsed: 45, isTV: false) == 3)
        #expect(AmbiancePolicy.batCount(dense: 8, elapsed: 0, isTV: true) == 4)
        #expect(AmbiancePolicy.batCount(dense: 2, elapsed: 45, isTV: true) == 1)
    }

    @Test("Halloween paints a night sky behind the browsing screens")
    func halloweenBackdrop() {
        #expect(halloween.backdrop == .nightSky)
    }
}
