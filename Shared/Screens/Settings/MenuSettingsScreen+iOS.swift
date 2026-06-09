import SwiftUI
import CinemaxKit

#if os(iOS)
extension MenuSettingsScreen {

    var iOSBody: some View {
        // Native `List` so iOS provides:
        //  • `Picker(.segmented)` row chrome inside Section rows
        //  • `EditButton` + `.onMove` for drag-reorder with the standard
        //    3-bar handle on the right of each row in edit mode
        // The per-row toggle uses `CinemaToggleIndicator` (design-system
        // mandate — `Never system Toggle in settings`) inside a Button with
        // `.buttonStyle(.borderless)`, which is the documented SwiftUI
        // escape hatch to stop the List cell from stealing the inner tap.
        List {
            modeSection
            if store.mode == .custom {
                kindSection
                if store.customKind == .library {
                    refreshSection
                }
                entriesSection
                resetSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(CinemaColor.surface.ignoresSafeArea())
        // Permanent edit mode → the native ≡ drag handle is always visible
        // on the right edge of each row that has `.onMove`. Pickers and
        // action rows (no `.onMove`) stay fully interactive because edit
        // mode only affects rows that opted in to moving — and we never
        // declared `.onDelete`, so no destructive UI appears either.
        .environment(\.editMode, .constant(.active))
        .navigationTitle(loc.localized("settings.interface.menu"))
        .navigationBarTitleDisplayMode(.large)
        .task {
            if store.mode == .custom && store.customKind == .library && store.availableViews.isEmpty {
                await store.refreshAvailableViews()
            }
        }
    }

    // MARK: - Mode section (native segmented picker)

    @ViewBuilder
    private var modeSection: some View {
        Section {
            // Custom `Binding` so `setMode` runs on every selection — that's
            // where persistence + downstream side effects (`ensureLibraryEntriesPopulated`)
            // live. The `$store.mode` projection from `@Bindable` skips them.
            Picker(loc.localized("menu.mode"), selection: Binding(
                get: { store.mode },
                set: { store.setMode($0) }
            )) {
                Text(loc.localized("menu.mode.default")).tag(MenuConfigStore.Mode.default)
                Text(loc.localized("menu.mode.custom")).tag(MenuConfigStore.Mode.custom)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .padding(.vertical, CinemaSpacing.spacing2)
        } header: {
            Text(loc.localized("menu.mode"))
        } footer: {
            Text(loc.localized("menu.mode.footer"))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
    }

    // MARK: - Kind section (native segmented picker)

    @ViewBuilder
    private var kindSection: some View {
        Section {
            Picker(loc.localized("menu.kind"), selection: Binding(
                get: { store.customKind },
                set: { store.setCustomKind($0) }
            )) {
                Text(loc.localized("menu.kind.contentType")).tag(MenuConfigStore.CustomKind.contentType)
                Text(loc.localized("menu.kind.library")).tag(MenuConfigStore.CustomKind.library)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .padding(.vertical, CinemaSpacing.spacing2)
        } header: {
            Text(loc.localized("menu.kind"))
        }
    }

    // MARK: - Refresh section

    @ViewBuilder
    private var refreshSection: some View {
        Section {
            Button {
                Task { await store.refreshAvailableViews() }
            } label: {
                HStack(spacing: CinemaSpacing.spacing3) {
                    if store.isLoadingViews {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: CinemaScale.pt(16), weight: .semibold))
                    }
                    Text(loc.localized("menu.refreshViews"))
                        .font(CinemaFont.label(.large))
                    Spacer()
                }
                .foregroundStyle(store.isLoadingViews ? CinemaColor.onSurfaceVariant : themeManager.accent)
            }
            .buttonStyle(.borderless)
            .disabled(store.isLoadingViews)

            if store.lastFetchError != nil {
                HStack(spacing: CinemaSpacing.spacing2) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(CinemaColor.error)
                    Text(loc.localized("menu.library.error"))
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.error)
                }
            }
        }
    }

    // MARK: - Entries section (native drag-reorder)

    @ViewBuilder
    private var entriesSection: some View {
        Section {
            if store.customKind == .library && store.availableViews.isEmpty && !store.isLoadingViews {
                emptyLibraryRow
            } else {
                let entries = activeEntries
                ForEach(entries) { entry in
                    entryRow(entry)
                }
                .onMove { offsets, target in
                    store.move(fromOffsets: offsets, toOffset: target)
                }
                // Intentionally no `.onDelete` — only drag-reorder, no
                // swipe-to-delete in edit mode.
            }
        } header: {
            Text(loc.localized("menu.entries.title"))
        } footer: {
            Text(loc.localized(
                store.customKind == .contentType
                    ? "menu.entries.footer.contentType"
                    : "menu.entries.footer.library"
            ))
            .font(CinemaFont.label(.medium))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: MenuEntry) -> some View {
        HStack(spacing: CinemaSpacing.spacing3) {
            iOSRowIcon(systemName: entryIcon(entry), color: themeManager.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(entryLabel(entry))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                if entry.isMandatory {
                    Text(loc.localized("menu.entry.required"))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }

            Spacer()

            if entry.isMandatory {
                Image(systemName: "lock.fill")
                    .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            } else {
                Button {
                    let result = store.toggle(entry.id)
                    if result == .refusedCapReached {
                        toasts.info(String(format: loc.localized("menu.maxReached"), MenuConfigStore.maxEnabledTabs))
                    }
                } label: {
                    CinemaToggleIndicator(isOn: entry.enabled, accent: themeManager.accent, animated: motionEffects)
                }
                // `.borderless` keeps the inner Button reachable inside the
                // List row — `.plain` lets the row's tap-handler swallow it.
                .buttonStyle(.borderless)
                .sensoryFeedback(.selection, trigger: entry.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var emptyLibraryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loc.localized("menu.library.empty"))
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurface)
            Text(loc.localized("menu.library.empty.subtitle"))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Reset section

    @ViewBuilder
    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                store.reset()
                toasts.success(loc.localized("menu.reset.confirm"))
            } label: {
                HStack(spacing: CinemaSpacing.spacing3) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: CinemaScale.pt(16), weight: .semibold))
                    Text(loc.localized("menu.reset"))
                        .font(CinemaFont.label(.large))
                    Spacer()
                }
            }
            .buttonStyle(.borderless)
        }
    }
}
#endif
