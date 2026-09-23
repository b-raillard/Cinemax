import SwiftUI

#if os(tvOS)

// MARK: - tvOS Language Picker

extension SettingsScreen {

    var tvLanguagePicker: some View {
        let isFocused = focusedItem == .language("row")

        return Button {
            // Toggle between languages on press
            loc.languageCode = loc.languageCode == "fr" ? "en" : "fr"
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "globe")
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 24)

                Text(loc.localized("settings.language"))
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)

                Spacer()

                HStack(spacing: CinemaSpacing.spacing2) {
                    tvLanguageChip("fr", label: loc.localized("settings.language.french"))
                    tvLanguageChip("en", label: loc.localized("settings.language.english"))
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, animated: motionEffects, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        // Both chips' labels would otherwise be read with nothing saying which
        // one is on: the row reads as « Langue, Français ».
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc.localized("settings.language"))
        .accessibilityValue(loc.localized(loc.languageCode == "fr" ? "settings.language.french" : "settings.language.english"))
        .focused($focusedItem, equals: .language("row"))
        .onMoveCommand { direction in
            guard isFocused else { return }
            switch direction {
            case .left, .right:
                loc.languageCode = loc.languageCode == "fr" ? "en" : "fr"
            default:
                break
            }
        }
    }

    func tvLanguageChip(_ code: String, label: String) -> some View {
        let isSelected = loc.languageCode == code

        return Text(label)
            .font(.system(size: CinemaScale.pt(20), weight: isSelected ? .bold : .medium))
            .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurfaceVariant)
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing2)
            .background(
                RoundedRectangle(cornerRadius: CinemaRadius.medium)
                    .fill(isSelected ? themeManager.accent : CinemaColor.surfaceContainerHigh)
            )
    }
}

#endif
