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
    @State private var showManualEntry = false
    @State private var manualUsername: String = ""

    var body: some View {
        Group {
            #if os(tvOS)
            tvOSChrome
            #else
            iOSChrome
            #endif
        }
        .task {
            await loadUsers()
        }
    }

    // MARK: - Chrome

    /// The step currently on screen — shared by both chromes.
    private var stepContent: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            if showManualEntry {
                manualEntryStep
            } else if let user = selectedUser {
                passwordStep(for: user)
            } else if isLoading {
                LoadingStateView()
            } else if users.isEmpty {
                EmptyStateView(
                    systemImage: "person.crop.circle.badge.questionmark",
                    title: loc.localized("switchAccount.noPublicUsers.title"),
                    subtitle: loc.localized("switchAccount.noPublicUsers.subtitle"),
                    actionTitle: loc.localized("switchAccount.signInManually"),
                    onAction: { enterManualMode() }
                )
            } else {
                userGrid
            }
        }
    }

    #if !os(tvOS)
    private var iOSChrome: some View {
        NavigationStack {
            stepContent
                .navigationTitle(loc.localized("settings.switchAccount"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(loc.localized("action.cancel")) { dismiss() }
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }
                }
        }
    }
    #endif

    #if os(tvOS)
    /// tvOS full-screen-cover chrome — the one shape every tvOS modal shares
    /// (`WatchedHistoryScreen`): header row with the title and an accent
    /// button, content below, Menu dismisses. A `.toolbar` item renders as a
    /// broken empty pill on tvOS, which is what the Cancel button used to be.
    private var tvOSChrome: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                tvHeader
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onExitCommand { dismiss() }
    }

    private var tvHeader: some View {
        HStack(alignment: .center) {
            Text(loc.localized("settings.switchAccount"))
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)

            Spacer(minLength: CinemaSpacing.spacing6)

            CinemaButton(
                title: loc.localized("action.cancel"),
                style: .accent
            ) {
                dismiss()
            }
            .frame(width: CinemaTVLayout.ctaWidth)
        }
        .padding(.horizontal, CinemaTVLayout.pagePadding)
        .padding(.top, CinemaSpacing.spacing8)
        .padding(.bottom, CinemaSpacing.spacing5)
        // Without this, up-presses from the first grid row never reach the
        // header button (separate container — same rule as the Home hero).
        .focusSection()
    }
    #endif

    // MARK: - Step 1: Pick a user

    private var userGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: CinemaSpacing.spacing4) {
                ForEach(users, id: \.id) { user in
                    userTile(user)
                }
            }
            .padding(.horizontal, gridHorizontalPadding)
            .padding(.vertical, CinemaSpacing.spacing4)

            textActionButton(
                loc.localized("switchAccount.useDifferentAccount"),
                color: themeManager.accent
            ) {
                enterManualMode()
            }
            .padding(.bottom, CinemaSpacing.spacing4)
        }
        #if os(tvOS)
        // The tiles carry `CinemaTVCardButtonStyle`, which grows on focus —
        // without this the edge tiles' scaled ring is clipped.
        .scrollClipDisabled()
        #endif
    }

    /// A text-only secondary action. `.plain` gives it NO focus treatment on
    /// tvOS — focus landed on it invisibly — so there it wears a chip
    /// (surface capsule + `TVFilterChipButtonStyle`, the documented row/chip
    /// level); iOS keeps the bare text.
    @ViewBuilder
    private func textActionButton(
        _ title: String, color: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(CinemaFont.label(.large))
                .foregroundStyle(color)
                #if os(tvOS)
                .padding(.horizontal, CinemaSpacing.spacing4)
                .padding(.vertical, CinemaSpacing.spacing2)
                .background(CinemaColor.surfaceContainer)
                .clipShape(Capsule())
                #endif
        }
        #if os(tvOS)
        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
        #else
        .buttonStyle(.plain)
        #endif
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
                .onSubmit {
                    guard !isAuthenticating else { return }
                    Task { await performAuth(user: user) }
                }
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
                style: .accent
            ) {
                Task { await performAuth(user: user) }
            }
            .disabled(isAuthenticating)
            .padding(.horizontal, CinemaSpacing.spacing4)

            textActionButton(
                loc.localized("action.cancel"),
                color: CinemaColor.onSurfaceVariant
            ) {
                selectedUser = nil
                password = ""
                authError = nil
            }

            Spacer()
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step 3: Manual entry (server hides user list or hidden account)

    private var manualEntryStep: some View {
        VStack(spacing: CinemaSpacing.spacing5) {
            Spacer()

            ZStack {
                Circle()
                    .fill(themeManager.accent.opacity(0.15))
                    .frame(width: avatarSize, height: avatarSize)
                Image(systemName: "person.crop.circle")
                    .font(.system(size: avatarSize * 0.55, weight: .regular))
                    .foregroundStyle(themeManager.accent)
            }

            Text(loc.localized("switchAccount.signInManually"))
                .font(CinemaFont.headline(.small))
                .foregroundStyle(CinemaColor.onSurface)
                .multilineTextAlignment(.center)

            // Autocap/autocorrect must apply on tvOS too — Jellyfin usernames
            // are case-sensitive server-side, and the tvOS on-screen keyboard
            // otherwise sentence-caps the first character.
            TextField(loc.localized("switchAccount.username"), text: $manualUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textContentType(.username)
                .submitLabel(.next)
                #endif
                .padding(.horizontal, CinemaSpacing.spacing4)
                .padding(.vertical, CinemaSpacing.spacing3)
                .background(CinemaColor.surfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                .padding(.horizontal, CinemaSpacing.spacing4)

            SecureField(loc.localized("login.password"), text: $password)
                .textContentType(.password)
                #if os(iOS)
                .submitLabel(.go)
                #endif
                .onSubmit {
                    guard !isAuthenticating,
                          !manualUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !password.isEmpty else { return }
                    Task { await performAuth(username: manualUsername) }
                }
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
                style: .accent
            ) {
                Task { await performAuth(username: manualUsername) }
            }
            .disabled(isAuthenticating
                      || manualUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || password.isEmpty)
            .padding(.horizontal, CinemaSpacing.spacing4)

            textActionButton(
                loc.localized("action.cancel"),
                color: CinemaColor.onSurfaceVariant
            ) {
                exitManualMode()
            }

            Spacer()
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func enterManualMode() {
        showManualEntry = true
        authError = nil
        password = ""
        manualUsername = ""
    }

    private func exitManualMode() {
        showManualEntry = false
        manualUsername = ""
        password = ""
        authError = nil
    }

    private func loadUsers() async {
        isLoading = true
        defer { isLoading = false }
        // Visibility rule (admin-only getUsers, hidden filter, public
        // fallback) is shared with the tvOS quick-switch grid — see
        // AppState.fetchSwitchableUsers.
        users = await appState.fetchSwitchableUsers()
    }

    private func performAuth(user: UserDto) async {
        guard let username = user.name else { return }
        await performAuth(username: username)
    }

    private func performAuth(username: String) async {
        // Username is trimmed because tvOS on-screen keyboards and iOS paste
        // commonly inject a trailing space — Jellyfin matches usernames
        // exactly so the un-trimmed value would silently 401. Password is
        // intentionally NOT trimmed: legitimate passwords can contain
        // leading/trailing spaces (Jellyfin does not validate this), and
        // silently stripping them would break those accounts.
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isAuthenticating = true
        authError = nil
        defer { isAuthenticating = false }
        do {
            let session = try await appState.apiClient.authenticate(
                username: trimmed, password: password
            )
            try appState.keychain.saveAccessToken(session.accessToken)
            try appState.keychain.saveUserSession(session)
            appState.accessToken = session.accessToken
            appState.currentUserId = session.userID
            // Same server, different user: refresh the active registry entry so
            // the servers list shows who is signed in on it.
            appState.upsertActiveEntry(session: session)
            // reconnect() clears the cache as its first action — needed so
            // personalised DTOs (resume, next-up, rating-filtered lists)
            // from the previous user's session don't bleed across accounts.
            appState.apiClient.reconnect(
                url: appState.serverURL ?? AppState.placeholderServerURL,
                accessToken: session.accessToken
            )
            appState.isAuthenticated = true
            // Refresh admin flag + full user so Settings rerenders with the
            // right categories for the switched-to user.
            await appState.refreshCurrentUser()

            toasts.success(String(format: loc.localized("switchAccount.success"), trimmed))
            password = ""
            manualUsername = ""
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

    /// The grid sits at the page margin on tvOS, like every full-page grid.
    private var gridHorizontalPadding: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.pagePadding
        #else
        CinemaSpacing.spacing4
        #endif
    }
}
