import SwiftUI

#if os(tvOS)

// MARK: - tvOS Seasonal Theme Picker (lot C)

extension SettingsScreen {
    /// Automatique / Désactivé / Halloween — one row like the language
    /// picker: a press moves to the next choice, Left / Right step either
    /// way, wrapping. The chip lit is the EFFECTIVE choice (a forced Halloween
    /// the tier refuses reads Automatique). Halloween at any date is the
    /// Pro's: locked, its chip wears a lock, and reaching it raises the Pro
    /// sheet (`ProFeatureAccess.admit`) while the selection STAYS where it
    /// was (`SeasonalSetting.stepped`) — nothing is written the user did not
    /// choose; the other direction still reaches every free choice.
    var tvSeasonalPicker: some View {
        let isFocused = focusedItem == .toggle("seasonalTheme")
        let selected = seasonal.effectiveSetting
        let forcedLocked = proAccess?.allows(.seasonalAllYear) == false

        return Button {
            tvStepSeasonal(by: 1)
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "calendar")
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                    Text(loc.localized("settings.seasonal.toggle"))
                        .font(.system(size: CinemaScale.pt(20), weight: .medium))
                        .foregroundStyle(CinemaColor.onSurface)
                    Text(SeasonalSettingsText.catalogueSummary(loc: loc))
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, CinemaSpacing.spacing2)

                Spacer()

                HStack(spacing: CinemaSpacing.spacing2) {
                    ForEach(SeasonalSetting.choices, id: \.self) { choice in
                        tvSeasonalChip(
                            choice,
                            isSelected: choice == selected,
                            isLocked: choice.forcedSeasonID != nil && forcedLocked
                        )
                    }
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, animated: motionEffects, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        // One element: « Thème éphémère, Automatique ».
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc.localized("settings.seasonal.toggle"))
        .accessibilityValue(loc.localized(selected.labelKey))
        .accessibilityHint(SeasonalSettingsText.catalogueSummary(loc: loc))
        .focused($focusedItem, equals: .toggle("seasonalTheme"))
        .onMoveCommand { direction in
            guard isFocused else { return }
            switch direction {
            case .left: tvStepSeasonal(by: -1)
            case .right: tvStepSeasonal(by: 1)
            default: break
            }
        }
    }

    func tvStepSeasonal(by step: Int) {
        let next = seasonal.effectiveSetting.stepped(by: step) { choice in
            choice.forcedSeasonID == nil || proAccess?.admit(.seasonalAllYear) != false
        }
        seasonal.setSetting(next)
    }

    func tvSeasonalChip(_ choice: SeasonalSetting, isSelected: Bool, isLocked: Bool) -> some View {
        HStack(spacing: CinemaSpacing.spacing1) {
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: CinemaScale.pt(14), weight: .bold))
            }
            Text(loc.localized(choice.labelKey))
                .font(.system(size: CinemaScale.pt(20), weight: isSelected ? .bold : .medium))
        }
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
