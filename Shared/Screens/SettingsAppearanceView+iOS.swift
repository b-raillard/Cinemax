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
