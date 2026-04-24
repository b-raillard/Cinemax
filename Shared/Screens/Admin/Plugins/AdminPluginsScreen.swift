#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Installed plugins list. Enable/disable is a toggle on each row; uninstall
/// is a menu action guarded by a confirmation dialog. Disabled plugins and
/// plugins that need a server restart are signalled via a coloured status
/// badge — no guessing about plugin state.
struct AdminPluginsScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    @State private var viewModel = AdminPluginsViewModel()

    var body: some View {
        AdminLoadStateContainer(
            isLoading: viewModel.isLoading && viewModel.plugins.isEmpty,
            errorMessage: viewModel.errorMessage,
            isEmpty: viewModel.isEmpty,
            emptyIcon: "puzzlepiece.extension",
            emptyTitle: loc.localized("admin.plugins.empty.title"),
            emptySubtitle: loc.localized("admin.plugins.empty.subtitle"),
            onRetry: { Task { await viewModel.load(using: appState.apiClient) } }
        ) {
            ScrollView(showsIndicators: false) {
                AdminSectionGroup {
                    ForEach(Array(viewModel.plugins.enumerated()), id: \.element.id) { index, plugin in
                        pluginRow(plugin)
                        if index < viewModel.plugins.count - 1 {
                            iOSSettingsDivider
                        }
                    }
                }
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.top, CinemaSpacing.spacing4)
                .padding(.bottom, CinemaSpacing.spacing8)
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.plugins.title"))
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await viewModel.load(using: appState.apiClient) }
        .task {
            if viewModel.plugins.isEmpty {
                await viewModel.load(using: appState.apiClient)
            }
        }
        .confirmationDialog(
            loc.localized("admin.plugins.uninstall.title"),
            isPresented: Binding(
                get: { viewModel.pendingUninstall != nil },
                set: { if !$0 { viewModel.pendingUninstall = nil } }
            ),
            titleVisibility: .visible,
            presenting: viewModel.pendingUninstall
        ) { plugin in
            Button(loc.localized("admin.plugins.uninstall.confirm"), role: .destructive) {
                Task {
                    let ok = await viewModel.uninstall(plugin, using: appState.apiClient)
                    if ok {
                        toasts.success(loc.localized("admin.plugins.uninstall.success"))
                    } else if let err = viewModel.errorMessage {
                        toasts.error(err)
                    }
                    viewModel.pendingUninstall = nil
                }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {
                viewModel.pendingUninstall = nil
            }
        } message: { plugin in
            Text(String(
                format: loc.localized("admin.plugins.uninstall.message"),
                plugin.name ?? ""
            ))
        }
    }

    @ViewBuilder
    private func pluginRow(_ plugin: PluginInfo) -> some View {
        let isPending = viewModel.pendingActionPluginId == plugin.id
        let isEnabled = plugin.status == .active || plugin.status == .restart

        iOSSettingsRow {
            HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
                iOSRowIcon(
                    systemName: "puzzlepiece.extension",
                    color: isEnabled ? themeManager.accent : CinemaColor.onSurfaceVariant
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(plugin.name ?? "—")
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)

                    HStack(spacing: CinemaSpacing.spacing2) {
                        if let version = plugin.version {
                            Text("v\(version)")
                                .font(CinemaFont.label(.small))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                        }
                        statusBadge(plugin.status)
                    }

                    if let description = plugin.description, !description.isEmpty {
                        Text(description)
                            .font(CinemaFont.label(.small))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }

                Spacer()

                VStack(spacing: CinemaSpacing.spacing2) {
                    if isPending {
                        ProgressView().tint(themeManager.accent)
                    } else {
                        Button {
                            Task {
                                let ok = await viewModel.setEnabled(plugin, enabled: !isEnabled, using: appState.apiClient)
                                if ok {
                                    toasts.info(loc.localized(isEnabled ? "admin.plugins.disabled" : "admin.plugins.enabled"))
                                } else if let err = viewModel.errorMessage {
                                    toasts.error(err)
                                }
                            }
                        } label: {
                            CinemaToggleIndicator(isOn: isEnabled, accent: themeManager.accent, animated: true)
                        }
                        .buttonStyle(.plain)
                    }

                    if plugin.canUninstall == true {
                        Menu {
                            Button(role: .destructive) {
                                viewModel.pendingUninstall = plugin
                            } label: {
                                Label(loc.localized("admin.plugins.uninstall"), systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                                .frame(width: 32, height: 24)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: PluginStatus?) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .active:
                return (loc.localized("admin.plugins.status.active"), CinemaColor.success)
            case .disabled:
                return (loc.localized("admin.plugins.status.disabled"), CinemaColor.onSurfaceVariant)
            case .restart:
                return (loc.localized("admin.plugins.status.restart"), .orange)
            case .malfunctioned, .notSupported:
                return (loc.localized("admin.plugins.status.error"), CinemaColor.error)
            case .superseded, .superceded:
                return (loc.localized("admin.plugins.status.superseded"), .orange)
            case .deleted:
                return (loc.localized("admin.plugins.status.deleted"), CinemaColor.error)
            case .none:
                return ("", CinemaColor.onSurfaceVariant)
            }
        }()

        if !label.isEmpty {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.15)))
        }
    }
}
#endif
