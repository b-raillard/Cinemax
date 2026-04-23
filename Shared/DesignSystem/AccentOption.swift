import SwiftUI

// MARK: - Accent Color Definition

/// Single source of truth for the accent palette. Each case carries a full `Palette`
/// (accent / container / dim / onAccent × light+dark). `ThemeManager` reads these
/// values — adding a new accent means adding one case + one `Palette` entry here.
///
/// Order of cases follows the natural spectrum (rainbow) so the picker reads left-to-right.
enum AccentOption: String, CaseIterable, Identifiable {
    case red    = "red"
    case orange = "orange"
    case yellow = "yellow"
    case green  = "green"
    case cyan   = "cyan"
    case blue   = "blue"
    case indigo = "indigo"
    case purple = "purple"
    case pink   = "pink"
    /// Easter egg accent — hidden from the picker until unlocked via the Server/Login
    /// logo tap sequence. When active, `ThemeManager` ignores the palette below and
    /// drives `accent`/`accentContainer`/`accentDim` from an animated HSB hue phase.
    case rainbow = "rainbow"

    var id: String { rawValue }

    /// Cases visible in the accent picker. Rainbow is filtered out unless the user
    /// has unlocked it via the easter egg.
    static func visibleCases(rainbowUnlocked: Bool) -> [AccentOption] {
        rainbowUnlocked ? allCases : allCases.filter { $0 != .rainbow }
    }

    /// The nine base accents the easter egg cycles through.
    static var cyclingCases: [AccentOption] {
        allCases.filter { $0 != .rainbow }
    }

    struct Palette {
        let accentLight: UInt
        let accentDark: UInt
        let containerLight: UInt
        let containerDark: UInt
        let dimLight: UInt
        let dimDark: UInt
        let onAccentLight: UInt
        let onAccentDark: UInt
    }

    var palette: Palette {
        switch self {
        case .red:    Palette(accentLight: 0xC1272D, accentDark: 0xFF6B6B,
                              containerLight: 0xE53935, containerDark: 0xE53935,
                              dimLight: 0x8C1C20, dimDark: 0xCC2C30,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x3D0000)
        case .orange: Palette(accentLight: 0xCC5A0A, accentDark: 0xFF8C42,
                              containerLight: 0xE06A1A, containerDark: 0xE06A1A,
                              dimLight: 0xA84508, dimDark: 0xCC5500,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x3D1500)
        case .yellow: Palette(accentLight: 0x8A5A00, accentDark: 0xFFC940,
                              containerLight: 0xD19500, containerDark: 0xD19500,
                              dimLight: 0x6B4500, dimDark: 0xB37B00,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x2B1F00)
        case .green:  Palette(accentLight: 0x1F7A50, accentDark: 0x4CAF82,
                              containerLight: 0x2E8A5E, containerDark: 0x2E8A5E,
                              dimLight: 0x155F3E, dimDark: 0x1F7A50,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x001A0D)
        case .cyan:   Palette(accentLight: 0x0E8F84, accentDark: 0x2DD4BF,
                              containerLight: 0x0BAEA0, containerDark: 0x0BAEA0,
                              dimLight: 0x08756B, dimDark: 0x009A8C,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x001A18)
        case .blue:   Palette(accentLight: 0x0060D6, accentDark: 0x679CFF,
                              containerLight: 0x007AFF, containerDark: 0x007AFF,
                              dimLight: 0x0050B8, dimDark: 0x0070EB,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x001F4A)
        case .indigo: Palette(accentLight: 0x3730A3, accentDark: 0x818CF8,
                              containerLight: 0x4F46E5, containerDark: 0x4F46E5,
                              dimLight: 0x262183, dimDark: 0x3B3FB5,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x0A0A2B)
        case .purple: Palette(accentLight: 0x7A2BD0, accentDark: 0xBF7FFF,
                              containerLight: 0x8E3CE0, containerDark: 0x9B57E0,
                              dimLight: 0x651FB0, dimDark: 0x8B44CF,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x1A0040)
        case .pink:   Palette(accentLight: 0xC2185B, accentDark: 0xFF6BB5,
                              containerLight: 0xD63384, containerDark: 0xE0458F,
                              dimLight: 0xA0144A, dimDark: 0xCC3578,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x3D001A)
        // Rainbow Palette values are inert — `ThemeManager` checks `isRainbow`
        // first and returns HSB colors driven by `_rainbowHue`. The hex values
        // below satisfy the non-optional `palette` type but are never read.
        case .rainbow: Palette(accentLight: 0x6B46C1, accentDark: 0xA78BFA,
                               containerLight: 0x7C3AED, containerDark: 0x8B5CF6,
                               dimLight: 0x5B21B6, dimDark: 0x7C3AED,
                               onAccentLight: 0xFFFFFF, onAccentDark: 0x1A0040)
        }
    }

    /// Preview swatch — resolves against the active trait collection so the dot
    /// matches the live accent in both light and dark mode.
    var color: Color { Color.dynamic(light: palette.accentLight, dark: palette.accentDark) }
}

// MARK: - Accent Easter Egg

/// Pure resolver that powers the logo-tap easter egg on `ServerSetupScreen` and
/// `LoginScreen`. Each tap advances the accent through `AccentOption.cyclingCases`;
/// after a full loop during the session the rainbow accent is unlocked + applied.
/// Once unlocked it stays available in the settings picker forever.
///
/// The resolver is pure (no state mutation) so callers can bind directly to `@State`
/// and `@AppStorage` without wrestling with inout on property-wrapper-backed values.
enum AccentEasterEgg {
    struct TapResult {
        /// Accent key to apply after this tap.
        let nextAccentKey: String
        /// `true` when this tap completed the loop and rainbow should become unlocked.
        let unlockedRainbow: Bool
    }

    static func tap(
        currentAccentKey: String,
        previousTapCount: Int,
        rainbowAlreadyUnlocked: Bool
    ) -> TapResult {
        let cycle = AccentOption.cyclingCases
        let nextTapCount = previousTapCount + 1

        if nextTapCount >= cycle.count, !rainbowAlreadyUnlocked {
            return TapResult(nextAccentKey: AccentOption.rainbow.rawValue, unlockedRainbow: true)
        }

        if let idx = cycle.firstIndex(where: { $0.rawValue == currentAccentKey }) {
            return TapResult(nextAccentKey: cycle[(idx + 1) % cycle.count].rawValue, unlockedRainbow: false)
        }
        // Currently on rainbow (already unlocked) — jump back to start of cycle.
        return TapResult(nextAccentKey: cycle.first?.rawValue ?? "green", unlockedRainbow: false)
    }
}
