import SwiftUI

// MARK: - Theme Manager
//
// Single source of truth for dynamic theming: accent color and dark/light mode.
// Injected as an @Observable into the environment from AppNavigation.
// All screens that previously used CinemaColor.tertiary / tertiaryContainer /
// tertiaryDim / onTertiary should read from ThemeManager instead.

@MainActor @Observable
final class ThemeManager {

    // MARK: - Persisted Properties

    @ObservationIgnored
    @AppStorage("accentColor") var accentColorKey: String = "blue"

    @ObservationIgnored
    @AppStorage("darkMode") var darkModeEnabled: Bool = true

    // MARK: - Dynamic Accent Colors

    /// Accent "light" variant — used for text, icons, active indicators.
    var accent: Color {
        switch accentColorKey {
        case "purple": Color(hex: 0xBF7FFF)
        case "pink":   Color(hex: 0xFF6BB5)
        case "orange": Color(hex: 0xFF8C42)
        case "green":  Color(hex: 0x4CAF82)
        case "cyan":   Color(hex: 0x2DD4BF)
        default:       Color(hex: 0x679CFF) // blue
        }
    }

    /// Accent "container" — used for filled button backgrounds, selection highlights.
    /// Slightly deeper / more saturated than `accent`.
    var accentContainer: Color {
        switch accentColorKey {
        case "purple": Color(hex: 0x9B57E0)
        case "pink":   Color(hex: 0xE0458F)
        case "orange": Color(hex: 0xE06A1A)
        case "green":  Color(hex: 0x2E8A5E)
        case "cyan":   Color(hex: 0x0BAEA0)
        default:       Color(hex: 0x007AFF) // blue
        }
    }

    /// Dimmed accent — used for hover/pressed states of accent-colored UI.
    var accentDim: Color {
        switch accentColorKey {
        case "purple": Color(hex: 0x8B44CF)
        case "pink":   Color(hex: 0xCC3578)
        case "orange": Color(hex: 0xCC5500)
        case "green":  Color(hex: 0x1F7A50)
        case "cyan":   Color(hex: 0x009A8C)
        default:       Color(hex: 0x0070EB) // blue
        }
    }

    /// On-accent — text/icon color placed on top of `accentContainer`.
    var onAccent: Color {
        switch accentColorKey {
        case "purple": Color(hex: 0x1A0040)
        case "pink":   Color(hex: 0x3D001A)
        case "orange": Color(hex: 0x3D1500)
        case "green":  Color(hex: 0x001A0D)
        case "cyan":   Color(hex: 0x001A18)
        default:       Color(hex: 0x001F4A) // blue
        }
    }

    // MARK: - Color Scheme

    var colorScheme: ColorScheme? {
        darkModeEnabled ? .dark : .light
    }
}
