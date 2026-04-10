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
    @AppStorage("accentColor") private var _accentColorKey: String = "blue"

    var accentColorKey: String {
        get {
            _ = _accentRevision
            return _accentColorKey
        }
        set {
            _accentColorKey = newValue
            _accentRevision += 1
        }
    }

    @ObservationIgnored
    @AppStorage("darkMode") private var _darkModeEnabled: Bool = true

    var darkModeEnabled: Bool {
        get { _darkModeEnabled }
        set {
            _darkModeEnabled = newValue
            _accentRevision += 1
        }
    }

    @ObservationIgnored
    @AppStorage("uiScale") private var _uiScale: Double = 1.0

    /// Global UI text scale factor (0.8 – 1.4). Changing this re-renders all views.
    var uiScale: Double {
        get { _uiScale }
        set {
            _uiScale = min(1.4, max(0.8, newValue))
            _accentRevision += 1
        }
    }

    /// Tracked revision counter — triggers SwiftUI updates when AppStorage values change.
    private var _accentRevision: Int = 0

    // MARK: - Dynamic Accent Colors

    /// Accent "light" variant — used for text, icons, active indicators.
    /// Light-mode values are deeper/more saturated for ≥4.5:1 contrast on the soft-grey background.
    var accent: Color {
        _ = _accentRevision
        return switch accentColorKey {
        case "purple": Color.dynamic(light: 0x7A2BD0, dark: 0xBF7FFF)
        case "pink":   Color.dynamic(light: 0xC2185B, dark: 0xFF6BB5)
        case "orange": Color.dynamic(light: 0xCC5A0A, dark: 0xFF8C42)
        case "green":  Color.dynamic(light: 0x1F7A50, dark: 0x4CAF82)
        case "cyan":   Color.dynamic(light: 0x0E8F84, dark: 0x2DD4BF)
        default:       Color.dynamic(light: 0x0060D6, dark: 0x679CFF) // blue
        }
    }

    /// Accent "container" — used for filled button backgrounds, selection highlights.
    /// Mid-tone saturated values work on both light and dark backgrounds.
    var accentContainer: Color {
        _ = _accentRevision
        return switch accentColorKey {
        case "purple": Color.dynamic(light: 0x8E3CE0, dark: 0x9B57E0)
        case "pink":   Color.dynamic(light: 0xD63384, dark: 0xE0458F)
        case "orange": Color.dynamic(light: 0xE06A1A, dark: 0xE06A1A)
        case "green":  Color.dynamic(light: 0x2E8A5E, dark: 0x2E8A5E)
        case "cyan":   Color.dynamic(light: 0x0BAEA0, dark: 0x0BAEA0)
        default:       Color.dynamic(light: 0x007AFF, dark: 0x007AFF) // blue
        }
    }

    /// Dimmed accent — used for hover/pressed states of accent-colored UI.
    var accentDim: Color {
        _ = _accentRevision
        return switch accentColorKey {
        case "purple": Color.dynamic(light: 0x651FB0, dark: 0x8B44CF)
        case "pink":   Color.dynamic(light: 0xA0144A, dark: 0xCC3578)
        case "orange": Color.dynamic(light: 0xA84508, dark: 0xCC5500)
        case "green":  Color.dynamic(light: 0x155F3E, dark: 0x1F7A50)
        case "cyan":   Color.dynamic(light: 0x08756B, dark: 0x009A8C)
        default:       Color.dynamic(light: 0x0050B8, dark: 0x0070EB) // blue
        }
    }

    /// On-accent — text/icon color placed on top of `accentContainer`.
    /// Always white in light mode (saturated containers host white); near-black in dark mode.
    var onAccent: Color {
        _ = _accentRevision
        return switch accentColorKey {
        case "purple": Color.dynamic(light: 0xFFFFFF, dark: 0x1A0040)
        case "pink":   Color.dynamic(light: 0xFFFFFF, dark: 0x3D001A)
        case "orange": Color.dynamic(light: 0xFFFFFF, dark: 0x3D1500)
        case "green":  Color.dynamic(light: 0xFFFFFF, dark: 0x001A0D)
        case "cyan":   Color.dynamic(light: 0xFFFFFF, dark: 0x001A18)
        default:       Color.dynamic(light: 0xFFFFFF, dark: 0x001F4A) // blue
        }
    }

    // MARK: - Color Scheme

    var colorScheme: ColorScheme? {
        _ = _accentRevision
        return darkModeEnabled ? .dark : .light
    }
}
