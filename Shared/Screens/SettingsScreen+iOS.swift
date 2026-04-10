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
            }

            VStack(spacing: CinemaSpacing.spacing1) {
                Text(loc.localized("settings.systemSettings"))
                    .font(.system(size: CinemaScale.pt(28), weight: .heavy, design: .default))
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
                        .fill(isFirst ? Color.white.opacity(0.2) : CinemaColor.surfaceContainerHighest)
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

    var iOSServerDetail: some View {
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

    var iOSInterfaceDetail: some View {
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
        HStack(spacing: 5) {
            Circle()
                .fill(CinemaColor.success)
                .frame(width: 6, height: 6)

            Text(loc.localized("settings.live"))
                .font(.system(size: CinemaScale.pt(13), weight: .bold))
                .tracking(0.5)
                .foregroundStyle(CinemaColor.success)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(CinemaColor.success.opacity(0.12)))
    }

    @ViewBuilder
    func navigationRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
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
    func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing3)
    }

    @ViewBuilder
    func rowIcon(systemName: String, color: Color) -> some View {
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

    var divider: some View {
        Rectangle()
            .fill(CinemaColor.surfaceContainerHighest.opacity(0.6))
            .frame(height: 1)
            .padding(.leading, CinemaSpacing.spacing4 + 32 + CinemaSpacing.spacing2)
    }

    func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(CinemaFont.label(.small))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .tracking(1.2)
            .padding(.horizontal, CinemaSpacing.spacing2)
    }
}

// MARK: - Appearance Detail View (iOS)
// Standalone View struct so NavigationStack destination has its own
// @Observable observation tracking for ThemeManager and LocalizationManager.

private struct IOSAppearanceDetailView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(LocalizationManager.self) var loc

    var body: some View {
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

    // MARK: - Appearance-specific helpers

    var selectedAccent: AccentOption {
        AccentOption(rawValue: themeManager.accentColorKey) ?? .blue
    }

    var languagePicker: some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            languageButton("fr", label: "FR")
            languageButton("en", label: "EN")
        }
    }

    func languageButton(_ code: String, label: String) -> some View {
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

    @ViewBuilder
    func accentDot(_ option: AccentOption) -> some View {
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

    // MARK: - Shared layout helpers

    @ViewBuilder
    func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing3)
    }

    @ViewBuilder
    func rowIcon(systemName: String, color: Color) -> some View {
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

    var divider: some View {
        Rectangle()
            .fill(CinemaColor.surfaceContainerHighest.opacity(0.6))
            .frame(height: 1)
            .padding(.leading, CinemaSpacing.spacing4 + 32 + CinemaSpacing.spacing2)
    }

    func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(CinemaFont.label(.small))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .tracking(1.2)
            .padding(.horizontal, CinemaSpacing.spacing2)
    }
}
#endif
