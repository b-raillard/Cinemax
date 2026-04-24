import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Two-step user switcher presented from Settings → Account. Avoids the full
/// server-setup + login flow when families share a single device (common on tvOS).
///
/// Step 1 — grid of server users with their primary images
/// Step 2 — password prompt for the picked user
///
/// On success, updates `AppState` (access token + userId) without clearing the server URL,
/// and emits a success toast before dismissing. Errors show inline; the sheet stays open
/// so users can retry without losing their place.
struct UserSwitchSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    @State private var users: [UserDto] = []
    @State private var isLoading = true
    @State private var selectedUser: UserDto?
    @State private var password: String = ""
    @State private var isAuthenticating = false
    @State private var authError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                CinemaColor.surface.ignoresSafeArea()

                if let user = selectedUser {
                    passwordStep(for: user)
                } else if isLoading {
                    LoadingStateView()
                } else if users.isEmpty {
                    EmptyStateView(
                        systemImage: "person.slash",
                        title: loc.localized("switchAccount.pickUser")
                    )
                } else {
                    userGrid
                }
            }
            .navigationTitle(loc.localized("settings.switchAccount"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.cancel")) { dismiss() }
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
        }
        .task {
            await loadUsers()
        }
    }

    // MARK: - Step 1: Pick a user

    private var userGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: CinemaSpacing.spacing4) {
                ForEach(users, id: \.id) { user in
                    userTile(user)
                }
            }
            .padding(CinemaSpacing.spacing4)
        }
    }

    @ViewBuilder
    private func userTile(_ user: UserDto) -> some View {
        Button {
            selectedUser = user
            authError = nil
            password = ""
        } label: {
            VStack(spacing: CinemaSpacing.spacing2) {
                avatar(for: user)
                Text(user.name ?? "")
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, CinemaSpacing.spacing3)
            .background(CinemaColor.surfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel(user.name ?? "")
    }

    @ViewBuilder
    private func avatar(for user: UserDto) -> some View {
        UserAvatar(
            userId: user.id,
            name: user.name,
            primaryImageTag: user.primaryImageTag,
            size: avatarSize
        )
    }

    // MARK: - Step 2: Password prompt

    @ViewBuilder
    private func passwordStep(for user: UserDto) -> some View {
        VStack(spacing: CinemaSpacing.spacing5) {
            Spacer()

            avatar(for: user)

            Text(String(format: loc.localized("switchAccount.enterPasswordFor"), user.name ?? ""))
                .font(CinemaFont.headline(.small))
                .foregroundStyle(CinemaColor.onSurface)
                .multilineTextAlignment(.center)

            SecureField(loc.localized("login.password"), text: $password)
                .textContentType(.password)
                #if os(iOS)
                .submitLabel(.go)
                #endif
                .onSubmit { Task { await performAuth(user: user) } }
                .padding(.horizontal, CinemaSpacing.spacing4)
                .padding(.vertical, CinemaSpacing.spacing3)
                .background(CinemaColor.surfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                .padding(.horizontal, CinemaSpacing.spacing4)

            if let authError {
                Text(authError)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, CinemaSpacing.spacing4)
            }

            CinemaButton(
                title: isAuthenticating ? "…" : loc.localized("switchAccount.signIn"),
                style: .primary
            ) {
                Task { await performAuth(user: user) }
            }
            .disabled(isAuthenticating)
            .padding(.horizontal, CinemaSpacing.spacing4)

            Button {
                selectedUser = nil
                password = ""
                authError = nil
            } label: {
                Text(loc.localized("action.cancel"))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func loadUsers() async {
        isLoading = true
        defer { isLoading = false }
        // Prefer authenticated list when available (richer); fall back to public users.
        if let fetched = try? await appState.apiClient.getUsers(), !fetched.isEmpty {
            users = fetched
            return
        }
        users = (try? await appState.apiClient.getPublicUsers()) ?? []
    }

    private func performAuth(user: UserDto) async {
        guard let username = user.name else { return }
        isAuthenticating = true
        authError = nil
        defer { isAuthenticating = false }
        do {
            let session = try await appState.apiClient.authenticate(
                username: username, password: password
            )
            try appState.keychain.saveAccessToken(session.accessToken)
            try appState.keychain.saveUserSession(session)
            appState.accessToken = session.accessToken
            appState.currentUserId = session.userID
            appState.apiClient.reconnect(
                url: appState.serverURL ?? AppState.placeholderServerURL,
                accessToken: session.accessToken
            )
            // Drop cached DTOs from the previous user's session — APICache is
            // keyed by query params only, so personalised views (resume, next-up,
            // rating-filtered lists) would otherwise bleed across accounts
            // until each screen refreshed on its own.
            appState.apiClient.clearCache()
            appState.isAuthenticated = true
            // Refresh admin flag + full user so Settings rerenders with the
            // right categories for the switched-to user.
            await appState.refreshCurrentUser()

            toasts.success(String(format: loc.localized("switchAccount.success"), username))
            password = ""
            dismiss()
        } catch {
            authError = loc.localized("switchAccount.authFailed")
        }
    }

    // MARK: - Sizing

    private var gridColumns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: CinemaSpacing.spacing4), count: 4)
        #else
        AdaptiveLayout.userGridColumns(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var avatarSize: CGFloat {
        #if os(tvOS)
        140
        #else
        80
        #endif
    }
}
