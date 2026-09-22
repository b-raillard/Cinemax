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

    /// The key of the accent's localized name (`accent.name.<rawValue>`), read
    /// by VoiceOver on the picker's swatches — a colour dot says nothing to it.
    var nameKey: String { "accent.name.\(rawValue)" }
}

// MARK: - Label contrast on accent fills

/// Which label colour sits on an `accentContainer` fill.
///
/// Every accent CTA used to carry a WHITE label, which is 2.62:1 on yellow,
/// 2.77:1 on cyan and 3.36:1 on orange — under the 3:1 floor WCAG sets even
/// for large text on the first two, on « Lecture » and « Connexion » (audit
/// 2026-09-22, U4). Pure and numeric rather than a per-case list, so the
/// rainbow accent — whose hue sweeps through yellow and cyan — gets the same
/// answer as the static palette.
enum AccentLabelContrast {
    /// Near-black label, the same weight as `CinemaColor.onSurface` in light mode.
    static let darkLabel: UInt = 0x1A1A1A
    /// White stays unless it drops under this ratio: the saturated reds,
    /// greens and blues sit at 4.0–4.3:1 and keep the design's white CTA.
    static let whiteFloor: Double = 3.5

    static func prefersDarkLabel(red: Double, green: Double, blue: Double) -> Bool {
        let fill = luminance(red: red, green: green, blue: blue)
        let white = contrast(1.0, fill)
        guard white < whiteFloor else { return false }
        let dark = contrast(luminance(hex: darkLabel), fill)
        return dark > white
    }

    static func prefersDarkLabel(hex: UInt) -> Bool {
        let (r, g, b) = components(hex)
        return prefersDarkLabel(red: r, green: g, blue: b)
    }

    /// WCAG 2.x contrast ratio between two relative luminances.
    static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func luminance(hex: UInt) -> Double {
        let (r, g, b) = components(hex)
        return luminance(red: r, green: g, blue: b)
    }

    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    private static func components(_ hex: UInt) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
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
