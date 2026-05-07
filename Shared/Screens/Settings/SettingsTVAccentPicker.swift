import SwiftUI

#if os(tvOS)

// MARK: - tvOS Accent Color Picker

extension SettingsScreen {

    var tvAccentColorPicker: some View {
        let isFocused = focusedItem == .accentColor("row")
        let allOptions = AccentOption.visibleCases(rainbowUnlocked: rainbowUnlocked)

        return Button {
            // Cycle to next accent color on press
            if let currentIndex = allOptions.firstIndex(where: { $0.rawValue == themeManager.accentColorKey }) {
                let nextIndex = (allOptions.distance(from: allOptions.startIndex, to: currentIndex) + 1) % allOptions.count
                themeManager.accentColorKey = allOptions[allOptions.index(allOptions.startIndex, offsetBy: nextIndex)].rawValue
            }
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 24)

                Text(loc.localized("settings.accentColor"))
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)

                Spacer()

                HStack(spacing: CinemaSpacing.spacing3) {
                    ForEach(allOptions) { option in
                        tvAccentDotDisplay(option)
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
        .focused($focusedItem, equals: .accentColor("row"))
        .onMoveCommand { direction in
            guard isFocused else { return }
            let allOpts = AccentOption.visibleCases(rainbowUnlocked: rainbowUnlocked)
            if let currentIndex = allOpts.firstIndex(where: { $0.rawValue == themeManager.accentColorKey }) {
                let idx = allOpts.distance(from: allOpts.startIndex, to: currentIndex)
                switch direction {
                case .left:
                    if idx > 0 {
                        themeManager.accentColorKey = allOpts[allOpts.index(allOpts.startIndex, offsetBy: idx - 1)].rawValue
                    }
                case .right:
                    if idx < allOpts.count - 1 {
                        themeManager.accentColorKey = allOpts[allOpts.index(allOpts.startIndex, offsetBy: idx + 1)].rawValue
                    }
                default:
                    break
                }
            }
        }
    }

    func tvAccentDotDisplay(_ option: AccentOption) -> some View {
        let isSelected = option.rawValue == themeManager.accentColorKey

        return ZStack {
            if option == .rainbow {
                RainbowAccentSwatch(diameter: 36)
            } else {
                Circle()
                    .fill(option.color)
                    .frame(width: 36, height: 36)
            }

            if isSelected {
                Circle()
                    .strokeBorder(.white.opacity(0.9), lineWidth: 2.5)
                    .frame(width: 36, height: 36)

                Image(systemName: "checkmark")
                    .font(.system(size: CinemaScale.pt(14), weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 48, height: 48)
    }
}

#endif
