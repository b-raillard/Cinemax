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
    @AppStorage(SettingsKey.accentColor) private var _accentColorKey: String = SettingsKey.Default.accentColor

    var accentColorKey: String {
        get {
            _ = _accentRevision
            return _accentColorKey
        }
        set {
            _accentColorKey = newValue
            _accentRevision += 1
            startRainbowIfNeeded()
        }
    }

    @ObservationIgnored
    @AppStorage(SettingsKey.darkMode) private var _darkModeEnabled: Bool = SettingsKey.Default.darkMode

    var darkModeEnabled: Bool {
        get { _darkModeEnabled }
        set {
            _darkModeEnabled = newValue
            _accentRevision += 1
        }
    }

    @ObservationIgnored
    @AppStorage(SettingsKey.uiScale) private var _uiScale: Double = SettingsKey.Default.uiScale

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

    // MARK: - Rainbow Easter Egg
    //
    // When `accentColorKey == "rainbow"`, a Task on the main actor advances
    // `_rainbowHue` every ~33 ms and bumps `_accentRevision` so every view
    // observing ThemeManager re-evaluates `accent`/`accentContainer`/`accentDim`
    // against the new hue. The task self-exits as soon as the user switches to a
    // static accent, so there's zero cost outside of the easter-egg state.

    @ObservationIgnored private var _rainbowHue: Double = 0
    @ObservationIgnored private var rainbowTask: Task<Void, Never>?

    var isRainbow: Bool { accentColorKey == "rainbow" }

    init() {
        startRainbowIfNeeded()
    }

    deinit {
        rainbowTask?.cancel()
    }

    private func startRainbowIfNeeded() {
        rainbowTask?.cancel()
        rainbowTask = nil
        guard isRainbow else { return }
        rainbowTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard let self, self.isRainbow else { return }
                self._rainbowHue = (self._rainbowHue + 0.006).truncatingRemainder(dividingBy: 1.0)
                self._accentRevision += 1
            }
        }
    }

    // MARK: - Dynamic Accent Colors
    //
    // The palette for each accent lives on `AccentOption.palette` — single source of truth.
    // These computed properties just pick the right slice + wrap in `Color.dynamic`.
    // Rainbow mode bypasses the palette and returns HSB colors driven by `_rainbowHue`.

    /// Current palette. Falls back to green if `accentColorKey` is unrecognised (e.g. stale storage).
    private var palette: AccentOption.Palette {
        (AccentOption(rawValue: accentColorKey) ?? .green).palette
    }

    /// Accent "light" variant — used for text, icons, active indicators.
    /// Light-mode values are deeper/more saturated for ≥4.5:1 contrast on the soft-grey background.
    var accent: Color {
        _ = _accentRevision
        if isRainbow {
            return Color(hue: _rainbowHue, saturation: 0.85, brightness: 0.95)
        }
        let p = palette
        return Color.dynamic(light: p.accentLight, dark: p.accentDark)
    }

    /// Accent "container" — used for filled button backgrounds, selection highlights.
    /// Mid-tone saturated values work on both light and dark backgrounds.
    var accentContainer: Color {
        _ = _accentRevision
        if isRainbow {
            return Color(hue: _rainbowHue, saturation: 0.9, brightness: 0.88)
        }
        let p = palette
        return Color.dynamic(light: p.containerLight, dark: p.containerDark)
    }

    /// Dimmed accent — used for hover/pressed states of accent-colored UI.
    var accentDim: Color {
        _ = _accentRevision
        if isRainbow {
            return Color(hue: _rainbowHue, saturation: 0.75, brightness: 0.7)
        }
        let p = palette
        return Color.dynamic(light: p.dimLight, dark: p.dimDark)
    }

    /// On-accent — text/icon color placed on top of `accentContainer`.
    /// Always white in light mode (saturated containers host white); near-black in dark mode.
    var onAccent: Color {
        _ = _accentRevision
        if isRainbow {
            return .white
        }
        let p = palette
        return Color.dynamic(light: p.onAccentLight, dark: p.onAccentDark)
    }

    // MARK: - Color Scheme

    var colorScheme: ColorScheme? {
        _ = _accentRevision
        return darkModeEnabled ? .dark : .light
    }
}
