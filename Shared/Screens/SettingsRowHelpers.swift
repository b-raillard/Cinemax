import SwiftUI

// MARK: - Shared Settings Row Data

/// Descriptor for a boolean-toggle settings row shared across iOS and tvOS.
/// Lets us declare the icon / label / binding triple for each user-facing
/// preference in one place (computed on `SettingsScreen`) and render it through
/// the two platform-specific helpers below without duplicating the list.
///
/// `id` doubles as the tvOS `SettingsFocus.toggle` key — it must be stable
/// across renders so `@FocusState` keeps the right row focused when the
/// binding changes. `tint` is honored by the iOS renderer (icon color) and
/// ignored by the tvOS renderer, which always uses `themeManager.accent` —
/// preserving the current Debug-section asymmetry (orange on iOS, accent on tvOS).
struct SettingsToggleRow: Identifiable {
    let id: String
    let icon: String
    let label: String
    let value: Binding<Bool>
    let tint: Color?

    init(id: String, icon: String, label: String, value: Binding<Bool>, tint: Color? = nil) {
        self.id = id
        self.icon = icon
        self.label = label
        self.value = value
        self.tint = tint
    }
}

// MARK: - Server Status Badge (shared)

/// Green-dot + uppercase-label capsule used on the Server detail page to convey
/// connection state. iOS shows "LIVE" at 13pt; tvOS shows "CONNECTED" at 14pt.
/// Both sides previously inlined nearly-identical HStacks — this collapses that
/// duplication while keeping each platform's label copy and size.
@ViewBuilder
func serverStatusBadge(label: String, fontSize: Double, dotSize: CGFloat = 6) -> some View {
    HStack(spacing: dotSize - 1) {
        Circle()
            .fill(CinemaColor.success)
            .frame(width: dotSize, height: dotSize)
        Text(label)
            .font(.system(size: CinemaScale.pt(fontSize), weight: .bold))
            .tracking(0.5)
            .foregroundStyle(CinemaColor.success)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Capsule().fill(CinemaColor.success.opacity(0.12)))
}

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
///
/// `@MainActor` is required because the helper touches `PrimitiveButtonStyle.plain`,
/// which is main-actor isolated under Swift 6 strict concurrency. Without it the
/// compiler raises "Main actor-isolated static property 'plain' can not be referenced
/// from a nonisolated context".
@MainActor
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
                .font(CinemaFont.dynamicLabel(.large))
                .foregroundStyle(CinemaColor.onSurface)
            Spacer()
            Button { value.wrappedValue.toggle() } label: {
                CinemaToggleIndicator(isOn: value.wrappedValue, accent: accent, animated: animated)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Renders a list of `SettingsToggleRow` as iOS toggle rows separated by
/// `iOSSettingsDivider`. Caller is responsible for wrapping in a `glassPanel`
/// and for appending any non-toggle rows (sleep timer, font size, etc.) —
/// this keeps the helper compatible with mixed-row sections.
@MainActor
@ViewBuilder
func iOSToggleRowsJoined(_ rows: [SettingsToggleRow], accent: Color, animated: Bool) -> some View {
    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
        iOSToggleRow(
            icon: row.icon,
            label: row.label,
            value: row.value,
            accent: row.tint ?? accent,
            animated: animated
        )
        if index < rows.count - 1 {
            iOSSettingsDivider
        }
    }
}

#endif
