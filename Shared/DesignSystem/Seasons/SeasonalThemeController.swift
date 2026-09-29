import Foundation
import Observation

/// Owns « which season is on now ». A process singleton hosted by
/// `AppNavigation`, re-evaluated at launch, on return to the foreground, on
/// the day change and whenever a setting moves. Plain stored properties +
/// explicit mutators — no `didSet` on an `@Observable` (root RULE).
@MainActor @Observable
final class SeasonalThemeController {
    private(set) var activeTheme: SeasonalTheme?
    private(set) var setting: SeasonalSetting
    private(set) var ambianceEnabled: Bool
    private(set) var rowEnabled: Bool
    private(set) var forcedSeasonID: String
    /// A calm zone is on screen (Search, Settings — set by `MainTabView`): the
    /// near ambiance plane stays away where people read and type.
    private(set) var calmZone = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let catalogue: [SeasonalTheme]
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: @Sendable () -> Date

    init(
        defaults: UserDefaults = .standard,
        catalogue: [SeasonalTheme] = SeasonalThemeCatalogue.all,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.catalogue = catalogue
        self.calendar = calendar
        self.now = now
        setting = SeasonalSetting(rawValue: defaults.string(forKey: SettingsKey.seasonalTheme) ?? SettingsKey.Default.seasonalTheme) ?? .off
        ambianceEnabled = defaults.object(forKey: SettingsKey.seasonalAmbiance) as? Bool ?? SettingsKey.Default.seasonalAmbiance
        rowEnabled = defaults.object(forKey: SettingsKey.seasonalRow) as? Bool ?? SettingsKey.Default.seasonalRow
        forcedSeasonID = defaults.string(forKey: SettingsKey.debugForcedSeason) ?? SettingsKey.Default.debugForcedSeason
        reevaluate()
    }

    /// Recomputes the active season; writes only when it changed. Returns
    /// whether it did.
    @discardableResult
    func reevaluate() -> Bool {
        let theme = SeasonalThemePolicy.activeTheme(
            on: now(), calendar: calendar, setting: setting,
            forcedID: forcedSeasonID, catalogue: catalogue
        )
        guard theme != activeTheme else { return false }
        activeTheme = theme
        return true
    }

    func setSetting(_ value: SeasonalSetting) {
        setting = value
        defaults.set(value.rawValue, forKey: SettingsKey.seasonalTheme)
        reevaluate()
    }

    func setAmbianceEnabled(_ value: Bool) {
        ambianceEnabled = value
        defaults.set(value, forKey: SettingsKey.seasonalAmbiance)
    }

    func setRowEnabled(_ value: Bool) {
        rowEnabled = value
        defaults.set(value, forKey: SettingsKey.seasonalRow)
    }

    func setCalmZone(_ value: Bool) {
        guard value != calmZone else { return }
        calmZone = value
    }

    func setForcedSeason(_ id: String) {
        forcedSeasonID = id
        defaults.set(id, forKey: SettingsKey.debugForcedSeason)
        reevaluate()
    }
}
