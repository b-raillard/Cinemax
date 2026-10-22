import SwiftUI

#if os(tvOS)

// MARK: - tvOS App Icon Picker (lot D)

extension SettingsScreen {
    /// « Icône de l'app » — one row like the seasonal picker: a press moves to
    /// the next icon, Left / Right step either way, wrapping. Each step SWITCHES
    /// the icon (`setAlternateIconName`), so the chip lit is always the icon
    /// the Apple TV shows. An alternate icon is the Pro's: locked, its chip
    /// wears a lock and reaching it raises the Pro sheet
    /// (`ProFeatureAccess.admit(.appIcons)`) without switching — the free user
    /// stays on the icon they have (`AppIconPickerPolicy`). Hidden when the
    /// system has no alternate icons (`supportsAlternateIcons`).
    @ViewBuilder
    var tvAppIconPicker: some View {
        if AppIconSwitcher.isSupported {
            tvAppIconRow
        }
    }

    private var tvAppIconRow: some View {
        let isFocused = focusedItem == .toggle("appIcon")
        let tier = proAccess?.currentTier() ?? .founder
        let current = AppIconCatalogue.choice(alternateName: appIconName)

        return Button {
            tvStepAppIcon(by: 1)
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "app.badge")
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 24)

                Text(loc.localized("settings.appIcon.title"))
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)

                Spacer()

                // Thirteen icons since 2026-10-22: the chips scroll to the
                // current one until the picker's redesign (mockups pending).
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: CinemaSpacing.spacing4) {
                            ForEach(AppIconCatalogue.choices) { choice in
                                tvAppIconChip(
                                    choice,
                                    isSelected: choice == current,
                                    isLocked: choice != current && AppIconPickerPolicy.isLocked(choice, tier: tier)
                                )
                                .id(choice.id)
                            }
                        }
                        .padding(.vertical, CinemaSpacing.spacing2)
                    }
                    .frame(maxWidth: 760)
                    .onChange(of: appIconName, initial: true) { _, name in
                        if let id = AppIconCatalogue.choice(alternateName: name)?.id {
                            proxy.scrollTo(id, anchor: .center)
                        }
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
        // One element: « Icône de l'app, Classique ».
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc.localized("settings.appIcon.title"))
        .accessibilityValue(current.map { loc.localized($0.labelKey) } ?? "")
        .focused($focusedItem, equals: .toggle("appIcon"))
        .onMoveCommand { direction in
            guard isFocused else { return }
            switch direction {
            case .left: tvStepAppIcon(by: -1)
            case .right: tvStepAppIcon(by: 1)
            default: break
            }
        }
        .onAppear { appIconName = AppIconSwitcher.currentName }
    }

    func tvStepAppIcon(by step: Int) {
        let target = AppIconCatalogue.neighbour(of: appIconName, by: step)
        switch AppIconPickerPolicy.outcome(choosing: target, current: appIconName, tier: proAccess?.currentTier() ?? .founder) {
        case .keep:
            return
        case .upsell:
            proAccess?.admit(.appIcons)
        case .apply(let name):
            Task {
                do {
                    try await AppIconSwitcher.set(name)
                } catch {
                    toasts.error(loc.localized("settings.appIcon.error"))
                }
                appIconName = AppIconSwitcher.currentName
            }
        }
    }

    private func tvAppIconChip(_ choice: AppIconChoice, isSelected: Bool, isLocked: Bool) -> some View {
        VStack(spacing: CinemaSpacing.spacing1) {
            // The thumbnail is the icon's back + front, as the Home screen
            // shows it (`recolor.py --alternates`, 400 × 240 @2x).
            Image(choice.previewImage)
                .resizable()
                .aspectRatio(5 / 3, contentMode: .fit)
                .frame(width: 100)
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium, style: .continuous))
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: CinemaRadius.medium + 3, style: .continuous)
                        .strokeBorder(isSelected ? themeManager.accent : .clear, lineWidth: 3)
                }
            HStack(spacing: CinemaSpacing.spacing1) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: CinemaScale.pt(14), weight: .bold))
                }
                Text(loc.localized(choice.labelKey))
                    .font(.system(size: CinemaScale.pt(18), weight: isSelected ? .bold : .medium))
            }
            .foregroundStyle(isSelected ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
        }
    }
}

#endif
