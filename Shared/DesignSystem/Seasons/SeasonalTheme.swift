import Foundation

// MARK: - Seasonal themes
//
// A season is DATA: its dates, its palette, its accent, its title font, its
// ambiance and its Home row. `SeasonalThemeCatalogue` lists them; adding
// Christmas is one more entry, no new logic. See
// docs/superpowers/specs/2026-09-28-seasonal-themes-design.md.

struct MonthDay: Sendable, Equatable, Comparable {
    let month: Int   // 1…12
    let day: Int     // 1…31

    static func < (a: Self, b: Self) -> Bool {
        (a.month, a.day) < (b.month, b.day)
    }
}

/// Both ends INCLUDED, read in the calendar's time zone (the device's, in the
/// app). `start > end` means the window wraps the New Year.
struct SeasonWindow: Sendable, Equatable {
    let start: MonthDay
    let end: MonthDay

    func contains(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return false }
        let today = MonthDay(month: month, day: day)
        if start <= end { return start <= today && today <= end }
        return today >= start || today <= end
    }
}

/// The `CinemaColor` tokens a season may repaint. Every other token (error,
/// success, primary…) keeps its value.
enum SeasonToken: Sendable, CaseIterable {
    case surface, surfaceContainerLowest, surfaceContainerLow, surfaceContainer
    case surfaceContainerHigh, surfaceContainerHighest, surfaceVariant
    case onSurface, onSurfaceVariant, onSurfaceMuted
    case outline, outlineVariant
}

struct SeasonPalette: Sendable, Equatable {
    let surface: UInt
    let surfaceContainerLowest: UInt
    let surfaceContainerLow: UInt
    let surfaceContainer: UInt
    let surfaceContainerHigh: UInt
    let surfaceContainerHighest: UInt
    let surfaceVariant: UInt
    let onSurface: UInt
    let onSurfaceVariant: UInt
    let onSurfaceMuted: UInt
    let outline: UInt
    let outlineVariant: UInt

    subscript(_ token: SeasonToken) -> UInt {
        switch token {
        case .surface: surface
        case .surfaceContainerLowest: surfaceContainerLowest
        case .surfaceContainerLow: surfaceContainerLow
        case .surfaceContainer: surfaceContainer
        case .surfaceContainerHigh: surfaceContainerHigh
        case .surfaceContainerHighest: surfaceContainerHighest
        case .surfaceVariant: surfaceVariant
        case .onSurface: onSurface
        case .onSurfaceVariant: onSurfaceVariant
        case .onSurfaceMuted: onSurfaceMuted
        case .outline: outline
        case .outlineVariant: outlineVariant
        }
    }
}

struct SeasonFont: Sendable, Equatable {
    let postScriptName: String
    let fileName: String
}

enum AmbianceEffect: String, Sendable, CaseIterable {
    case bats, pumpkins, focusGlow
}

/// What a season paints BEHIND the browsing screens (`SeasonalBackdrop`).
enum SeasonBackdrop: Sendable {
    /// Stars (dark mode), a few twinkling, cobwebs in the top corners.
    case nightSky
}

struct SeasonRow: Sendable, Equatable {
    let titleKey: String
    /// Compared case- and accent-insensitively with the server's genre names,
    /// which follow the library's metadata language.
    let genreCandidates: [String]
    /// Keywords matched against the items' tags (Jellyfin imports TMDb's
    /// keywords as tags, in English whatever the metadata language). TMDb
    /// files series under no « Horror » genre — « Mercredi » is « Mystère,
    /// Comédie » — so without them the row was films only.
    let tagCandidates: [String]

    init(titleKey: String, genreCandidates: [String], tagCandidates: [String] = []) {
        self.titleKey = titleKey
        self.genreCandidates = genreCandidates
        self.tagCandidates = tagCandidates
    }
}

struct SeasonalTheme: Sendable, Equatable, Identifiable {
    let id: String
    let nameKey: String
    let window: SeasonWindow
    let dark: SeasonPalette
    /// `nil`: in light mode the season leaves the surfaces alone; only the
    /// accent, the titles, the ambiance and the row change.
    let light: SeasonPalette?
    let accent: AccentOption.Palette
    let titleFont: SeasonFont?
    let ambiance: Set<AmbianceEffect>
    let row: SeasonRow?
    let backdrop: SeasonBackdrop?
}

/// Settings → Appearance (lot C, 2026-10-22): Automatique (the season whose
/// window contains today), Désactivé, or Halloween forced at ANY date — the
/// Pro's « Halloween toute l'année », refused to the free tier after the
/// launch (`SeasonalThemePolicy.effectiveSetting`). A forced choice's raw value
/// IS its catalogue id, so a second forced season (Christmas…) is one more case
/// and no migration; « automatic » / « off » read back exactly as before.
/// The Debug page's `debug.forcedSeason` beats all three.
enum SeasonalSetting: String, Sendable, CaseIterable {
    case automatic, off
    case halloween

    /// The order of the Réglages choices.
    static let choices: [Self] = allCases

    /// « Automatique » / « Désactivé » / « Halloween ».
    var labelKey: String { "settings.seasonal.choice.\(rawValue)" }

    /// The catalogue season a forced choice names; `nil` for the two others.
    var forcedSeasonID: String? {
        switch self {
        case .automatic, .off: nil
        case .halloween: rawValue
        }
    }

    /// The user has accepted seasonal themes in some form — what « Quoi de
    /// neuf »'s offer asks: it must never re-offer to (nor downgrade) a forced
    /// choice.
    var isOptedIn: Bool { self != .off }

    /// The choice `step` places away (±1, wrapping — the tvOS row's press and
    /// Left / Right), if `admit` lets the user have it; refused, the selection
    /// STAYS. `admit` is asked once: for the Pro choice it is
    /// `ProFeatureAccess.admit`, whose refusal raises the Pro sheet. Never
    /// skip past a refused choice: that wrote the one after it — Left from
    /// Automatique landed on Désactivé and took Halloween off a free user's
    /// screen in season (recette lot C). The other way round still reaches
    /// every free choice.
    func stepped(by step: Int, admit: (Self) -> Bool) -> Self {
        let all = Self.choices
        guard let start = all.firstIndex(of: self) else { return self }
        let next = all[((start + step) % all.count + all.count) % all.count]
        return admit(next) ? next : self
    }
}
