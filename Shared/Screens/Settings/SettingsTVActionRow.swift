import SwiftUI

#if os(tvOS)

// MARK: - tvOS Action Row (shared helper)
//
// Single source of truth for "tappable row with icon + title + optional
// subtitle + optional chevron" on tvOS. Replaces three near-duplicate
// bespoke buttons (Refresh Catalogue / Refresh Connection / Licenses).
//
// Two overloads let callers either reuse the generic `.toggle(id)` focus
// lane (used for most settings rows) or supply a dedicated `SettingsFocus`
// case where one already exists (e.g. `.refreshConnection`).

extension SettingsScreen {

    @ViewBuilder
    func tvActionRow(
        id: String,
        icon: String,
        label: String,
        subtitle: String? = nil,
        showsChevron: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        tvActionRow(
            focus: .toggle(id),
            icon: icon,
            label: label,
            subtitle: subtitle,
            showsChevron: showsChevron,
            tint: tint,
            action: action
        )
    }

    @ViewBuilder
    func tvActionRow(
        focus: SettingsFocus,
        icon: String,
        label: String,
        subtitle: String? = nil,
        showsChevron: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focusedItem == focus
        let iconColor = tint ?? themeManager.accent
        let labelColor = tint ?? CinemaColor.onSurface
        Button(action: action) {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: icon)
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 24)

                if let subtitle {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label)
                            .font(.system(size: CinemaScale.pt(20), weight: .medium))
                            .foregroundStyle(labelColor)
                        Text(subtitle)
                            .font(.system(size: CinemaScale.pt(16), weight: .regular))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }
                } else {
                    Text(label)
                        .font(.system(size: CinemaScale.pt(20), weight: .medium))
                        .foregroundStyle(labelColor)
                }

                Spacer()

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: focus)
    }
}

#endif
