import Foundation

enum SeasonalThemePolicy {
    /// A non-empty `forcedID` naming a catalogue season wins (Debug page);
    /// otherwise `.off` means none, and `.automatic` the season whose window
    /// contains `date`.
    static func activeTheme(
        on date: Date, calendar: Calendar, setting: SeasonalSetting,
        forcedID: String, catalogue: [SeasonalTheme]
    ) -> SeasonalTheme? {
        if !forcedID.isEmpty, let forced = catalogue.first(where: { $0.id == forcedID }) {
            return forced
        }
        guard setting == .automatic else { return nil }
        return catalogue.first { $0.window.contains(date, calendar: calendar) }
    }
}

enum AmbiancePolicy {
    /// Nothing moves when the user turned ambiance off, or when the app's
    /// motion effects / the system's Reduce Motion say no (`motionEnabled` is
    /// the combined `\.motionEffectsEnabled`). Off means ABSENT, not frozen.
    static func effects(theme: SeasonalTheme?, ambianceEnabled: Bool, motionEnabled: Bool) -> Set<AmbianceEffect> {
        guard let theme, ambianceEnabled, motionEnabled else { return [] }
        return theme.ambiance
    }
}

enum SeasonRowMatcher {
    /// The server's spelling of the first candidate it carries, or `nil`.
    static func match(candidates: [String], in serverGenres: [String]) -> String? {
        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        for candidate in candidates {
            let key = fold(candidate)
            if let hit = serverGenres.first(where: { fold($0) == key }) { return hit }
        }
        return nil
    }
}
