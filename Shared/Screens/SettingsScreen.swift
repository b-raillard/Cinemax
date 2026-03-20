import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

// MARK: - Accent Color Definition

private enum AccentOption: String, CaseIterable, Identifiable {
    case blue   = "blue"
    case purple = "purple"
    case pink   = "pink"
    case orange = "orange"
    case green  = "green"
    case cyan   = "cyan"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue:   Color(hex: 0x679CFF)
        case .purple: Color(hex: 0xBF7FFF)
        case .pink:   Color(hex: 0xFF6BB5)
        case .orange: Color(hex: 0xFF8C42)
        case .green:  Color(hex: 0x4CAF82)
        case .cyan:   Color(hex: 0x2DD4BF)
        }
    }
}

// MARK: - tvOS Focus Tracking

#if os(tvOS)
private enum SettingsFocus: Hashable {
    case profile(String)
    case switchAccount
    case refreshConnection
    case toggle(String)
}
#endif

// MARK: - Settings Screen

struct SettingsScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @State private var showLogOutAlert = false

    private var username: String {
        appState.keychain.getUserSession()?.username ?? "User"
    }

    private var userInitial: String {
        String(username.prefix(1)).uppercased()
    }

    private var serverName: String {
        appState.serverInfo?.name ?? "Jellyfin Server"
    }

    private var serverAddress: String {
        appState.serverURL?.host ?? appState.serverURL?.absoluteString ?? "Unknown"
    }

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            #if os(tvOS)
            tvOSLayout
            #else
            iOSLayout
            #endif
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .alert("Log Out", isPresented: $showLogOutAlert) {
            Button("Log Out", role: .destructive) {
                appState.logout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will be returned to the server setup screen.")
        }
    }

    // MARK: - iOS Layout

    private var iOSLayout: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                profileHeader
                    .padding(.top, CinemaSpacing.spacing3)

                infrastructureSection

                personalizationSection

                accountSection
            }
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.bottom, CinemaSpacing.spacing8)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - tvOS Layout
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    #if os(tvOS)
    @FocusState private var focusedItem: SettingsFocus?
    @State private var serverUsers: [UserDto] = []
    @State private var showSwitchAccountAlert = false

    @AppStorage("motionEffects") private var motionEffects: Bool = true
    @AppStorage("forceSubtitles") private var forceSubtitles: Bool = false
    @AppStorage("render4K") private var render4K: Bool = true

    private var tvOSLayout: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                // Two-column layout
                HStack(alignment: .top, spacing: CinemaSpacing.spacing6) {
                    // Left column
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                        tvAppearanceSection
                        tvProfileSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Right column
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                        tvServerSection
                        tvInterfaceSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing20)
            .padding(.bottom, CinemaSpacing.spacing8)
        }
        .task { await loadServerUsers() }
        .alert("Switch Account", isPresented: $showSwitchAccountAlert) {
            Button("Switch Account", role: .destructive) {
                appState.logout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will be logged out and returned to the login screen.")
        }
    }

    private func loadServerUsers() async {
        do {
            serverUsers = try await appState.apiClient.getUsers()
        } catch {
            do { serverUsers = try await appState.apiClient.getPublicUsers() } catch {}
        }
    }

    // MARK: - Appearance

    @AppStorage("darkMode") private var darkModeStorage: Bool = true

    private var tvAppearanceSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvSectionLabel("Appearance")

            tvGlassToggle(
                icon: darkModeStorage ? "moon.fill" : "sun.max.fill",
                label: darkModeStorage ? "Dark Mode" : "Light Mode",
                key: "darkMode",
                value: $darkModeStorage
            )
        }
    }

    // MARK: - Profile Management

    private var currentUserId: String {
        appState.currentUserId ?? ""
    }

    private var displayUsers: [UserDto] {
        let users: [UserDto]
        if serverUsers.isEmpty {
            if let session = appState.keychain.getUserSession() {
                users = [UserDto(id: session.userID, name: session.username)]
            } else {
                users = []
            }
        } else {
            users = serverUsers
        }
        return users.sorted { a, _ in a.id == currentUserId }
    }

    private var tvProfileSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvSectionLabel("Profiles")

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: CinemaSpacing.spacing3),
                    GridItem(.flexible(), spacing: CinemaSpacing.spacing3),
                    GridItem(.flexible(), spacing: CinemaSpacing.spacing3)
                ],
                spacing: CinemaSpacing.spacing3
            ) {
                ForEach(displayUsers, id: \.id) { user in
                    tvProfileBlock(user: user)
                }

                tvSwitchAccountBlock
            }
        }
    }

    private func tvProfileBlock(user: UserDto) -> some View {
        let userId = user.id ?? ""
        let isCurrentUser = userId == currentUserId
        let hasImage = user.primaryImageTag != nil
        let isFocused = focusedItem == .profile(userId)

        return Button {
            if !isCurrentUser { showSwitchAccountAlert = true }
        } label: {
            VStack(spacing: CinemaSpacing.spacing2) {
                Group {
                    if hasImage, let serverURL = appState.serverURL {
                        let imageURL = ImageURLBuilder(serverURL: serverURL)
                            .userImageURL(userId: userId, tag: user.primaryImageTag, maxWidth: 96)
                        AsyncImage(url: imageURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            tvUserInitial(name: user.name ?? "?", size: 36)
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                    } else {
                        tvUserInitial(name: user.name ?? "?", size: 36)
                    }
                }
                .opacity(isCurrentUser ? 1.0 : 0.55)

                Text(user.name ?? "User")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isFocused ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
                    .lineLimit(1)

                if isCurrentUser {
                    Text("Active")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: 0x34C759))
                } else {
                    Text(user.policy?.isAdministrator == true ? "Admin" : "User")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isFocused ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .padding(.vertical, CinemaSpacing.spacing3)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .profile(userId))
    }

    private var tvSwitchAccountBlock: some View {
        let isFocused = focusedItem == .switchAccount

        return Button {
            showSwitchAccountAlert = true
        } label: {
            VStack(spacing: CinemaSpacing.spacing2) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isFocused ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
                    .frame(width: 36, height: 36)

                Text("Switch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isFocused ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)

                Text("Account")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isFocused ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .padding(.vertical, CinemaSpacing.spacing3)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .switchAccount)
    }

    private func tvUserInitial(name: String, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [themeManager.accentContainer, themeManager.accent.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)

            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Server Connection

    private var tvServerSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvSectionLabel("Server")

            VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                HStack(spacing: CinemaSpacing.spacing3) {
                    ZStack {
                        Circle()
                            .fill(themeManager.accent.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "server.rack")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(themeManager.accent)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(serverName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(CinemaColor.onSurface)
                        Text(serverAddress)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(hex: 0x34C759))
                            .frame(width: 6, height: 6)
                        Text("Connected")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(hex: 0x34C759))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(hex: 0x34C759, alpha: 0.1)))
                }

                tvRefreshConnectionButton
            }
            .padding(CinemaSpacing.spacing4)
            .background(
                RoundedRectangle(cornerRadius: CinemaRadius.extraLarge)
                    .fill(CinemaColor.surfaceContainerLow)
                    .overlay(
                        RoundedRectangle(cornerRadius: CinemaRadius.extraLarge)
                            .fill(CinemaColor.surfaceVariant.opacity(0.6))
                    )
            )
        }
    }

    private var tvRefreshConnectionButton: some View {
        let isFocused = focusedItem == .refreshConnection

        return Button {
            Task { await appState.restoreSession() }
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 24)

                Text("Refresh Connection")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)

                Spacer()
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .refreshConnection)
    }

    // MARK: - Interface Options

    private var tvInterfaceSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvSectionLabel("Interface")

            tvGlassToggle(icon: "sparkles", label: "Motion Effects", key: "motion", value: $motionEffects)
            tvGlassToggle(icon: "captions.bubble", label: "Force Subtitles", key: "subtitles", value: $forceSubtitles)
            tvGlassToggle(icon: "4k.tv", label: "4K UI Rendering", key: "4k", value: $render4K)
        }
    }

    private func tvGlassToggle(icon: String, label: String, key: String, value: Binding<Bool>) -> some View {
        let isFocused = focusedItem == .toggle(key)

        return Button {
            value.wrappedValue.toggle()
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 24)

                Text(label)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)

                Spacer()

                // Custom toggle indicator
                Capsule()
                    .fill(value.wrappedValue ? themeManager.accent : CinemaColor.surfaceContainerHighest)
                    .frame(width: 52, height: 32)
                    .overlay(alignment: value.wrappedValue ? .trailing : .leading) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 26, height: 26)
                            .padding(3)
                    }
                    .animation(.easeInOut(duration: 0.15), value: value.wrappedValue)
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .toggle(key))
    }

    // MARK: - tvOS Helpers

    private func tvSectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .tracking(1.5)
    }

    #endif // os(tvOS)

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - iOS Components
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // MARK: - Profile Header (iOS)

    private var profileHeader: some View {
        HStack(spacing: CinemaSpacing.spacing4) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [themeManager.accentContainer, themeManager.accent.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: avatarSize, height: avatarSize)

                Text(userInitial)
                    .font(.system(size: avatarFontSize, weight: .bold, design: .default))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                Text(username)
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurface)

                Text("Premium Member \u{2022} Managed Profile")
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }

            Spacer()
        }
        .padding(CinemaSpacing.spacing4)
        .glassPanel(cornerRadius: CinemaRadius.extraLarge)
    }

    // MARK: - Infrastructure Section

    private var infrastructureSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            sectionHeader("Infrastructure")

            HStack(spacing: CinemaSpacing.spacing3) {
                ZStack {
                    RoundedRectangle(cornerRadius: CinemaRadius.medium)
                        .fill(themeManager.accent.opacity(0.15))
                        .frame(width: 40, height: 40)

                    Image(systemName: "server.rack")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(themeManager.accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(serverName)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)

                    Text(serverAddress)
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                HStack(spacing: CinemaSpacing.spacing2) {
                    liveBadge

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CinemaColor.outlineVariant)
                }
            }
            .padding(CinemaSpacing.spacing4)
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        }
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(hex: 0x34C759))
                .frame(width: 6, height: 6)

            Text("LIVE")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Color(hex: 0x34C759))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(hex: 0x34C759, alpha: 0.12)))
    }

    // MARK: - Personalization Section (iOS)

    private var personalizationSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            sectionHeader("Personalization")

            VStack(spacing: 0) {
                settingsRow {
                    HStack {
                        rowIcon(systemName: "moon.fill", color: themeManager.accent)

                        Text("Dark Mode")
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurface)

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { themeManager.darkModeEnabled },
                            set: { themeManager.darkModeEnabled = $0 }
                        ))
                        .labelsHidden()
                        .tint(themeManager.accentContainer)
                    }
                }

                divider

                settingsRow {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                        HStack {
                            rowIcon(systemName: "paintpalette.fill", color: selectedAccent.color)

                            Text("Accent Color")
                                .font(CinemaFont.label(.large))
                                .foregroundStyle(CinemaColor.onSurface)

                            Spacer()
                        }

                        HStack(spacing: CinemaSpacing.spacing2) {
                            ForEach(AccentOption.allCases) { option in
                                accentDot(option)
                            }
                        }
                    }
                }
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        }
    }

    private var selectedAccent: AccentOption {
        AccentOption(rawValue: themeManager.accentColorKey) ?? .blue
    }

    @ViewBuilder
    private func accentDot(_ option: AccentOption) -> some View {
        let isSelected = option.rawValue == themeManager.accentColorKey

        Button {
            themeManager.accentColorKey = option.rawValue
        } label: {
            ZStack {
                Circle()
                    .fill(option.color)
                    .frame(width: accentDotSize, height: accentDotSize)

                if isSelected {
                    Circle()
                        .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                        .frame(width: accentDotSize, height: accentDotSize)

                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.1 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }

    // MARK: - Account Section

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            sectionHeader("Account")

            VStack(spacing: 0) {
                navigationRow(icon: "person.crop.circle", label: "Profile Settings") {}

                divider

                navigationRow(icon: "lock.shield", label: "Privacy & Security") {}

                divider

                settingsRow {
                    Button {
                        showLogOutAlert = true
                    } label: {
                        HStack {
                            rowIcon(systemName: "rectangle.portrait.and.arrow.right", color: CinemaColor.error)

                            Text("Log Out")
                                .font(CinemaFont.label(.large))
                                .foregroundStyle(CinemaColor.error)

                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        }
    }

    // MARK: - Reusable iOS Helpers

    @ViewBuilder
    private func navigationRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        settingsRow {
            Button(action: action) {
                HStack {
                    rowIcon(systemName: icon, color: CinemaColor.onSurfaceVariant)

                    Text(label)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CinemaColor.outlineVariant)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing3)
    }

    @ViewBuilder
    private func rowIcon(systemName: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: CinemaRadius.small)
                .fill(color.opacity(0.12))
                .frame(width: 32, height: 32)

            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.trailing, CinemaSpacing.spacing2)
    }

    private var divider: some View {
        Rectangle()
            .fill(CinemaColor.surfaceContainerHighest.opacity(0.6))
            .frame(height: 1)
            .padding(.leading, CinemaSpacing.spacing4 + 32 + CinemaSpacing.spacing2)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(CinemaFont.label(.small))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .tracking(1.2)
            .padding(.horizontal, CinemaSpacing.spacing2)
    }

    // MARK: - Platform-adaptive sizes

    private var avatarSize: CGFloat {
        #if os(tvOS)
        80
        #else
        56
        #endif
    }

    private var avatarFontSize: CGFloat {
        #if os(tvOS)
        34
        #else
        24
        #endif
    }

    private var accentDotSize: CGFloat {
        #if os(tvOS)
        40
        #else
        28
        #endif
    }
}

// MARK: - tvOS Settings Focus Style

#if os(tvOS)
private extension View {
    func tvSettingsFocusable(isFocused: Bool, accent: Color) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .fill(CinemaColor.surfaceContainerHigh)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .strokeBorder(accent.opacity(isFocused ? 0.8 : 0), lineWidth: 1.5)
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
#endif
