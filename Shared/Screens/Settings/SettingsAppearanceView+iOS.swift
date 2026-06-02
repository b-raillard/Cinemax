#if os(iOS)
import SwiftUI
import CinemaxKit

// MARK: - Appearance Detail View (iOS)

/// Standalone View struct so NavigationStack destination has its own `@Observable`
/// observation tracking for `ThemeManager` and `LocalizationManager`.
///
/// Extracted from `SettingsScreen+iOS.swift` to keep that file focused on layout
/// scaffolding. All rows here are Appearance-only (dark mode, accent, language).
struct IOSAppearanceDetailView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(LocalizationManager.self) var loc
    @Environment(\.motionEffectsEnabled) private var motionEffects
    @AppStorage(SettingsKey.rainbowUnlocked) private var rainbowUnlocked: Bool = SettingsKey.Default.rainbowUnlocked
    @AppStorage(SettingsKey.motionEffects) private var motionEffectsStorage: Bool = SettingsKey.Default.motionEffects
    @State private var fontScale: Double = UserDefaults.standard.object(forKey: SettingsKey.uiScale) as? Double ?? SettingsKey.Default.uiScale
    private let fontScaleOptions: [Double] = [0.80, 0.85, 0.90, 0.95, 1.00, 1.05, 1.10, 1.15, 1.20, 1.25, 1.30]

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            iOSSettingsSectionHeader(loc.localized("settings.personalization"))

            VStack(spacing: 0) {
                iOSSettingsRow {
                    HStack {
                        iOSRowIcon(systemName: themeManager.darkModeEnabled ? "moon.fill" : "sun.max.fill", color: themeManager.accent)

                        Text(themeManager.darkModeEnabled ? loc.localized("settings.darkMode") : loc.localized("settings.lightMode"))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurface)

                        Spacer()

                        Button { themeManager.darkModeEnabled.toggle() } label: {
                            CinemaToggleIndicator(isOn: themeManager.darkModeEnabled, accent: themeManager.accent, animated: motionEffects)
                        }
                        .buttonStyle(.plain)
                    }
                }

                iOSSettingsDivider

                iOSSettingsRow {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                        HStack {
                            iOSRowIcon(systemName: "paintpalette.fill", color: selectedAccent.color)

                            Text(loc.localized("settings.accentColor"))
                                .font(CinemaFont.label(.large))
                                .foregroundStyle(CinemaColor.onSurface)

                            Spacer()
                        }

                        HStack(spacing: CinemaSpacing.spacing2) {
                            ForEach(AccentOption.visibleCases(rainbowUnlocked: rainbowUnlocked)) { option in
                                accentDot(option)
                            }
                        }
                    }
                    .hoverEffectDisabled()
                }

                iOSSettingsDivider

                iOSSettingsRow {
                    HStack {
                        iOSRowIcon(systemName: "globe", color: themeManager.accent)

                        Text(loc.localized("settings.language"))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurface)

                        Spacer()

                        languagePicker
                    }
                }

                iOSSettingsDivider

                iOSSettingsRow {
                    HStack {
                        iOSRowIcon(systemName: "sparkles", color: themeManager.accent)

                        Text(loc.localized("settings.motionEffects"))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurface)

                        Spacer()

                        Button { motionEffectsStorage.toggle() } label: {
                            CinemaToggleIndicator(isOn: motionEffectsStorage, accent: themeManager.accent, animated: motionEffectsStorage)
                        }
                        .buttonStyle(.plain)
                        .sensoryFeedback(.selection, trigger: motionEffectsStorage)
                    }
                }

                iOSSettingsDivider

                iOSSettingsRow {
                    HStack {
                        iOSRowIcon(systemName: "textformat.size", color: themeManager.accent)
                        Text(loc.localized("settings.fontSize"))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurface)
                        Spacer()
                        Stepper(
                            "\(Int(fontScale * 100))%",
                            onIncrement: {
                                if let idx = fontScaleOptions.firstIndex(of: fontScale), idx < fontScaleOptions.count - 1 {
                                    fontScale = fontScaleOptions[idx + 1]
                                    themeManager.uiScale = fontScale
                                }
                            },
                            onDecrement: {
                                if let idx = fontScaleOptions.firstIndex(of: fontScale), idx > 0 {
                                    fontScale = fontScaleOptions[idx - 1]
                                    themeManager.uiScale = fontScale
                                }
                            }
                        )
                        .fixedSize()
                        .tint(themeManager.accent)
                    }
                }
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        }
    }

    // MARK: - Appearance-specific helpers

    var selectedAccent: AccentOption {
        AccentOption(rawValue: themeManager.accentColorKey) ?? .green
    }

    var languagePicker: some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            languageButton("fr", label: "FR")
            languageButton("en", label: "EN")
        }
    }

    func languageButton(_ code: String, label: String) -> some View {
        let isSelected = loc.languageCode == code
        return Button {
            loc.languageCode = code
        } label: {
            Text(label)
                .font(.system(size: CinemaScale.pt(17), weight: .bold))
                .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurfaceVariant)
                .frame(width: 40, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: CinemaRadius.medium)
                        .fill(isSelected ? themeManager.accent : CinemaColor.surfaceContainerHigh)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    func accentDot(_ option: AccentOption) -> some View {
        let isSelected = option.rawValue == themeManager.accentColorKey

        Button {
            themeManager.accentColorKey = option.rawValue
        } label: {
            ZStack {
                if option == .rainbow {
                    RainbowAccentSwatch(diameter: 28)
                } else {
                    Circle()
                        .fill(option.color)
                        .frame(width: 28, height: 28)
                }

                if isSelected {
                    Circle()
                        .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                        .frame(width: 28, height: 28)

                    Image(systemName: "checkmark")
                        .font(.system(size: CinemaScale.pt(13), weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverEffectDisabled()
        .scaleEffect(isSelected ? 1.1 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }
}
#endif
