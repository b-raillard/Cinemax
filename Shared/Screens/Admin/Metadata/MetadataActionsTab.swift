#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Actions tab — refresh metadata and delete item. Refresh is a fire-and-forget
/// server job (the scheduled-task system picks it up); Delete is final and
/// goes through `DestructiveConfirmSheet` with the item's title as the
/// type-to-confirm phrase.
///
/// `onDeleted` closure lets the caller dismiss the editor after a successful
/// delete — the item no longer exists server-side, so leaving the editor open
/// would be confusing.
struct MetadataActionsTab: View {
    @Bindable var viewModel: MetadataEditorViewModel
    let onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        Group {
            refreshSection
            deleteSection
        }
        .sheet(isPresented: $viewModel.showDeleteConfirm) {
            DestructiveConfirmSheet(
                title: loc.localized("admin.metadata.delete.title"),
                message: String(
                    format: loc.localized("admin.metadata.delete.message"),
                    viewModel.item.name ?? ""
                ),
                requiredPhrase: viewModel.item.name ?? "",
                confirmLabel: loc.localized("admin.metadata.delete.confirm"),
                onConfirm: {
                    let ok = await viewModel.deleteItem(using: appState.apiClient)
                    if ok {
                        onDeleted()
                    } else if let err = viewModel.errorMessage {
                        toasts.error(err)
                    }
                }
            )
        }
    }

    // MARK: - Refresh section

    private var refreshSection: some View {
        AdminSectionGroup(
            loc.localized("admin.metadata.actions.refresh.title"),
            footer: loc.localized("admin.metadata.actions.refresh.footer")
        ) {
            modePickerRow(
                label: loc.localized("admin.metadata.actions.refresh.metadataMode"),
                selection: $viewModel.refreshMetadataMode
            )
            iOSSettingsDivider
            modePickerRow(
                label: loc.localized("admin.metadata.actions.refresh.imageMode"),
                selection: $viewModel.refreshImageMode
            )
            iOSSettingsDivider
            toggleRow(
                label: loc.localized("admin.metadata.actions.refresh.replaceMetadata"),
                isOn: $viewModel.refreshReplaceAllMetadata
            )
            iOSSettingsDivider
            toggleRow(
                label: loc.localized("admin.metadata.actions.refresh.replaceImages"),
                isOn: $viewModel.refreshReplaceAllImages
            )
            iOSSettingsDivider
            iOSSettingsRow {
                CinemaButton(
                    title: loc.localized("admin.metadata.actions.refresh.submit"),
                    style: .primary,
                    isLoading: viewModel.isRefreshing
                ) {
                    Task {
                        let ok = await viewModel.refreshMetadata(using: appState.apiClient)
                        if ok {
                            toasts.success(loc.localized("admin.metadata.actions.refresh.success"))
                        } else if let err = viewModel.errorMessage {
                            toasts.error(err)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Delete section

    private var deleteSection: some View {
        AdminSectionGroup(
            loc.localized("admin.metadata.actions.delete.title"),
            footer: loc.localized("admin.metadata.actions.delete.footer")
        ) {
            iOSSettingsRow {
                Button(role: .destructive) {
                    viewModel.showDeleteConfirm = true
                } label: {
                    HStack {
                        iOSRowIcon(systemName: "trash", color: CinemaColor.error)
                        Text(loc.localized("admin.metadata.delete.title"))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.error)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func modePickerRow(label: String, selection: Binding<MetadataRefreshMode>) -> some View {
        iOSSettingsRow {
            HStack {
                Text(label)
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                Menu {
                    ForEach(MetadataRefreshMode.allCases, id: \.self) { mode in
                        Button {
                            selection.wrappedValue = mode
                        } label: {
                            if selection.wrappedValue == mode {
                                Label(modeLabel(mode), systemImage: "checkmark")
                            } else {
                                Text(modeLabel(mode))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(modeLabel(selection.wrappedValue))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: CinemaScale.pt(11), weight: .semibold))
                            .foregroundStyle(CinemaColor.outlineVariant)
                    }
                }
                .tint(themeManager.accent)
            }
        }
    }

    @ViewBuilder
    private func toggleRow(label: String, isOn: Binding<Bool>) -> some View {
        iOSSettingsRow {
            HStack {
                Text(label)
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                Button { isOn.wrappedValue.toggle() } label: {
                    CinemaToggleIndicator(
                        isOn: isOn.wrappedValue,
                        accent: themeManager.accent,
                        animated: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func modeLabel(_ mode: MetadataRefreshMode) -> String {
        switch mode {
        case .none: loc.localized("admin.metadata.actions.refresh.mode.none")
        case .validationOnly: loc.localized("admin.metadata.actions.refresh.mode.validation")
        case .default: loc.localized("admin.metadata.actions.refresh.mode.default")
        case .fullRefresh: loc.localized("admin.metadata.actions.refresh.mode.full")
        }
    }
}
#endif
