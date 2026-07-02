#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Admin → "Fonction hors ligne" — the control panel for the
/// offline-downloads feature gate:
///   * one **global** toggle (server-wide kill-switch, Branding marker)
///   * one toggle **per user** (`UserPolicy.enableContentDownloading`)
/// A user only ever sees download affordances when BOTH are on. Explicit
/// save via `AdminFormScreen` (admin-editor rule).
struct AdminOfflineScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.motionEffectsEnabled) private var motionEffects

    @State private var viewModel = AdminOfflineViewModel()

    var body: some View {
        AdminLoadStateContainer(
            isLoading: viewModel.isLoading && !viewModel.hasLoaded,
            errorMessage: viewModel.hasLoaded ? nil : viewModel.errorMessage,
            isEmpty: false,
            onRetry: { Task { await viewModel.load(using: appState.apiClient, loc: loc) } }
        ) {
            if viewModel.hasLoaded {
                AdminFormScreen(
                    isDirty: viewModel.isDirty,
                    isSaving: viewModel.isSaving,
                    onSave: {
                        let ok = await viewModel.save(using: appState.apiClient, loc: loc)
                        if ok {
                            toasts.success(loc.localized("admin.offline.save.success"))
                            // Re-derive the local gate right away — when the
                            // admin just changed the global flag or their own
                            // policy, their Settings/detail surfaces must
                            // reflect it without waiting for the next launch.
                            await appState.refreshCurrentUser()
                        } else if let err = viewModel.errorMessage {
                            toasts.error(err)
                        }
                    }
                ) {
                    globalSection
                    usersSection
                }
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.offline.title"))
        .navigationBarTitleDisplayMode(.large)
        .task {
            if !viewModel.hasLoaded {
                await viewModel.load(using: appState.apiClient, loc: loc)
            }
        }
    }

    // MARK: - Sections

    private var globalSection: some View {
        AdminSectionGroup(
            loc.localized("admin.offline.global.title"),
            footer: loc.localized("admin.offline.global.footer")
        ) {
            iOSSettingsRow {
                HStack {
                    iOSRowIcon(systemName: "arrow.down.circle", color: themeManager.accent)
                    Text(loc.localized("admin.offline.global.toggle"))
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                    Spacer()
                    Button { viewModel.globalEnabled.toggle() } label: {
                        CinemaToggleIndicator(
                            isOn: viewModel.globalEnabled,
                            accent: themeManager.accent,
                            animated: motionEffects
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var usersSection: some View {
        AdminSectionGroup(
            loc.localized("admin.offline.users.title"),
            footer: loc.localized("admin.offline.users.footer")
        ) {
            ForEach(Array(viewModel.users.enumerated()), id: \.element.id) { index, user in
                userRow(user)
                if index < viewModel.users.count - 1 {
                    iOSSettingsDivider
                }
            }
        }
    }

    @ViewBuilder
    private func userRow(_ user: UserDto) -> some View {
        let userId = user.id ?? ""
        let isOn = viewModel.perUser[userId] ?? true
        iOSSettingsRow {
            HStack(spacing: CinemaSpacing.spacing3) {
                UserAvatar(
                    userId: user.id,
                    name: user.name,
                    primaryImageTag: user.primaryImageTag,
                    size: 36
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.name ?? "—")
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                        .lineLimit(1)
                    if user.policy?.isAdministrator == true {
                        Text(loc.localized("settings.admin").uppercased())
                            .font(.system(size: CinemaScale.pt(10), weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(themeManager.accent)
                    }
                }
                Spacer()
                Button { viewModel.toggleUser(userId) } label: {
                    CinemaToggleIndicator(
                        isOn: isOn,
                        accent: themeManager.accent,
                        animated: motionEffects
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
#endif
