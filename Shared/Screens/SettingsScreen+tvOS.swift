import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

// MARK: - tvOS Layout

#if os(tvOS)
extension SettingsScreen {

    var tvOSLayout: some View {
        // Wrap in a ScrollView + ScrollViewReader so we can force the page to
        // scroll back to its top whenever the user pops back from a category
        // detail. Without this, tvOS keeps the page scrolled (or focus stranded)
        // and the system top tab bar can stay hidden behind page content.
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("settings.top")

                Group {
                    if let category = selectedCategory {
                        tvDetailView(for: category)
                            .onExitCommand { selectedCategory = nil }
                    } else {
                        tvLandingPage
                    }
                }
                // Hold full height so the visual layout is unchanged from the
                // pre-ScrollView version (brand panel + categories centered).
                .frame(maxWidth: .infinity, minHeight: tvLandingMinHeight, maxHeight: .infinity)
            }
            .scrollClipDisabled()
            .onChange(of: selectedCategory) { _, newValue in
                // When a category is closed (newValue == nil), bring the page
                // back to the top so the tab bar resurfaces naturally.
                if newValue == nil {
                    proxy.scrollTo("settings.top", anchor: .top)
                }
            }
            .onAppear {
                proxy.scrollTo("settings.top", anchor: .top)
            }
        }
        .background {
            // Centered accent bloom — persists across all settings pages
            Circle()
                .fill(themeManager.accent.opacity(0.3))
                .frame(width: 1200, height: 1200)
                .blur(radius: 280)
        }
        .task { await loadServerUsers() }
        .alert(loc.localized("settings.switchAccount"), isPresented: $showSwitchAccountAlert) {
            Button(loc.localized("settings.switchAccount")) {
                showUserSwitch = true
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("settings.switchAccountConfirm"))
        }
        .alert(loc.localized("action.logOut"), isPresented: $showLogOutAlert) {
            Button(loc.localized("action.logOut"), role: .destructive) {
                appState.logout()
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("settings.logOutConfirm"))
        }
    }

    // MARK: tvOS Landing Page

    var tvLandingPage: some View {
        HStack(spacing: 0) {
            // Left Side: Identity & Logo (40%)
            tvBrandPanel
                .frame(maxWidth: .infinity)

            // Right Side: Navigation Categories (60%)
            tvNavigationPanel
                .frame(maxWidth: .infinity)
        }
    }

    var tvBrandPanel: some View {
        VStack(spacing: CinemaSpacing.spacing6) {
            Spacer()

            Image("AppLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 400, height: 400)
                .shadow(color: themeManager.accent.opacity(0.5), radius: 40)
                .accessibilityHidden(true)

            VStack(spacing: CinemaSpacing.spacing2) {
                Text(loc.localized("settings.systemSettings"))
                    .font(.system(size: CinemaScale.pt(48), weight: .heavy))
                    .foregroundStyle(CinemaColor.onSurface)
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

    var tvNavigationPanel: some View {
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
    func tvCategoryButton(_ category: SettingsCategory) -> some View {
        let isFocused = focusedItem == .category(category.rawValue)

        Button {
            selectedCategory = category
        } label: {
            HStack(spacing: CinemaSpacing.spacing4) {
                // Icon circle
                ZStack {
                    Circle()
                        .fill(isFocused ? themeManager.accent.opacity(0.18) : CinemaColor.surfaceContainerHighest)
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
                        .foregroundStyle(CinemaColor.onSurface.opacity(0.7))
                }

                if isFocused {
                    Image(systemName: "chevron.right")
                        .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                        .foregroundStyle(CinemaColor.onSurface.opacity(0.7))
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing5)
            .padding(.vertical, CinemaSpacing.spacing4)
            .background(
                RoundedRectangle(cornerRadius: CinemaRadius.full)
                    .fill(isFocused ? themeManager.accentContainer : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CinemaRadius.full)
                    .strokeBorder(CinemaColor.onSurface.opacity(isFocused ? 0.1 : 0), lineWidth: 4)
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

    var tvSystemInfoBar: some View {
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

    // MARK: - tvOS Detail Views

    @ViewBuilder
    func tvDetailView(for category: SettingsCategory) -> some View {
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

    var tvAppearanceDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvGlassToggle(
                icon: themeManager.darkModeEnabled ? "moon.fill" : "sun.max.fill",
                label: themeManager.darkModeEnabled ? loc.localized("settings.darkMode") : loc.localized("settings.lightMode"),
                key: "darkMode",
                value: Binding(
                    get: { themeManager.darkModeEnabled },
                    set: { themeManager.darkModeEnabled = $0 }
                )
            )

            tvAccentColorPicker

            tvLanguagePicker
        }
    }

    // MARK: Account Detail (tvOS)

    var tvAccountDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            tvProfileSection

            tvActionRow(
                id: "privacySecurity",
                icon: "lock.shield",
                label: loc.localized("settings.privacySecurity"),
                showsChevron: true,
                action: { showPrivacySecurity = true }
            )

            tvActionRow(
                id: "logout",
                icon: "rectangle.portrait.and.arrow.right",
                label: loc.localized("action.logOut"),
                tint: CinemaColor.error,
                action: { showLogOutAlert = true }
            )
        }
    }

    // MARK: Server Detail (tvOS)

    var tvServerDetail: some View {
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

                    serverStatusBadge(label: loc.localized("settings.connected"), fontSize: 14)
                }

                tvRefreshConnectionButton
                tvRefreshCatalogueButton
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

            tvLicensesButton
        }
    }

    // MARK: - Action Rows (tvOS)

    var tvRefreshCatalogueButton: some View {
        tvActionRow(
            id: "refreshCatalogue",
            icon: "arrow.triangle.2.circlepath",
            label: loc.localized("settings.refreshCatalogue"),
            subtitle: loc.localized("settings.refreshCatalogue.subtitle"),
            action: refreshCatalogue
        )
    }

    var tvLicensesButton: some View {
        tvActionRow(
            id: "licenses",
            icon: "doc.text",
            label: loc.localized("settings.licenses"),
            showsChevron: true,
            action: { showLicenses = true }
        )
    }

    // MARK: Interface Detail (tvOS)

    var tvInterfaceDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                tvToggleList(interfaceToggleRows)

                tvSleepTimerRow
                tvFontSizeRow
            }

            // Home Page section
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                tvSectionLabel(loc.localized("settings.homePage"))
                tvToggleList(homePageToggleRows)
            }

            // Detail Page section
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                tvSectionLabel(loc.localized("settings.detailPage"))
                tvToggleList(detailPageToggleRows)
            }

            // Debug section
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                tvSectionLabel(loc.localized("settings.debug"))
                tvToggleList(debugToggleRows)
            }
        }
    }

    /// Renders a `SettingsToggleRow` list as tvOS focused rows. tvOS currently
    /// uses `themeManager.accent` for every icon; `row.tint` is preserved on the
    /// data model but intentionally ignored here to match the pre-refactor
    /// visual (see CLAUDE.md — iOS orange debug icons, tvOS accent icons).
    @ViewBuilder
    func tvToggleList(_ rows: [SettingsToggleRow]) -> some View {
        ForEach(rows) { row in
            tvGlassToggle(icon: row.icon, label: row.label, key: row.id, value: row.value)
        }
    }

    // MARK: - tvOS Reusable Components

    func loadServerUsers() async {
        do {
            serverUsers = try await appState.apiClient.getUsers()
        } catch {
            do { serverUsers = try await appState.apiClient.getPublicUsers() } catch {}
        }
    }

    var tvLanguagePicker: some View {
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
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, animated: motionEffects, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
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

    func tvLanguageChip(_ code: String, label: String) -> some View {
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

    var tvAccentColorPicker: some View {
        let isFocused = focusedItem == .accentColor("row")
        let allOptions = AccentOption.visibleCases(rainbowUnlocked: rainbowUnlocked)

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
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, animated: motionEffects, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .accentColor("row"))
        .onMoveCommand { direction in
            guard isFocused else { return }
            let allOpts = AccentOption.visibleCases(rainbowUnlocked: rainbowUnlocked)
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

    func tvAccentDotDisplay(_ option: AccentOption) -> some View {
        let isSelected = option.rawValue == themeManager.accentColorKey

        return ZStack {
            if option == .rainbow {
                RainbowAccentSwatch(diameter: 36)
            } else {
                Circle()
                    .fill(option.color)
                    .frame(width: 36, height: 36)
            }

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

    var currentUserId: String {
        appState.currentUserId ?? ""
    }

    var displayUsers: [UserDto] {
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

    var tvProfileSection: some View {
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

    func tvProfileBlock(user: UserDto) -> some View {
        let userId = user.id ?? ""
        let isCurrentUser = userId == currentUserId
        let hasImage = user.primaryImageTag != nil
        let isFocused = focusedItem == .profile(userId)

        return Button {
            if !isCurrentUser { showSwitchAccountAlert = true }
        } label: {
            VStack(spacing: CinemaSpacing.spacing2) {
                Group {
                    if hasImage, appState.serverURL != nil {
                        let imageURL = appState.imageBuilder
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
                        .foregroundStyle(CinemaColor.success)
                } else {
                    Text(user.policy?.isAdministrator == true ? loc.localized("settings.admin") : loc.localized("settings.user"))
                        .font(.system(size: CinemaScale.pt(13), weight: .medium))
                        .foregroundStyle(isFocused ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .padding(.vertical, CinemaSpacing.spacing3)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .profile(userId))
    }

    var tvSwitchAccountBlock: some View {
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
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .switchAccount)
    }

    func tvUserInitial(name: String, size: CGFloat) -> some View {
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

    var tvRefreshConnectionButton: some View {
        tvActionRow(
            focus: .refreshConnection,
            icon: "arrow.clockwise",
            label: loc.localized("settings.refreshConnection"),
            action: { Task { await appState.restoreSession() } }
        )
    }

    // MARK: - Interface Options

    var tvFontSizeRow: some View {
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
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, animated: motionEffects, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
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

    /// Minimum height for the Settings landing page so the brand+categories layout
    /// keeps its visual proportions inside the new ScrollView wrapper. tvOS screens
    /// are ≥ 720pt tall, so this safely fills the viewport without forcing scroll.
    var tvLandingMinHeight: CGFloat { 720 }

    // MARK: - Sleep Timer Row (tvOS)

    var tvSleepTimerRow: some View {
        let isFocused = focusedItem == .toggle("sleepTimer")
        let selected = SleepTimerOption(rawValue: sleepTimerMinutes) ?? .disabled
        return Button {
            showSleepTimerPicker = true
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 24)
                Text(loc.localized("settings.sleepTimer"))
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                Text(loc.localized(selected.localizationKey))
                    .font(.system(size: CinemaScale.pt(17), weight: .semibold))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: CinemaScale.pt(14), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, animated: motionEffects, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .toggle("sleepTimer"))
        .confirmationDialog(loc.localized("settings.sleepTimer"), isPresented: $showSleepTimerPicker) {
            ForEach(SleepTimerOption.allCases) { option in
                Button(loc.localized(option.localizationKey)) {
                    sleepTimerMinutes = option.rawValue
                }
            }
        }
    }

    func tvGlassToggle(icon: String, label: String, key: String, value: Binding<Bool>) -> some View {
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

                CinemaToggleIndicator(isOn: value.wrappedValue, accent: themeManager.accent, animated: motionEffects)
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, animated: motionEffects, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .toggle(key))
    }

    // MARK: - Action Row (shared tvOS helper)
    //
    // Single source of truth for "tappable row with icon + title + optional
    // subtitle + optional chevron" on tvOS. Replaces three near-duplicate
    // bespoke buttons (Refresh Catalogue / Refresh Connection / Licenses).
    //
    // Two overloads let callers either reuse the generic `.toggle(id)` focus
    // lane (used for most settings rows) or supply a dedicated `SettingsFocus`
    // case where one already exists (e.g. `.refreshConnection`).

    @ViewBuilder
    func tvActionRow(
        id: String,
        icon: String,
        label: String,
        subtitle: String? = nil,
        showsChevron: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        tvActionRow(
            focus: .toggle(id),
            icon: icon,
            label: label,
            subtitle: subtitle,
            showsChevron: showsChevron,
            tint: tint,
            action: action
        )
    }

    @ViewBuilder
    func tvActionRow(
        focus: SettingsFocus,
        icon: String,
        label: String,
        subtitle: String? = nil,
        showsChevron: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focusedItem == focus
        let iconColor = tint ?? themeManager.accent
        let labelColor = tint ?? CinemaColor.onSurface
        Button(action: action) {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: icon)
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 24)

                if let subtitle {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label)
                            .font(.system(size: CinemaScale.pt(20), weight: .medium))
                            .foregroundStyle(labelColor)
                        Text(subtitle)
                            .font(.system(size: CinemaScale.pt(16), weight: .regular))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }
                } else {
                    Text(label)
                        .font(.system(size: CinemaScale.pt(20), weight: .medium))
                        .foregroundStyle(labelColor)
                }

                Spacer()

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: CinemaScale.pt(14), weight: .medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: focus)
    }

    // MARK: - tvOS Helpers

    func tvSectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: CinemaScale.pt(17), weight: .bold))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .tracking(1.5)
    }
}

// MARK: - tvOS Settings Focus Style

extension View {
    func tvSettingsFocusable(isFocused: Bool, accent: Color, animated: Bool = true, colorScheme: ColorScheme) -> some View {
        self
            // Prevent tvOS's focus-induced trait collection override from flipping Color.dynamic
            // tokens (texts, chips, icons) inside the button label to their light-mode values.
            .environment(\.colorScheme, colorScheme)
            .background(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .fill(CinemaColor.surfaceContainerHigh)
                    .environment(\.colorScheme, colorScheme)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .strokeBorder(accent.opacity(isFocused ? 0.8 : 0), lineWidth: 1.5)
            )
            .animation(animated ? .easeOut(duration: 0.15) : nil, value: isFocused)
    }
}
#endif
