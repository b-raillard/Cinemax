import SwiftUI

// MARK: - iOS Settings Row Helpers
//
// Shared layout helpers used by SettingsScreen and IOSAppearanceDetailView on iOS.
// Extracted to avoid duplication between the main screen and pushed detail views.

#if os(iOS)

/// Standard padded row container for settings cells.
@ViewBuilder
func iOSSettingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
        .padding(.horizontal, CinemaSpacing.spacing4)
        .padding(.vertical, CinemaSpacing.spacing3)
}

/// Colored icon badge used as the leading element of a settings row.
@ViewBuilder
func iOSRowIcon(systemName: String, color: Color) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: CinemaRadius.small)
            .fill(color.opacity(0.12))
            .frame(width: 32, height: 32)

        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color)
    }
    .padding(.trailing, CinemaSpacing.spacing2)
}

/// Thin divider inset to align with row text (past the icon).
var iOSSettingsDivider: some View {
    Rectangle()
        .fill(CinemaColor.surfaceContainerHighest.opacity(0.6))
        .frame(height: 1)
        .padding(.leading, CinemaSpacing.spacing4 + 32 + CinemaSpacing.spacing2)
}

/// Uppercase section header label.
func iOSSettingsSectionHeader(_ title: String) -> some View {
    Text(title.uppercased())
        .font(CinemaFont.label(.small))
        .foregroundStyle(CinemaColor.onSurfaceVariant)
        .tracking(1.2)
        .padding(.horizontal, CinemaSpacing.spacing2)
}

/// Toggle row matching the iOS settings pattern: icon + label + CinemaToggleIndicator.
/// Equivalent to tvOS's `tvGlassToggle` — one call per boolean setting.
@ViewBuilder
func iOSToggleRow(
    icon: String,
    label: String,
    value: Binding<Bool>,
    accent: Color,
    animated: Bool
) -> some View {
    iOSSettingsRow {
        HStack {
            iOSRowIcon(systemName: icon, color: accent)
            Text(label)
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurface)
            Spacer()
            Button { value.wrappedValue.toggle() } label: {
                CinemaToggleIndicator(isOn: value.wrappedValue, accent: accent, animated: animated)
            }
            .buttonStyle(.plain)
        }
    }
}

#endif
