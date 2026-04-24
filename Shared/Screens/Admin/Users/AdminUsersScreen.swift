#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Admin Users grid. Mirrors Jellyfin web's Users panel: a grid of avatar
/// tiles with last-activity timestamps, a `+` toolbar button for creating
/// new users, and a tap-through to the four-tab detail editor.
struct AdminUsersScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var viewModel = AdminUsersViewModel()

    private var gridColumns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: CinemaSpacing.spacing3), count: count)
    }

    var body: some View {
        AdminLoadStateContainer(
            isLoading: viewModel.isLoading && viewModel.users.isEmpty,
            errorMessage: viewModel.errorMessage,
            isEmpty: viewModel.isEmpty,
            emptyIcon: "person.slash",
            emptyTitle: loc.localized("admin.users.empty.title"),
            emptySubtitle: loc.localized("admin.users.empty.subtitle"),
            emptyActionTitle: loc.localized("admin.users.add"),
            onRetry: { Task { await viewModel.load(using: appState.apiClient) } },
            onEmptyAction: { viewModel.showCreateUser = true }
        ) {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: CinemaSpacing.spacing3) {
                    ForEach(viewModel.users, id: \.id) { user in
                        NavigationLink {
                            AdminUserDetailScreen(user: user, parent: viewModel)
                        } label: {
                            userTile(user)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.top, CinemaSpacing.spacing3)
                .padding(.bottom, CinemaSpacing.spacing8)
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.users.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showCreateUser = true
                } label: {
                    Image(systemName: "plus")
                }
                .tint(themeManager.accent)
            }
        }
        .refreshable { await viewModel.load(using: appState.apiClient) }
        .task {
            if viewModel.users.isEmpty {
                await viewModel.load(using: appState.apiClient)
            }
        }
        .sheet(isPresented: $viewModel.showCreateUser) {
            createUserSheet
        }
    }

    // MARK: - User tile

    @ViewBuilder
    private func userTile(_ user: UserDto) -> some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            UserAvatar(
                userId: user.id,
                name: user.name,
                primaryImageTag: user.primaryImageTag,
                size: sizeClass == .regular ? 110 : 90
            )
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, CinemaSpacing.spacing3)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.name ?? "—")
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(1)

                Text(lastActivityText(for: user))
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(1)

                if user.policy?.isAdministrator == true {
                    adminBadge
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.bottom, CinemaSpacing.spacing3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(CinemaColor.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
    }

    private var adminBadge: some View {
        Text(loc.localized("settings.admin"))
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(themeManager.accent))
    }

    private func lastActivityText(for user: UserDto) -> String {
        guard let date = user.lastActivityDate ?? user.lastLoginDate else {
            return loc.localized("admin.users.neverActive")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Create user sheet

    private var createUserSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    GlassTextField(
                        label: loc.localized("admin.users.create.name"),
                        text: $viewModel.newUserName,
                        placeholder: loc.localized("admin.users.create.namePlaceholder")
                    )
                    GlassTextField(
                        label: loc.localized("admin.users.create.password"),
                        text: $viewModel.newUserPassword,
                        placeholder: loc.localized("admin.users.create.passwordPlaceholder"),
                        isSecure: true
                    )

                    Text(loc.localized("admin.users.create.passwordHint"))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)

                    if let err = viewModel.createErrorMessage {
                        Text(err)
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.error)
                    }

                    CinemaButton(
                        title: loc.localized("admin.users.create.submit"),
                        style: .accent,
                        isLoading: viewModel.isCreating
                    ) {
                        Task {
                            let ok = await viewModel.createUser(using: appState.apiClient)
                            if ok {
                                viewModel.showCreateUser = false
                                toasts.success(loc.localized("admin.users.create.success"))
                            }
                        }
                    }
                    .disabled(viewModel.newUserName.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isCreating)
                    .padding(.top, CinemaSpacing.spacing3)
                }
                .padding(CinemaSpacing.spacing4)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationTitle(loc.localized("admin.users.create.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.cancel")) { viewModel.showCreateUser = false }
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
