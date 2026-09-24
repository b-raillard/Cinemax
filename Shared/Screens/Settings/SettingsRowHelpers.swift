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
@MainActor
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
///
/// The row carries a rectangular `contentShape` covering its padding, because
/// a `Button` / `NavigationLink` only takes touches where its label DRAWS —
/// and neither a `Spacer` nor padding draws anything, so a tappable row whose
/// label is this container used to answer on its icon, text and chevron only
/// (Image Patterns RULE). A tappable row must therefore put this container
/// INSIDE its label (`Button { … } label: { iOSSettingsRow { … } }`), never the
/// other way round: a button nested inside it gains nothing from the shape.
@MainActor
@ViewBuilder
func iOSSettingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
        .padding(.horizontal, CinemaSpacing.spacing4)
        .padding(.vertical, CinemaSpacing.spacing3)
        .contentShape(Rectangle())
}

/// Colored icon badge used as the leading element of a settings row.
@MainActor
@ViewBuilder
func iOSRowIcon(systemName: String, color: Color) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: CinemaRadius.small)
            .fill(color.opacity(0.12))
            .frame(width: 32, height: 32)

        Image(systemName: systemName)
            .font(.system(size: CinemaScale.pt(14), weight: .semibold))
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
@MainActor
func iOSSettingsSectionHeader(_ title: String) -> some View {
    Text(title.uppercased())
        .font(CinemaFont.dynamicLabel(.small))
        .foregroundStyle(CinemaColor.onSurfaceVariant)
        .tracking(1.2)
        .padding(.horizontal, CinemaSpacing.spacing2)
        // A header for VoiceOver's rotor, read in its natural case rather than
        // as the upper-cased display string.
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
}

/// A settings row's label and its control: side by side normally, the control
/// UNDER the label at the accessibility text sizes. Side by side, a control of
/// fixed width (a toggle, a stepper whose « 100% » grows with the text, the
/// FR / EN pills) left the label a sliver and it broke mid-word — « Tail/le/du/
/// tex/te », « mouvem/ent » (recette 2026-09-23). A view rather than a check in
/// each helper because the row helpers are free functions with no environment.
struct SettingsRowAdaptiveLayout<Label: View, Control: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let label: Label
    @ViewBuilder let control: Control

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                label
                control
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack {
                label
                Spacer()
                control
            }
        }
    }
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
    animated: Bool,
    loc: LocalizationManager
) -> some View {
    // The WHOLE row is the button, not just the pill, so a tap on the label
    // or in the empty middle flips the setting — like a native `Toggle` row.
    Button {
        value.wrappedValue.toggle()
        Haptics.tap()
    } label: {
        iOSSettingsRow {
            SettingsRowAdaptiveLayout {
                HStack {
                    iOSRowIcon(systemName: icon, color: accent)
                    Text(label)
                        .font(CinemaFont.dynamicLabel(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                }
            } control: {
                CinemaToggleIndicator(isOn: value.wrappedValue, accent: accent, animated: animated)
            }
        }
    }
    .buttonStyle(.plain)
    // Collapse the whole row into one VoiceOver element that announces the
    // label + on/off state + toggle semantics (the bare `CinemaToggleIndicator`
    // is purely visual, so without this VoiceOver read the setting label-only).
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityValue(loc.localized(value.wrappedValue ? "a11y.toggle.on" : "a11y.toggle.off"))
    .accessibilityAddTraits(.isToggle)
    .accessibilityAction {
        value.wrappedValue.toggle()
        Haptics.tap()
    }
}

/// Renders a list of `SettingsToggleRow` as iOS toggle rows separated by
/// `iOSSettingsDivider`. Caller is responsible for wrapping in a `glassPanel`
/// and for appending any non-toggle rows (sleep timer, font size, etc.) —
/// this keeps the helper compatible with mixed-row sections.
@MainActor
@ViewBuilder
func iOSToggleRowsJoined(_ rows: [SettingsToggleRow], accent: Color, animated: Bool, loc: LocalizationManager) -> some View {
    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
        iOSToggleRow(
            icon: row.icon,
            label: row.label,
            value: row.value,
            accent: row.tint ?? accent,
            animated: animated,
            loc: loc
        )
        if index < rows.count - 1 {
            iOSSettingsDivider
        }
    }
}

#endif
