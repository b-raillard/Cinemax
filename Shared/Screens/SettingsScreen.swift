import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI
#if canImport(UIKit)
import UIKit
#endif
import Network

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

// MARK: - Settings Category

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance
    case account
    case server
    case interface

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance: "paintpalette"
        case .account:    "person"
        case .server:     "server.rack"
        case .interface:  "tv"
        }
    }

    @MainActor func localizedName(_ loc: LocalizationManager) -> String {
        switch self {
        case .appearance: loc.localized("settings.appearance")
        case .account:    loc.localized("settings.account")
        case .server:     loc.localized("settings.server")
        case .interface:  loc.localized("settings.interface")
        }
    }

    @MainActor func subtitle(_ loc: LocalizationManager, themeManager: ThemeManager) -> String? {
        switch self {
        case .appearance:
            themeManager.darkModeEnabled ? loc.localized("settings.darkMode") : loc.localized("settings.lightMode")
        default:
            nil
        }
    }
}

// MARK: - tvOS Focus Tracking

#if os(tvOS)
private enum SettingsFocus: Hashable {
    case category(String)
    case back
    case profile(String)
    case switchAccount
    case refreshConnection
    case toggle(String)
    case accentColor(String)
    case language(String)
}
#endif

// MARK: - Settings Screen

