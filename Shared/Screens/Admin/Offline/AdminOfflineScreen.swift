#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Admin → "Fonction hors ligne" — one toggle per user over
/// `UserPolicy.enableContentDownloading` (Jellyfin's native "Allow media
/// downloads" policy). A user only sees download affordances when their own
/// flag is on. Jellyfin defaults the policy to ON for every account, so the
/// header offers bulk enable/disable. Explicit save via `AdminFormScreen`
/// (admin-editor rule).
struct AdminOfflineScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.motionEffectsEnabled) private var motionEffects

    @State private var viewModel = AdminOfflineViewModel()

    var body: some View {
        AdminLoadStateContainer(
            isLoading: viewModel.isLoading && viewModel.users.isEmpty,
            errorMessage: viewModel.errorMessage,
            isEmpty: viewModel.isEmpty,
            emptyIcon: "person.slash",
            emptyTitle: loc.localized("admin.offline.empty.title"),
            emptySubtitle: loc.localized("admin.offline.empty.subtitle"),
            onRetry: { Task { await viewModel.load(using: appState.apiClient, loc: loc) } }
        ) {
            AdminFormScreen(
                isDirty: viewModel.isDirty,
                isSaving: viewModel.isSaving,
                onSave: {
                    let ok = await viewModel.save(using: appState.apiClient, loc: loc)
                    if ok {
                        toasts.success(loc.localized("admin.offline.save.success"))
                        // Re-derive the local gate right away — when the
                        // admin just changed their own policy, their
                        // Settings/detail surfaces must reflect it
                        // without waiting for the next launch.
                        await appState.refreshCurrentUser()
                    } else if let err = viewModel.errorMessage {
                        toasts.error(err)
                    }
                }
            ) {
                bulkActions
                usersSection
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.offline.title"))
        .navigationBarTitleDisplayMode(.large)
        .task {
            if viewModel.users.isEmpty {
                await viewModel.load(using: appState.apiClient, loc: loc)
            }
        }
    }

    // MARK: - Sections

    /// Bulk edit row — edits local state only; the sticky Save commits.
    private var bulkActions: some View {
        HStack(spacing: CinemaSpacing.spacing3) {
            CinemaButton(title: loc.localized("admin.offline.enableAll"), style: .ghost) {
                viewModel.setAll(true)
            }
            CinemaButton(title: loc.localized("admin.offline.disableAll"), style: .ghost) {
                viewModel.setAll(false)
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
                // The pill is purely visual — expose which user + on/off to VoiceOver.
                .accessibilityLabel(user.name ?? "—")
                .accessibilityValue(loc.localized(isOn ? "a11y.toggle.on" : "a11y.toggle.off"))
                .accessibilityAddTraits(.isToggle)
            }
        }
    }
}
#endif
