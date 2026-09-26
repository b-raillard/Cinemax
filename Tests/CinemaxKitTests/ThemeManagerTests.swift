import Foundation
import Observation
import Testing
@testable import Cinemax

/// Set from an `onChange` observation callback, which fires synchronously on
/// the mutating (main) thread.
private final class ObservationFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
private func observes(_ read: () -> Void, changedBy mutate: () -> Void) -> Bool {
    let flag = ObservationFlag()
    withObservationTracking(read) { flag.fired = true }
    mutate()
    return flag.fired
}

/// Audit P7 (lot 8): the rainbow accent's 10 Hz tick used to bump the same
/// counter `colorScheme` reads, so the root `AppNavigation.body` re-ran ten
/// times a second. The tick must reach the accent getters and nothing else.
@MainActor
@Suite("ThemeManager rainbow tick")
struct ThemeManagerRainbowTickTests {
    /// Rainbow on, motion off — the tick task never starts, the test drives it.
    private func rainbowManager() -> ThemeManager {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set("rainbow", forKey: SettingsKey.accentColor)
        defaults.set(false, forKey: SettingsKey.motionEffects)
        return ThemeManager(defaults: defaults)
    }

    @Test("A rainbow tick repaints the accent")
    func tickReachesAccent() {
        let theme = rainbowManager()
        #expect(theme.isRainbow)
        #expect(observes({ _ = theme.accent }, changedBy: { theme.advanceRainbow() }))
        #expect(observes({ _ = theme.accentContainer }, changedBy: { theme.advanceRainbow() }))
        #expect(observes({ _ = theme.onAccentContainer }, changedBy: { theme.advanceRainbow() }))
    }

    @Test("A rainbow tick leaves the colour scheme alone")
    func tickSparesColorScheme() {
        let theme = rainbowManager()
        #expect(!observes({ _ = theme.colorScheme }, changedBy: { theme.advanceRainbow() }))
    }

    @Test("A fixed accent does not depend on the tick")
    func fixedAccentIgnoresTick() {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set("green", forKey: SettingsKey.accentColor)
        let theme = ThemeManager(defaults: defaults)
        #expect(!observes({ _ = theme.accent }, changedBy: { theme.advanceRainbow() }))
    }

    @Test("A settings change still reaches the colour scheme")
    func darkModeWriteReachesColorScheme() {
        let theme = rainbowManager()
        let before = theme.colorScheme
        #expect(observes({ _ = theme.colorScheme }, changedBy: { theme.darkModeEnabled.toggle() }))
        #expect(theme.colorScheme != before)
    }

    @Test("The injected store is the one read and written")
    func injectedStoreIsUsed() {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set("purple", forKey: SettingsKey.accentColor)
        let theme = ThemeManager(defaults: defaults)
        #expect(theme.accentColorKey == "purple")
        theme.accentColorKey = "cyan"
        #expect(defaults.string(forKey: SettingsKey.accentColor) == "cyan")
    }
}
