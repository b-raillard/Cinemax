import SwiftUI
import CinemaxKit

#if os(tvOS)
extension MenuSettingsScreen {

    var tvBody: some View {
        // tvOS has no native drag-reorder for lists. We render each entry as
        // a focusable row with three controls (toggle + up + down) and let
        // the user reorder via dedicated buttons. Matches the pattern used
        // for action rows elsewhere in Settings.
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            modeRow
            if store.mode == .custom {
                kindRow
                if store.customKind == .library {
                    refreshRow
                }
                entriesList
                resetRow
            }
        }
    }

    // MARK: - Mode + kind pickers

    private var modeRow: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            Text(loc.localized("menu.mode").uppercased())
                .font(.system(size: CinemaScale.pt(17), weight: .bold))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .tracking(1.5)

            tvModePill(.default, label: loc.localized("menu.mode.default"))
            tvModePill(.custom, label: loc.localized("menu.mode.custom"))
        }
    }

    @ViewBuilder
    private func tvModePill(_ value: MenuConfigStore.Mode, label: String) -> some View {
        let key = "menu.mode.\(value.rawValue)"
        let isFocused = focusedItem == .toggle(key)
        let isSelected = store.mode == value
        Button {
            store.setMode(value)
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(isSelected ? themeManager.accent : CinemaColor.onSurfaceVariant)
                    .frame(width: 24)
                Text(label)
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .toggle(key))
    }

    private var kindRow: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            Text(loc.localized("menu.kind").uppercased())
                .font(.system(size: CinemaScale.pt(17), weight: .bold))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .tracking(1.5)

            tvKindPill(.contentType, label: loc.localized("menu.kind.contentType"))
            tvKindPill(.library, label: loc.localized("menu.kind.library"))
        }
    }

    @ViewBuilder
    private func tvKindPill(_ value: MenuConfigStore.CustomKind, label: String) -> some View {
        let key = "menu.kind.\(value.rawValue)"
        let isFocused = focusedItem == .toggle(key)
        let isSelected = store.customKind == value
        Button {
            store.setCustomKind(value)
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(isSelected ? themeManager.accent : CinemaColor.onSurfaceVariant)
                    .frame(width: 24)
                Text(label)
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .toggle(key))
    }

    // MARK: - Refresh

    private var refreshRow: some View {
        tvMenuActionRow(
            id: "menu.refreshViews",
            icon: store.isLoadingViews ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
            label: loc.localized("menu.refreshViews"),
            subtitle: store.lastFetchError != nil ? loc.localized("menu.library.error") : nil,
            action: { Task { await store.refreshAvailableViews() } }
        )
        .disabled(store.isLoadingViews)
    }

    /// Local equivalent of `SettingsScreen.tvActionRow` — the latter is an
    /// extension on `SettingsScreen` and reads its `@FocusState`, so it can't
    /// be invoked from another view. Same visual contract: focusable row with
    /// icon + label + optional subtitle + tvSettingsFocusable styling.
    @ViewBuilder
    private func tvMenuActionRow(
        id: String,
        icon: String,
        label: String,
        subtitle: String? = nil,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focusedItem == .toggle(id)
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
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .toggle(id))
    }

    // MARK: - Entries list

    @ViewBuilder
    private var entriesList: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            Text(loc.localized("menu.entries.title").uppercased())
                .font(.system(size: CinemaScale.pt(17), weight: .bold))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .tracking(1.5)

            if store.customKind == .library && store.availableViews.isEmpty && !store.isLoadingViews {
                tvEmptyCollectionRow
            } else {
                let entries = store.customKind == .contentType
                    ? store.contentTypeEntries
                    : store.libraryEntries
                ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                    tvEntryRow(entry, index: idx, total: entries.count)
                }
            }
        }
    }

    @ViewBuilder
    private func tvEntryRow(_ entry: MenuEntry, index: Int, total: Int) -> some View {
        let key = "menu.entry.\(entry.id)"
        let toggleKey = "menu.toggle.\(entry.id)"
        let upKey = "menu.up.\(entry.id)"
        let downKey = "menu.down.\(entry.id)"

        HStack(spacing: CinemaSpacing.spacing3) {
            Image(systemName: entryIcon(entry))
                .font(.system(size: CinemaScale.pt(20), weight: .medium))
                .foregroundStyle(themeManager.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entryLabel(entry))
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)
                if entry.isMandatory {
                    Text(loc.localized("menu.entry.required"))
                        .font(.system(size: CinemaScale.pt(15), weight: .regular))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }

            Spacer()

            // Toggle
            if entry.isMandatory {
                Image(systemName: "lock.fill")
                    .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .padding(.trailing, CinemaSpacing.spacing3)
            } else {
                let isFocused = focusedItem == .toggle(toggleKey)
                Button {
                    let result = store.toggle(entry.id)
                    if result == .refusedCapReached {
                        toasts.info(String(format: loc.localized("menu.maxReached"), MenuConfigStore.maxEnabledTabs))
                    }
                } label: {
                    CinemaToggleIndicator(isOn: entry.enabled, accent: themeManager.accent, animated: true)
                        .padding(.horizontal, CinemaSpacing.spacing3)
                        .padding(.vertical, CinemaSpacing.spacing2)
                        .background(
                            RoundedRectangle(cornerRadius: CinemaRadius.medium)
                                .strokeBorder(themeManager.accent.opacity(isFocused ? 0.8 : 0), lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .hoverEffectDisabled()
                .focused($focusedItem, equals: .toggle(toggleKey))
            }

            // Move up
            tvMoveButton(
                id: entry.id,
                key: upKey,
                systemImage: "arrow.up",
                accessibility: loc.localized("menu.entry.reorder.up"),
                enabled: index > 0,
                action: { store.moveBy(entry.id, delta: -1) }
            )

            // Move down
            tvMoveButton(
                id: entry.id,
                key: downKey,
                systemImage: "arrow.down",
                accessibility: loc.localized("menu.entry.reorder.down"),
                enabled: index < total - 1,
                action: { store.moveBy(entry.id, delta: 1) }
            )
        }
        .padding(.horizontal, CinemaSpacing.spacing4)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CinemaRadius.large)
                .fill(CinemaColor.surfaceContainerHigh)
        )
        .accessibilityLabel(entryLabel(entry))
        .accessibilityIdentifier(key)
    }

    @ViewBuilder
    private func tvMoveButton(id: String, key: String, systemImage: String, accessibility: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        let isFocused = focusedItem == .toggle(key)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                .foregroundStyle(enabled ? themeManager.accent : CinemaColor.onSurfaceVariant.opacity(0.4))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: CinemaRadius.medium)
                        .strokeBorder(themeManager.accent.opacity(isFocused ? 0.8 : 0), lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .toggle(key))
        .disabled(!enabled)
        .accessibilityLabel(accessibility)
    }

    @ViewBuilder
    private var tvEmptyCollectionRow: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            Text(loc.localized("menu.library.empty"))
                .font(.system(size: CinemaScale.pt(20), weight: .medium))
                .foregroundStyle(CinemaColor.onSurface)
            Text(loc.localized("menu.library.empty.subtitle"))
                .font(.system(size: CinemaScale.pt(16), weight: .regular))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
        .padding(.horizontal, CinemaSpacing.spacing4)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CinemaRadius.large)
                .fill(CinemaColor.surfaceContainerHigh)
        )
    }

    // MARK: - Overflow banner + reset

    private var resetRow: some View {
        tvMenuActionRow(
            id: "menu.reset",
            icon: "arrow.counterclockwise",
            label: loc.localized("menu.reset"),
            tint: CinemaColor.error,
            action: {
                store.reset()
                toasts.success(loc.localized("menu.reset.confirm"))
            }
        )
    }
}

#endif