struct SettingsScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State private var showLogOutAlert = false
    @State private var selectedCategory: SettingsCategory? = nil

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

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.6.0"
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .alert(loc.localized("action.logOut"), isPresented: $showLogOutAlert) {
            Button(loc.localized("action.logOut"), role: .destructive) {
                appState.logout()
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("settings.logOutConfirm"))
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - iOS Layout
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    #if os(iOS)
    private var iOSLayout: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    iOSHeader
                    iOSNavigationList
                    iOSDeviceInfo
                }
            }
            .background(CinemaColor.surfaceContainerLowest)
            .navigationDestination(item: $selectedCategory) { category in
                settingsDetailView(for: category)
            }
        }
    }

    // MARK: iOS Header

    private var iOSHeader: some View {
        VStack(spacing: CinemaSpacing.spacing3) {
            // Logo with ambient glow
            ZStack {
                // Glow
                Circle()
                    .fill(themeManager.accent.opacity(0.2))
                    .frame(width: 160, height: 160)
                    .blur(radius: 40)

                Image("AppLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .shadow(color: themeManager.accent.opacity(0.4), radius: 15)
            }

            VStack(spacing: CinemaSpacing.spacing1) {
                Text(loc.localized("settings.systemSettings"))
                    .font(.system(size: 28, weight: .heavy, design: .default))
                    .foregroundStyle(.white)
                    .tracking(-0.5)

                Text(loc.localized("settings.version", appVersion))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .tracking(0.5)
            }
        }
        .padding(.top, CinemaSpacing.spacing8)
        .padding(.bottom, CinemaSpacing.spacing6)
    }

    // MARK: iOS Navigation List

    private var iOSNavigationList: some View {
        VStack(spacing: CinemaSpacing.spacing2) {
            ForEach(SettingsCategory.allCases) { category in
                iOSCategoryButton(category)
            }
        }
        .padding(.horizontal, CinemaSpacing.spacing4)
    }

    @ViewBuilder
    private func iOSCategoryButton(_ category: SettingsCategory) -> some View {
        let isFirst = category == .appearance

        Button {
            selectedCategory = category
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                // Icon circle
                ZStack {
                    Circle()
                        .fill(isFirst ? Color.white.opacity(0.2) : CinemaColor.surfaceContainerHighest)
                        .frame(width: 40, height: 40)

                    Image(systemName: category.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isFirst ? .white : themeManager.accent)
                }

                // Label
                Text(category.localizedName(loc))
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(isFirst ? .white : CinemaColor.onSurface)

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isFirst ? Color.white.opacity(0.8) : CinemaColor.onSurfaceVariant.opacity(0.6))
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing3)
            .background {
                if isFirst {
                    RoundedRectangle(cornerRadius: CinemaRadius.extraLarge)
                        .fill(themeManager.accentContainer)
                } else {
                    RoundedRectangle(cornerRadius: CinemaRadius.extraLarge)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: CinemaRadius.extraLarge)
                                .fill(CinemaColor.surfaceContainerHigh.opacity(0.6))
                        )
                }
            }
            .shadow(color: isFirst ? themeManager.accentContainer.opacity(0.3) : .clear, radius: 20, y: 4)
            .overlay(
                RoundedRectangle(cornerRadius: CinemaRadius.extraLarge)
                    .strokeBorder(Color.white.opacity(isFirst ? 0.1 : 0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: iOS Device Info

    private var iOSDeviceInfo: some View {
        VStack(spacing: CinemaSpacing.spacing2) {
            Rectangle()
                .fill(CinemaColor.surfaceContainerHighest)
                .frame(width: 48, height: 3)
                .clipShape(Capsule())

            Text(loc.localized("settings.authenticatedDevice").uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(2)
                .foregroundStyle(CinemaColor.onSurfaceVariant)

            Text(deviceName)
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurface)
        }
        .opacity(0.4)
        .padding(.top, CinemaSpacing.spacing8)
        .padding(.bottom, CinemaSpacing.spacing6)
    }
    #endif

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
        Group {
            if let category = selectedCategory {
                tvDetailView(for: category)
                    .onExitCommand { selectedCategory = nil }
            } else {
                tvLandingPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Centered accent bloom — persists across all settings pages
            Circle()
                .fill(themeManager.accent.opacity(0.3))
                .frame(width: 1200, height: 1200)
                .blur(radius: 280)
        }
        .task { await loadServerUsers() }
        .alert(loc.localized("settings.switchAccount"), isPresented: $showSwitchAccountAlert) {
            Button(loc.localized("settings.switchAccount"), role: .destructive) {
                appState.logout()
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("settings.switchAccountConfirm"))
        }
    }

    // MARK: tvOS Landing Page

    private var tvLandingPage: some View {
        HStack(spacing: 0) {
            // Left Side: Identity & Logo (40%)
            tvBrandPanel
                .frame(maxWidth: .infinity)

            // Right Side: Navigation Categories (60%)
            tvNavigationPanel
                .frame(maxWidth: .infinity)
        }
    }

    private var tvBrandPanel: some View {
        VStack(spacing: CinemaSpacing.spacing6) {
            Spacer()

            Image("AppLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 400, height: 400)
                .shadow(color: themeManager.accent.opacity(0.5), radius: 40)

            VStack(spacing: CinemaSpacing.spacing2) {
                Text(loc.localized("settings.systemSettings"))
                    .font(.system(size: CinemaScale.pt(48), weight: .heavy))
                    .foregroundStyle(.white)
                    .tracking(-1)

                Text(loc.localized("settings.version", appVersion))
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .opacity(0.8)
                    .tracking(0.5)
            }

            Spacer()
        }
    }

    private var tvNavigationPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                ForEach(SettingsCategory.allCases) { category in
                    tvCategoryButton(category)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing10)

            Spacer()

            // System Information bar
            tvSystemInfoBar
                .padding(.horizontal, CinemaSpacing.spacing10)
                .padding(.bottom, CinemaSpacing.spacing8)
        }
    }

    @ViewBuilder
    private func tvCategoryButton(_ category: SettingsCategory) -> some View {
        let isFocused = focusedItem == .category(category.rawValue)

        Button {
            selectedCategory = category
        } label: {
            HStack(spacing: CinemaSpacing.spacing4) {
                // Icon circle
                ZStack {
                    Circle()
                        .fill(isFocused ? Color.white.opacity(0.2) : CinemaColor.surfaceContainerHighest)
                        .frame(width: 56, height: 56)

                    Image(systemName: category.icon)
                        .font(.system(size: CinemaScale.pt(24), weight: .semibold))
                        .foregroundStyle(isFocused ? .white : CinemaColor.onSurfaceVariant)
                }

                // Label
                Text(category.localizedName(loc))
                    .font(.system(size: CinemaScale.pt(28), weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(isFocused ? .white : CinemaColor.onSurfaceVariant)

                Spacer()

                // Subtitle + chevron
                if let subtitle = category.subtitle(loc, themeManager: themeManager), isFocused {
                    Text(subtitle)
                        .font(.system(size: CinemaScale.pt(18), weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.7))
                }

                if isFocused {
                    Image(systemName: "chevron.right")
                        .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing5)
            .padding(.vertical, CinemaSpacing.spacing4)
            .background(
                RoundedRectangle(cornerRadius: 9999)
                    .fill(isFocused ? themeManager.accentContainer : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9999)
                    .strokeBorder(Color.white.opacity(isFocused ? 0.1 : 0), lineWidth: 4)
            )
            .shadow(color: isFocused ? themeManager.accentContainer.opacity(0.4) : .clear, radius: 40)
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(motionEffects ? .easeOut(duration: 0.2) : nil, value: isFocused)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .category(category.rawValue))
    }

    private var tvSystemInfoBar: some View {
        HStack(spacing: CinemaSpacing.spacing8) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                Text(loc.localized("settings.deviceName"))
                    .font(.system(size: CinemaScale.pt(14), weight: .regular))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)

                Text(deviceName)
                    .font(.system(size: CinemaScale.pt(18), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)
            }

            VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                Text(loc.localized("settings.network"))
                    .font(.system(size: CinemaScale.pt(14), weight: .regular))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)

                Text(networkName)
                    .font(.system(size: CinemaScale.pt(18), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)
            }
        }
        .padding(CinemaSpacing.spacing5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: tvOS Detail Views

    @ViewBuilder
    private func tvDetailView(for category: SettingsCategory) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                // Back button
                let backFocused = focusedItem == .back
                Button {
                    selectedCategory = nil
                } label: {
                    HStack(spacing: CinemaSpacing.spacing2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                        Text(category.localizedName(loc))
                            .font(.system(size: CinemaScale.pt(28), weight: .bold))
                    }
                    .foregroundStyle(backFocused ? themeManager.accent : CinemaColor.onSurface)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .hoverEffectDisabled()
                .focused($focusedItem, equals: .back)

                switch category {
                case .appearance:
                    tvAppearanceDetail
                case .account:
                    tvAccountDetail
                case .server:
                    tvServerDetail
                case .interface:
                    tvInterfaceDetail
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing20)
            .padding(.vertical, CinemaSpacing.spacing8)
        }
    }

    // MARK: Appearance Detail (tvOS)

    @AppStorage("darkMode") private var darkModeStorage: Bool = true

    private var tvAppearanceDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvGlassToggle(
                icon: darkModeStorage ? "moon.fill" : "sun.max.fill",
                label: darkModeStorage ? loc.localized("settings.darkMode") : loc.localized("settings.lightMode"),
                key: "darkMode",
                value: $darkModeStorage
            )

            tvAccentColorPicker

            tvLanguagePicker
        }
    }

    // MARK: Account Detail (tvOS)

    private var tvAccountDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            tvProfileSection
        }
    }

    // MARK: Server Detail (tvOS)

    private var tvServerDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                HStack(spacing: CinemaSpacing.spacing3) {
                    ZStack {
                        Circle()
                            .fill(themeManager.accent.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "server.rack")
                            .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                            .foregroundStyle(themeManager.accent)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(serverName)
                            .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                            .foregroundStyle(CinemaColor.onSurface)
                        Text(serverAddress)
                            .font(.system(size: CinemaScale.pt(15), weight: .regular))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(hex: 0x34C759))
                            .frame(width: 6, height: 6)
                        Text(loc.localized("settings.connected"))
                            .font(.system(size: CinemaScale.pt(14), weight: .bold))
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

    // MARK: Interface Detail (tvOS)

    private var tvInterfaceDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvGlassToggle(icon: "sparkles", label: loc.localized("settings.motionEffects"), key: "motion", value: $motionEffects)
            tvGlassToggle(icon: "captions.bubble", label: loc.localized("settings.forceSubtitles"), key: "subtitles", value: $forceSubtitles)
            tvGlassToggle(icon: "4k.tv", label: loc.localized("settings.4kRendering"), key: "4k", value: $render4K)

            tvFontSizeRow
        }
    }

    // MARK: - tvOS Reusable Components

    private func loadServerUsers() async {
        do {
            serverUsers = try await appState.apiClient.getUsers()
        } catch {
            do { serverUsers = try await appState.apiClient.getPublicUsers() } catch {}
        }
    }

    private let languageCodes = ["fr", "en"]

    private var tvLanguagePicker: some View {
        let isFocused = focusedItem == .language("row")

        return Button {
            // Toggle between languages on press
            loc.languageCode = loc.languageCode == "fr" ? "en" : "fr"
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "globe")
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 24)

                Text(loc.localized("settings.language"))
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)

                Spacer()

                HStack(spacing: CinemaSpacing.spacing2) {
                    tvLanguageChip("fr", label: loc.localized("settings.language.french"))
                    tvLanguageChip("en", label: loc.localized("settings.language.english"))
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, animated: motionEffects)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .language("row"))
        .onMoveCommand { direction in
            guard isFocused else { return }
            switch direction {
            case .left, .right:
                loc.languageCode = loc.languageCode == "fr" ? "en" : "fr"
            default:
                break
            }
        }
    }

    private func tvLanguageChip(_ code: String, label: String) -> some View {
        let isSelected = loc.languageCode == code

        return Text(label)
            .font(.system(size: CinemaScale.pt(20), weight: isSelected ? .bold : .medium))
            .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurfaceVariant)
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing2)
            .background(
                RoundedRectangle(cornerRadius: CinemaRadius.medium)
                    .fill(isSelected ? themeManager.accent : CinemaColor.surfaceContainerHigh)
            )
    }

    private var tvAccentColorPicker: some View {
        let isFocused = focusedItem == .accentColor("row")
        let allOptions = AccentOption.allCases

        return Button {
            // Cycle to next accent color on press
            if let currentIndex = allOptions.firstIndex(where: { $0.rawValue == themeManager.accentColorKey }) {
                let nextIndex = (allOptions.distance(from: allOptions.startIndex, to: currentIndex) + 1) % allOptions.count
                themeManager.accentColorKey = allOptions[allOptions.index(allOptions.startIndex, offsetBy: nextIndex)].rawValue
            }
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 24)

                Text(loc.localized("settings.accentColor"))
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)

                Spacer()

                HStack(spacing: CinemaSpacing.spacing3) {
                    ForEach(allOptions) { option in
                        tvAccentDotDisplay(option)
                    }
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, animated: motionEffects)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .accentColor("row"))
        .onMoveCommand { direction in
            guard isFocused else { return }
            let allOpts = AccentOption.allCases
            if let currentIndex = allOpts.firstIndex(where: { $0.rawValue == themeManager.accentColorKey }) {
                let idx = allOpts.distance(from: allOpts.startIndex, to: currentIndex)
                switch direction {
                case .left:
                    if idx > 0 {
                        themeManager.accentColorKey = allOpts[allOpts.index(allOpts.startIndex, offsetBy: idx - 1)].rawValue
                    }
                case .right:
                    if idx < allOpts.count - 1 {
                        themeManager.accentColorKey = allOpts[allOpts.index(allOpts.startIndex, offsetBy: idx + 1)].rawValue
                    }
                default:
                    break
                }
            }
        }
    }

    private func tvAccentDotDisplay(_ option: AccentOption) -> some View {
        let isSelected = option.rawValue == themeManager.accentColorKey

        return ZStack {
            Circle()
                .fill(option.color)
                .frame(width: 36, height: 36)

            if isSelected {
                Circle()
                    .strokeBorder(.white.opacity(0.9), lineWidth: 2.5)
                    .frame(width: 36, height: 36)

                Image(systemName: "checkmark")
                    .font(.system(size: CinemaScale.pt(14), weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 48, height: 48)
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
            tvSectionLabel(loc.localized("settings.profiles"))

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
                    .font(.system(size: CinemaScale.pt(17), weight: .semibold))
                    .foregroundStyle(isFocused ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
                    .lineLimit(1)

                if isCurrentUser {
                    Text(loc.localized("settings.active"))
                        .font(.system(size: CinemaScale.pt(13), weight: .bold))
                        .foregroundStyle(Color(hex: 0x34C759))
                } else {
                    Text(user.policy?.isAdministrator == true ? loc.localized("settings.admin") : loc.localized("settings.user"))
                        .font(.system(size: CinemaScale.pt(13), weight: .medium))
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
                    .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                    .foregroundStyle(isFocused ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
                    .frame(width: 36, height: 36)

                Text(loc.localized("settings.switchAccount"))
                    .font(.system(size: CinemaScale.pt(17), weight: .semibold))
                    .foregroundStyle(isFocused ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
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

    private var tvRefreshConnectionButton: some View {
        let isFocused = focusedItem == .refreshConnection

        return Button {
            Task { await appState.restoreSession() }
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 24)

                Text(loc.localized("settings.refreshConnection"))
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
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

    @State private var fontScale: Double = UserDefaults.standard.object(forKey: "uiScale") as? Double ?? 1.0
    @State private var showFontSizePicker = false

    private let fontScaleOptions: [Double] = [0.80, 0.85, 0.90, 0.95, 1.00, 1.05, 1.10, 1.15, 1.20, 1.25, 1.30]

    private var tvFontSizeRow: some View {
        let isFocused = focusedItem == .toggle("fontSize")
        return Button {
            showFontSizePicker = true
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "textformat.size")
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 24)
                Text(loc.localized("settings.fontSize"))
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                Text("\(Int(fontScale * 100))%")
                    .font(.system(size: CinemaScale.pt(17), weight: .semibold))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .monospacedDigit()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: CinemaScale.pt(14), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, animated: motionEffects)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .toggle("fontSize"))
        .confirmationDialog(loc.localized("settings.fontSize"), isPresented: $showFontSizePicker) {
            ForEach(fontScaleOptions, id: \.self) { option in
                Button("\(Int(option * 100))%") {
                    fontScale = option
                    themeManager.uiScale = option
                }
            }
        }
    }

    private func tvGlassToggle(icon: String, label: String, key: String, value: Binding<Bool>) -> some View {
        let isFocused = focusedItem == .toggle(key)

        return Button {
            value.wrappedValue.toggle()
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: icon)
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 24)

                Text(label)
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
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
                    .animation(motionEffects ? .easeInOut(duration: 0.15) : nil, value: value.wrappedValue)
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, animated: motionEffects)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .toggle(key))
    }

    // MARK: - tvOS Helpers

    private func tvSectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: CinemaScale.pt(17), weight: .bold))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .tracking(1.5)
    }

    #endif // os(tvOS)

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - iOS Detail Views
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    #if os(iOS)
    @ViewBuilder
    private func settingsDetailView(for category: SettingsCategory) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                switch category {
                case .appearance:
                    iOSAppearanceDetail
                case .account:
                    iOSAccountDetail
                case .server:
                    iOSServerDetail
                case .interface:
                    iOSInterfaceDetail
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.bottom, CinemaSpacing.spacing8)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(category.localizedName(loc))
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: Appearance Detail (iOS)

    private var iOSAppearanceDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            sectionHeader(loc.localized("settings.personalization"))

            VStack(spacing: 0) {
                settingsRow {
                    HStack {
                        rowIcon(systemName: "moon.fill", color: themeManager.accent)

                        Text(loc.localized("settings.darkMode"))
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

                            Text(loc.localized("settings.accentColor"))
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

                divider

                settingsRow {
                    HStack {
                        rowIcon(systemName: "globe", color: themeManager.accent)

                        Text(loc.localized("settings.language"))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurface)

                        Spacer()

                        languagePicker
                    }
                }
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        }
    }

    // MARK: Account Detail (iOS)

    private var iOSAccountDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            profileHeader

            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                sectionHeader(loc.localized("settings.account"))

                VStack(spacing: 0) {
                    navigationRow(icon: "person.crop.circle", label: loc.localized("settings.profileSettings")) {}

                    divider

                    navigationRow(icon: "lock.shield", label: loc.localized("settings.privacySecurity")) {}

                    divider

                    settingsRow {
                        Button {
                            showLogOutAlert = true
                        } label: {
                            HStack {
                                rowIcon(systemName: "rectangle.portrait.and.arrow.right", color: CinemaColor.error)

                                Text(loc.localized("action.logOut"))
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
    }

    // MARK: Server Detail (iOS)

    private var iOSServerDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            sectionHeader(loc.localized("settings.infrastructure"))

            HStack(spacing: CinemaSpacing.spacing3) {
                ZStack {
                    RoundedRectangle(cornerRadius: CinemaRadius.medium)
                        .fill(themeManager.accent.opacity(0.15))
                        .frame(width: 40, height: 40)

                    Image(systemName: "server.rack")
                        .font(.system(size: CinemaScale.pt(20), weight: .semibold))
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
                        .font(.system(size: CinemaScale.pt(15), weight: .semibold))
                        .foregroundStyle(CinemaColor.outlineVariant)
                }
            }
            .padding(CinemaSpacing.spacing4)
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        }
    }

    // MARK: Interface Detail (iOS)

    private var iOSInterfaceDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            sectionHeader(loc.localized("settings.interface"))

            VStack(spacing: 0) {
                settingsRow {
                    HStack {
                        rowIcon(systemName: "sparkles", color: themeManager.accent)

                        Text(loc.localized("settings.motionEffects"))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurface)

                        Spacer()

                        Toggle("", isOn: .init(
                            get: { UserDefaults.standard.bool(forKey: "motionEffects") },
                            set: { UserDefaults.standard.set($0, forKey: "motionEffects") }
                        ))
                        .labelsHidden()
                        .tint(themeManager.accentContainer)
                    }
                }
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        }
    }
    #endif

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Shared Helpers
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var deviceName: String {
        #if os(tvOS)
        UIDevice.current.name
        #elseif os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    private var networkName: String {
        // Fallback display — actual SSID requires entitlements
        serverAddress
    }

    // MARK: - iOS Reusable Components

    #if os(iOS)
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
                    .frame(width: 56, height: 56)

                Text(userInitial)
                    .font(.system(size: 24, weight: .bold, design: .default))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                Text(username)
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurface)

                Text(loc.localized("settings.premiumMember"))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }

            Spacer()
        }
        .padding(CinemaSpacing.spacing4)
        .glassPanel(cornerRadius: CinemaRadius.extraLarge)
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(hex: 0x34C759))
                .frame(width: 6, height: 6)

            Text(loc.localized("settings.live"))
                .font(.system(size: CinemaScale.pt(13), weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Color(hex: 0x34C759))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(hex: 0x34C759, alpha: 0.12)))
    }

    private var languagePicker: some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            languageButton("fr", label: "FR")
            languageButton("en", label: "EN")
        }
    }

    private func languageButton(_ code: String, label: String) -> some View {
        let isSelected = loc.languageCode == code
        return Button {
            loc.languageCode = code
        } label: {
            Text(label)
                .font(.system(size: CinemaScale.pt(17), weight: .bold))
                .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurfaceVariant)
                .frame(width: 40, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: CinemaRadius.medium)
                        .fill(isSelected ? themeManager.accent : CinemaColor.surfaceContainerHigh)
                )
        }
        .buttonStyle(.plain)
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
                    .frame(width: 28, height: 28)

                if isSelected {
                    Circle()
                        .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                        .frame(width: 28, height: 28)

                    Image(systemName: "checkmark")
                        .font(.system(size: CinemaScale.pt(13), weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.1 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }

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
                        .font(.system(size: CinemaScale.pt(15), weight: .semibold))
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
    #endif
}

// MARK: - tvOS Settings Focus Style

#if os(tvOS)
private extension View {
    func tvSettingsFocusable(isFocused: Bool, accent: Color, animated: Bool = true) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .fill(CinemaColor.surfaceContainerHigh)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .strokeBorder(accent.opacity(isFocused ? 0.8 : 0), lineWidth: 1.5)
            )
            .animation(animated ? .easeOut(duration: 0.15) : nil, value: isFocused)
    }
}

#endif
