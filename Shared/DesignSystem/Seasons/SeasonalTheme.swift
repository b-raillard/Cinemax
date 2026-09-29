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

/// Settings → Appearance. No « always »: with several seasons it has no
/// meaning; the Debug page can force one for testing.
enum SeasonalSetting: String, Sendable {
    case automatic, off
}
