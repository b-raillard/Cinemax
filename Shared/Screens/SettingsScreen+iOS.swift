import SwiftUI
import CinemaxKit

// MARK: - iOS Layout

#if os(iOS)
extension SettingsScreen {

    var iOSLayout: some View {
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

    var iOSHeader: some View {
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
                    .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.extraLarge))
                    .shadow(color: themeManager.accent.opacity(0.4), radius: 15)
                    .accessibilityHidden(true)
            }

            VStack(spacing: CinemaSpacing.spacing1) {
                Text(loc.localized("settings.systemSettings"))
                    .font(.system(size: CinemaScale.pt(28), weight: .heavy, design: .default))
                    .foregroundStyle(CinemaColor.onSurface)
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

    var iOSNavigationList: some View {
        VStack(spacing: CinemaSpacing.spacing2) {
            ForEach(SettingsCategory.allCases) { category in
                iOSCategoryButton(category)
            }
        }
        .padding(.horizontal, CinemaSpacing.spacing4)
    }

    @ViewBuilder
    func iOSCategoryButton(_ category: SettingsCategory) -> some View {
        let isFirst = category == .appearance

        Button {
            selectedCategory = category
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                // Icon circle
                ZStack {
                    Circle()
                        .fill(isFirst ? themeManager.accent.opacity(0.18) : CinemaColor.surfaceContainerHighest)
                        .frame(width: 40, height: 40)

                    Image(systemName: category.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isFirst ? .white : themeManager.accent)
                }

                // Label
                Text(category.localizedName(loc))
                    .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(isFirst ? .white : CinemaColor.onSurface)

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                    .foregroundStyle(isFirst ? CinemaColor.onSurface.opacity(0.85) : CinemaColor.onSurfaceVariant.opacity(0.6))
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
                    .strokeBorder(CinemaColor.onSurface.opacity(isFirst ? 0.12 : 0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: iOS Device Info

    var iOSDeviceInfo: some View {
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

    // MARK: - iOS Detail Views

    @ViewBuilder
    func settingsDetailView(for category: SettingsCategory) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                switch category {
                case .appearance:
                    IOSAppearanceDetailView()
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

    // MARK: Account Detail (iOS)

    var iOSAccountDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            profileHeader

            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                iOSSettingsSectionHeader(loc.localized("settings.account"))

                VStack(spacing: 0) {
                    navigationRow(icon: "person.crop.circle", label: loc.localized("settings.profileSettings")) {}

                    iOSSettingsDivider

                    navigationRow(icon: "lock.shield", label: loc.localized("settings.privacySecurity")) {}

                    iOSSettingsDivider

                    navigationRow(icon: "person.2.circle", label: loc.localized("settings.switchAccount")) {
                        showUserSwitch = true
                    }

                    iOSSettingsDivider

                    iOSSettingsRow {
                        Button {
                            showLogOutAlert = true
                        } label: {
                            HStack {
                                iOSRowIcon(systemName: "rectangle.portrait.and.arrow.right", color: CinemaColor.error)

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

    var iOSServerDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                iOSSettingsSectionHeader(loc.localized("settings.infrastructure"))

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

            // Refresh Catalogue
            VStack(spacing: 0) {
                iOSSettingsRow {
                    Button { refreshCatalogue() } label: {
                        HStack(alignment: .center, spacing: CinemaSpacing.spacing3) {
                            iOSRowIcon(systemName: "arrow.triangle.2.circlepath", color: themeManager.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.localized("settings.refreshCatalogue"))
                                    .font(CinemaFont.label(.large))
                                    .foregroundStyle(CinemaColor.onSurface)
                                Text(loc.localized("settings.refreshCatalogue.subtitle"))
                                    .font(CinemaFont.label(.medium))
                                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)

            // Licenses
            VStack(spacing: 0) {
                navigationRow(icon: "doc.text", label: loc.localized("settings.licenses")) {
                    showLicenses = true
                }
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        }
    }

    // MARK: Interface Detail (iOS)

    var iOSInterfaceDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                iOSSettingsSectionHeader(loc.localized("settings.interface"))

                VStack(spacing: 0) {
                    iOSToggleRowsJoined(interfaceToggleRows, accent: themeManager.accent, animated: motionEffects)
                    iOSSettingsDivider

                    iOSSleepTimerRow
                    iOSSettingsDivider

                    iOSSettingsRow {
                        HStack {
                            iOSRowIcon(systemName: "textformat.size", color: themeManager.accent)
                            Text(loc.localized("settings.fontSize"))
                                .font(CinemaFont.label(.large))
                                .foregroundStyle(CinemaColor.onSurface)
                            Spacer()
                            Stepper(
                                "\(Int(fontScale * 100))%",
                                onIncrement: {
                                    if let idx = fontScaleOptions.firstIndex(of: fontScale), idx < fontScaleOptions.count - 1 {
                                        fontScale = fontScaleOptions[idx + 1]
                                        themeManager.uiScale = fontScale
                                    }
                                },
                                onDecrement: {
                                    if let idx = fontScaleOptions.firstIndex(of: fontScale), idx > 0 {
                                        fontScale = fontScaleOptions[idx - 1]
                                        themeManager.uiScale = fontScale
                                    }
                                }
                            )
                            .fixedSize()
                            .tint(themeManager.accent)
                        }
                    }
                }
                .glassPanel(cornerRadius: CinemaRadius.extraLarge)
            }

            // Home Page section
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                iOSSettingsSectionHeader(loc.localized("settings.homePage"))

                VStack(spacing: 0) {
                    iOSToggleRowsJoined(homePageToggleRows, accent: themeManager.accent, animated: motionEffects)
                }
                .glassPanel(cornerRadius: CinemaRadius.extraLarge)
            }

            // Detail Page section
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                iOSSettingsSectionHeader(loc.localized("settings.detailPage"))

                VStack(spacing: 0) {
                    iOSToggleRowsJoined(detailPageToggleRows, accent: themeManager.accent, animated: motionEffects)
                }
                .glassPanel(cornerRadius: CinemaRadius.extraLarge)
            }

            // Debug section
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                iOSSettingsSectionHeader(loc.localized("settings.debug"))

                VStack(spacing: 0) {
                    iOSToggleRowsJoined(debugToggleRows, accent: themeManager.accent, animated: motionEffects)
                }
                .glassPanel(cornerRadius: CinemaRadius.extraLarge)
            }
        }
    }

    // MARK: - iOS Reusable Components

    var profileHeader: some View {
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

    var liveBadge: some View {
        serverStatusBadge(label: loc.localized("settings.live"), fontSize: 13)
    }

    @ViewBuilder
    func navigationRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        iOSSettingsRow {
            Button(action: action) {
                HStack {
                    iOSRowIcon(systemName: icon, color: CinemaColor.onSurfaceVariant)

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
    // MARK: - Sleep Timer Row (iOS)

    /// Menu-based picker for the default sleep timer duration. Label matches the selected
    /// option's localized name ("Off", "30 minutes", etc.).
    @ViewBuilder
    var iOSSleepTimerRow: some View {
        iOSSettingsRow {
            HStack {
                iOSRowIcon(systemName: "moon.zzz", color: themeManager.accent)
                Text(loc.localized("settings.sleepTimer"))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                Menu {
                    ForEach(SleepTimerOption.allCases) { option in
                        Button {
                            sleepTimerMinutes = option.rawValue
                        } label: {
                            if sleepTimerMinutes == option.rawValue {
                                Label(loc.localized(option.localizationKey), systemImage: "checkmark")
                            } else {
                                Text(loc.localized(option.localizationKey))
                            }
                        }
                    }
                } label: {
                    let selected = SleepTimerOption(rawValue: sleepTimerMinutes) ?? .disabled
                    HStack(spacing: 4) {
                        Text(loc.localized(selected.localizationKey))
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
}

#endif
