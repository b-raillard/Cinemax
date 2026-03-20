import SwiftUI

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

// MARK: - Settings Tab (tvOS)

#if os(tvOS)
private enum SettingsTab: String, CaseIterable, Identifiable {
    case personalization = "Personalization"
    case playback        = "Playback"
    case display         = "Display"
    case library         = "Library"
    case advanced        = "Advanced"

    var id: String { rawValue }
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

    // MARK: - tvOS Layout

    #if os(tvOS)
    @State private var selectedTab: SettingsTab = .personalization

    private var tvOSLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Large title
            Text("Settings")
                .font(.system(size: 56, weight: .heavy))
                .foregroundStyle(CinemaColor.onSurface)
                .padding(.horizontal, CinemaSpacing.spacing20)
                .padding(.top, CinemaSpacing.spacing8)
                .padding(.bottom, CinemaSpacing.spacing5)

            // Tab bar
            tvTabBar
                .padding(.horizontal, CinemaSpacing.spacing20)
                .padding(.bottom, CinemaSpacing.spacing8)

            // Content area
            switch selectedTab {
            case .personalization:
                tvPersonalizationContent
            default:
                tvPlaceholderContent(for: selectedTab)
            }

            Spacer()
        }
    }

    private var tvTabBar: some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 20, weight: selectedTab == tab ? .bold : .medium))
                        .foregroundStyle(
                            selectedTab == tab
                                ? themeManager.accent
                                : CinemaColor.onSurfaceVariant
                        )
                        .padding(.horizontal, CinemaSpacing.spacing4)
                        .padding(.vertical, CinemaSpacing.spacing2)
                        .background(
                            selectedTab == tab
                                ? themeManager.accent.opacity(0.12)
                                : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Personalization Tab Content

    private var tvPersonalizationContent: some View {
        HStack(alignment: .top, spacing: CinemaSpacing.spacing8) {
            // Left column
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                    tvAppearanceSection
                    tvProfileManagementSection
                }
            }
            .frame(maxWidth: .infinity)

            // Right column
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                    tvConnectionIntegrityCard
                    tvInterfaceOptionsSection
                }
            }
            .frame(width: 420)
        }
        .padding(.horizontal, CinemaSpacing.spacing20)
    }

    // MARK: - Appearance Theme Section

    private var tvAppearanceSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
            tvSectionHeader(icon: "circle.lefthalf.filled", label: "Appearance Theme")

            // Dark / Light pill buttons
            HStack(spacing: CinemaSpacing.spacing3) {
                tvThemeButton(
                    title: "Dark",
                    icon: "moon.fill",
                    isSelected: themeManager.darkModeEnabled
                ) {
                    themeManager.darkModeEnabled = true
                }

                tvThemeButton(
                    title: "Light",
                    icon: "sun.max.fill",
                    isSelected: !themeManager.darkModeEnabled
                ) {
                    themeManager.darkModeEnabled = false
                }
            }

            // Description
            Text("Optimize your viewing experience for low-light environments. Dark mode reduces eye strain and power consumption on OLED panels.")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, CinemaSpacing.spacing1)
        }
    }

    private func tvThemeButton(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: CinemaSpacing.spacing2) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(isSelected ? .white : CinemaColor.onSurfaceVariant)
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing2)
            .background(
                isSelected
                    ? themeManager.accentContainer
                    : CinemaColor.surfaceContainerHigh,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .focusable()
        .scaleEffect(1.0)
    }

    // MARK: - Profile Management Section

    @State private var tvProfiles: [(name: String, role: String)] = [
        (name: "John Doe", role: "Admin \u{2022} Full Access"),
        (name: "Family", role: "Restricted \u{2022} 2 Kids")
    ]

    private var tvProfileManagementSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
            tvSectionHeader(icon: "person.2.fill", label: "Profile Management")

            HStack(spacing: CinemaSpacing.spacing4) {
                // Profile cards
                ForEach(tvProfiles, id: \.name) { profile in
                    tvProfileCard(profile)
                }

                // Add New Profile card
                tvAddProfileCard
            }
        }
    }

    private func tvProfileCard(_ profile: (name: String, role: String)) -> some View {
        VStack(spacing: CinemaSpacing.spacing3) {
            // Avatar
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [themeManager.accentContainer, themeManager.accent.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 60, height: 60)

                Text(String(profile.name.prefix(1)))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 2) {
                Text(profile.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CinemaColor.onSurface)
                Text(profile.role)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 120)
        .padding(CinemaSpacing.spacing4)
        .glassPanel(cornerRadius: CinemaRadius.large)
    }

    private var tvAddProfileCard: some View {
        Button {
            // Add profile action
        } label: {
            VStack(spacing: CinemaSpacing.spacing3) {
                ZStack {
                    Circle()
                        .fill(CinemaColor.surfaceContainerHighest)
                        .frame(width: 60, height: 60)
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }

                Text("Add New Profile")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 120)
            .padding(CinemaSpacing.spacing4)
            .glassPanel(cornerRadius: CinemaRadius.large)
        }
        .buttonStyle(.plain)
        .focusable()
    }

    // MARK: - Connection Integrity Card

    private var tvConnectionIntegrityCard: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
            Text("CONNECTION INTEGRITY")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .tracking(1.5)

            VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                // Server info row
                HStack(spacing: CinemaSpacing.spacing3) {
                    // Server icon
                    ZStack {
                        Circle()
                            .fill(themeManager.accent.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: "server.rack")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(themeManager.accent)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(serverName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(CinemaColor.onSurface)
                        Text(serverAddress)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    liveBadge
                }

                // Uptime and latency row
                HStack(spacing: CinemaSpacing.spacing6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("UPTIME")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .tracking(1)
                        Text("14d 02h")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(CinemaColor.onSurface)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("LATENCY")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .tracking(1)
                        Text("12ms")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(CinemaColor.onSurface)
                    }
                }

                // Refresh Connection button
                Button {
                    Task { await appState.restoreSession() }
                } label: {
                    HStack(spacing: CinemaSpacing.spacing2) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Refresh Connection")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CinemaSpacing.spacing2)
                    .background(themeManager.accentContainer, in: RoundedRectangle(cornerRadius: CinemaRadius.large))
                }
                .buttonStyle(.plain)
                .focusable()
            }
            .padding(CinemaSpacing.spacing4)
            .glassPanel(cornerRadius: CinemaRadius.large)
        }
    }

    // MARK: - Interface Options Section

    @AppStorage("motionEffects") private var motionEffects: Bool = true
    @AppStorage("forceSubtitles") private var forceSubtitles: Bool = false
    @AppStorage("render4K") private var render4K: Bool = true

    private var tvInterfaceOptionsSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
            Text("Interface Options")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(CinemaColor.onSurface)

            VStack(spacing: 0) {
                tvToggleRow(
                    icon: "sparkles",
                    label: "Motion Effects",
                    value: $motionEffects
                )

                Divider()
                    .background(CinemaColor.surfaceContainerHighest)

                tvToggleRow(
                    icon: "captions.bubble",
                    label: "Force Subtitles",
                    value: $forceSubtitles
                )

                Divider()
                    .background(CinemaColor.surfaceContainerHighest)

                tvToggleRow(
                    icon: "4k.tv",
                    label: "4K UI Rendering",
                    value: $render4K
                )
            }
            .glassPanel(cornerRadius: CinemaRadius.large)
        }
    }

    private func tvToggleRow(icon: String, label: String, value: Binding<Bool>) -> some View {
        HStack(spacing: CinemaSpacing.spacing3) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .frame(width: 24)

            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(CinemaColor.onSurface)

            Spacer()

            Toggle("", isOn: value)
                .labelsHidden()
                .tint(themeManager.accentContainer)
        }
        .padding(.horizontal, CinemaSpacing.spacing4)
        .padding(.vertical, CinemaSpacing.spacing3)
    }

    // MARK: - Placeholder for other tabs

    private func tvPlaceholderContent(for tab: SettingsTab) -> some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 48))
                .foregroundStyle(CinemaColor.outlineVariant)
            Text("\(tab.rawValue) settings coming soon")
                .font(CinemaFont.headline(.small))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - tvOS Section Header Helper

    private func tvSectionHeader(icon: String, label: String) -> some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(themeManager.accent)
            Text(label)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(CinemaColor.onSurface)
        }
    }

    #endif // os(tvOS)

    // MARK: - Profile Header (iOS)

    private var profileHeader: some View {
        HStack(spacing: CinemaSpacing.spacing4) {
            // Avatar circle
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                themeManager.accentContainer,
                                themeManager.accent.opacity(0.6)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(
                        width: avatarSize,
                        height: avatarSize
                    )

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
                // Server icon
                ZStack {
                    RoundedRectangle(cornerRadius: CinemaRadius.medium)
                        .fill(themeManager.accent.opacity(0.15))
                        .frame(width: 40, height: 40)

                    Image(systemName: "server.rack")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(themeManager.accent)
                }

                // Server details
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

                // Status badge + chevron
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
        .background(
            Capsule()
                .fill(Color(hex: 0x34C759, alpha: 0.12))
        )
    }

    // MARK: - Personalization Section (iOS)

    private var personalizationSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            sectionHeader("Personalization")

            VStack(spacing: 0) {
                // Dark Mode toggle row
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

                // Accent Color row
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
        #if os(tvOS)
        .focusable()
        #endif
    }

    // MARK: - Account Section

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            sectionHeader("Account")

            VStack(spacing: 0) {
                // Profile Settings
                navigationRow(icon: "person.crop.circle", label: "Profile Settings") {}

                divider

                // Privacy & Security
                navigationRow(icon: "lock.shield", label: "Privacy & Security") {}

                divider

                // Log Out
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

    // MARK: - Reusable Row Helpers

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
