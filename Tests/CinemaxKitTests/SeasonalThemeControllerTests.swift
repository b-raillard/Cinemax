import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Cinemax

/// A clock a test can move. Read from the controller's `@Sendable` `now`.
/// `@unchecked`: only ever set and read on the main actor (the suite and the
/// controller are both `@MainActor`); a test moving it off the main actor
/// would need a lock.
private final class TestClock: @unchecked Sendable {
    var date: Date
    init(_ iso: String) { date = ISO8601DateFormatter().date(from: iso)! }
    func set(_ iso: String) { date = ISO8601DateFormatter().date(from: iso)! }
}

@Suite("Seasonal theme controller")
@MainActor
struct SeasonalThemeControllerTests {
    private var paris: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }

    private func make(_ clock: TestClock, defaults: UserDefaults = .isolatedForTesting()) -> SeasonalThemeController {
        SeasonalThemeController(defaults: defaults, calendar: paris, now: { clock.date })
    }

    @Test("Active inside the window on first evaluation")
    func activeAtLaunch() {
        let c = make(TestClock("2026-10-20T12:00:00Z"))
        #expect(c.activeTheme?.id == "halloween")
    }

    @Test("Inactive outside the window")
    func inactiveOutside() {
        let c = make(TestClock("2026-06-20T12:00:00Z"))
        #expect(c.activeTheme == nil)
    }

    @Test("Day change ends the season without relaunch")
    func dayChangeEndsTheSeasonWithoutRelaunch() {
        let clock = TestClock("2026-11-02T22:30:00Z")   // 23:30 in Paris, 2 Nov
        let c = make(clock)
        #expect(c.activeTheme?.id == "halloween")
        clock.set("2026-11-02T23:00:01Z")               // 00:00:01, 3 Nov
        #expect(c.reevaluate() == true)
        #expect(c.activeTheme == nil)
        #expect(c.reevaluate() == false)                // nothing changed
    }

    @Test("Turning the setting off ends the season now, and persists")
    func settingOff() {
        let defaults = UserDefaults.isolatedForTesting()
        let c = make(TestClock("2026-10-20T12:00:00Z"), defaults: defaults)
        c.setSetting(.off)
        #expect(c.activeTheme == nil)
        #expect(defaults.string(forKey: SettingsKey.seasonalTheme) == "off")
        let reborn = make(TestClock("2026-10-20T12:00:00Z"), defaults: defaults)
        #expect(reborn.setting == .off)
        #expect(reborn.activeTheme == nil)
    }

    @Test("Forcing a season works outside its window; clearing restores the date rule")
    func forcing() {
        let c = make(TestClock("2026-06-20T12:00:00Z"))
        c.setForcedSeason("halloween")
        #expect(c.activeTheme?.id == "halloween")
        c.setForcedSeason("")
        #expect(c.activeTheme == nil)
    }

    @Test("Ambiance and row switches persist")
    func switches() {
        let defaults = UserDefaults.isolatedForTesting()
        let c = make(TestClock("2026-10-20T12:00:00Z"), defaults: defaults)
        #expect(c.ambianceEnabled && c.rowEnabled)
        c.setAmbianceEnabled(false)
        c.setRowEnabled(false)
        #expect(defaults.bool(forKey: SettingsKey.seasonalAmbiance) == false)
        #expect(defaults.bool(forKey: SettingsKey.seasonalRow) == false)
    }

    // MARK: ThemeManager

    private func darkHex(_ color: Color) -> UInt {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt((r * 255).rounded()) << 16 | UInt((g * 255).rounded()) << 8 | UInt((b * 255).rounded())
    }

    @Test("Season accent replaces the displayed accent, never the stored one")
    func seasonAccent() {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set("blue", forKey: SettingsKey.accentColor)
        let tm = ThemeManager(defaults: defaults)
        tm.setSeasonAccent(SeasonalThemeCatalogue.halloween.accent)
        #expect(tm.isSeasonAccentActive)
        #expect(darkHex(tm.accent) == 0xFF7A1A)
        #expect(tm.accentColorKey == "blue")
        tm.setSeasonAccent(nil)
        #expect(!tm.isSeasonAccentActive)
        #expect(darkHex(tm.accent) == 0x679CFF)
    }

    @Test("Season accent beats the rainbow easter egg")
    func seasonAccentBeatsRainbow() {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set("rainbow", forKey: SettingsKey.accentColor)
        let tm = ThemeManager(defaults: defaults)
        tm.setSeasonAccent(SeasonalThemeCatalogue.halloween.accent)
        #expect(darkHex(tm.accent) == 0xFF7A1A)
        #expect(darkHex(tm.accentContainer) == 0xE06A1A)
    }

    @Test("Calm zone: set by the tab bar, read by the root overlay")
    func calmZone() {
        let c = make(TestClock("2026-10-20T12:00:00Z"))
        #expect(c.calmZone == false)
        c.setCalmZone(true)
        #expect(c.calmZone)
        c.setCalmZone(false)
        #expect(c.calmZone == false)
    }
}
