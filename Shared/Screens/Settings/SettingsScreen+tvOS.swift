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
                    if let sub = selectedInterfaceSub {
                        // Three-level state: pop sub → hub.
                        tvInterfaceSubDetailView(for: sub)
                            .onExitCommand { selectedInterfaceSub = nil }
                    } else if let category = selectedCategory {
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
                    selectedInterfaceSub = nil
                    proxy.scrollTo("settings.top", anchor: .top)
                }
            }
            .onChange(of: selectedInterfaceSub) { _, newValue in
                if newValue == nil {
                    proxy.scrollTo("settings.top", anchor: .top)
                }
            }
            // No `.onAppear { scrollTo(top) }` — that fired whenever SwiftUI
            // re-presented this view inside the `TabView` (which happens on
            // every `MenuConfigStore` mutation now that the sub-nav state
            // survives the remount via `SettingsNavCoordinator`), yanking the
            // user back to the top of the page and dropping focus on the
            // row they were just touching. A fresh `ScrollView` already
            // starts at the top — no explicit reset needed on first appear.
        }
        .background {
            // Centered accent bloom — persists across all settings pages
            Circle()
                .fill(themeManager.accent.opacity(0.3))
                .frame(width: CinemaBloom.settingsSize, height: CinemaBloom.settingsSize)
                .blur(radius: CinemaBloom.settingsBlur)
        }
        .task { await loadServerUsers() }
        .task { await probeQuickConnect() }
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
                // tvOS explicitly hides admin entries — admin workflows are
                // iOS/iPadOS-only. `isAdmin: false` is safe because the filter
                // short-circuits on `isTVOS: true` regardless of admin flag.
                // `downloadsEnabled: false` is equally moot on tvOS — the
                // `isIOSOnly` filter already removes Downloads here.
                ForEach(SettingsCategory.visibleCases(isAdmin: false, isTVOS: true, downloadsEnabled: false)) { category in
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
                        .font(CinemaFont.headline(.small))
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
                            .font(CinemaFont.headline(.medium))
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
                case .administration, .advancedAdmin, .downloads:
                    // Never selected on tvOS — admin + downloads categories
                    // are filtered out of the landing pill list. Render
                    // nothing as a safety net.
                    EmptyView()
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

            tvGlassToggle(
                icon: "sparkles",
                label: loc.localized("settings.motionEffects"),
                key: "motion",
                value: $motionEffects
            )

            tvFontSizeRow
            tvLibraryLayoutRow
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

            if quickConnectEnabled {
                tvActionRow(
                    id: "quickConnect",
                    icon: "qrcode.viewfinder",
                    label: loc.localized("settings.quickConnect"),
                    showsChevron: true,
                    action: { showQuickConnectAuthorize = true }
                )
            }

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

    // MARK: Interface Detail (tvOS) — Hub of sub-pages

    /// Renders a list of focusable rows, one per `InterfaceSubcategory`. Each
    /// row sets `selectedInterfaceSub`, triggering the third-level page below.
    var tvInterfaceDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            ForEach(InterfaceSubcategory.allCases) { sub in
                tvActionRow(
                    focus: .interfaceSub(sub.rawValue),
                    icon: sub.icon,
                    label: sub.localizedName(loc),
                    showsChevron: true,
                    action: { selectedInterfaceSub = sub }
                )
            }
        }
    }

    // MARK: tvOS Interface Sub-Detail

    @ViewBuilder
    func tvInterfaceSubDetailView(for sub: InterfaceSubcategory) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                let backFocused = focusedItem == .back
                Button {
                    selectedInterfaceSub = nil
                } label: {
                    HStack(spacing: CinemaSpacing.spacing2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                        Text(sub.localizedName(loc))
                            .font(CinemaFont.headline(.medium))
                    }
                    .foregroundStyle(backFocused ? themeManager.accent : CinemaColor.onSurface)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .hoverEffectDisabled()
                .focused($focusedItem, equals: .back)

                switch sub {
                case .menu:       tvMenuSection
                case .homePage:   tvHomePageSection
                case .detailPage: tvDetailPageSection
                case .playback:   tvPlaybackSection
                case .debug:      tvDebugSection
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing20)
            .padding(.vertical, CinemaSpacing.spacing8)
        }
    }

    var tvHomePageSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvToggleList(homePageToggleRows)
            if showGenreRows {
                TVHomeGenrePickerView()
            }
        }
    }

    var tvPlaybackSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvToggleList(playbackToggleRows)
            tvSleepTimerRow
        }
    }

    var tvDetailPageSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvToggleList(detailPageToggleRows)
        }
    }

    /// Renders the shared `MenuSettingsScreen` body. The screen returns a
    /// VStack that composes inside the parent `tvInterfaceSubDetailView`'s
    /// ScrollView; no extra wrapping needed.
    var tvMenuSection: some View {
        MenuSettingsScreen()
    }

    var tvDebugSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvToggleList(debugToggleRows)
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
        // Idempotent guard — `.task` re-fires every time `MainTabView` rebuilds
        // its `TabView` content (any menu mutation does this), which would
        // otherwise hit `getUsers`/`getPublicUsers` and trigger a toast on
        // every refresh / kind change. The quick-switch profile section
        // gracefully renders nothing if the list stays empty, and
        // `UserSwitchSheet` does its own fetch with `try?` when opened.
        guard !serverUsersLoadAttempted else { return }
        serverUsersLoadAttempted = true

        // Visibility rule (admin-only getUsers, hidden filter with a
        // current-user exemption, public fallback) is shared with
        // UserSwitchSheet — see AppState.fetchSwitchableUsers. Failures stay
        // silent: the profile section renders nothing on empty, and the
        // sheet does its own deeper retry when actually opened.
        serverUsers = await appState.fetchSwitchableUsers()
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
                    .font(CinemaFont.label(.small))
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

    /// Library landing layout ("By genre" browse vs "Show all" flat grid). The
    /// iOS equivalent is an inline segmented control in `IOSAppearanceDetailView`.
    var tvLibraryLayoutRow: some View {
        let isFocused = focusedItem == .toggle("libraryLayout")
        let selected = LibraryBrowseLayout(rawValue: libraryBrowseLayout) ?? .browse
        return Button {
            showLibraryLayoutPicker = true
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 24)
                Text(loc.localized("settings.libraryLayout"))
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                Text(loc.localized(selected == .browse ? "settings.libraryLayout.browse" : "settings.libraryLayout.grid"))
                    .font(.system(size: CinemaScale.pt(17), weight: .semibold))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                Image(systemName: "chevron.up.chevron.down")
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, animated: motionEffects, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .toggle("libraryLayout"))
        .confirmationDialog(loc.localized("settings.libraryLayout"), isPresented: $showLibraryLayoutPicker) {
            ForEach(LibraryBrowseLayout.allCases) { option in
                Button(loc.localized(option == .browse ? "settings.libraryLayout.browse" : "settings.libraryLayout.grid")) {
                    libraryBrowseLayout = option.rawValue
                }
            }
        }
    }

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
                    .font(CinemaFont.label(.small))
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

// MARK: - tvOS Home Genre Rows Picker

/// Focusable genre chips for choosing which genres appear as rows on Home.
/// Standalone `View` so it owns its `@State` (fetched genres) and re-renders
/// from `@AppStorage` even though it's hosted in the state-machine settings
/// detail rendered from an extension method (where `@Observable` wouldn't).
/// Selection persists through `HomeGenrePreferences` (`home.selectedGenres`).
struct TVHomeGenrePickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.motionEffectsEnabled) private var motionEffects
    /// Held only for reactivity — the source of truth is `HomeGenrePreferences`.
    @AppStorage(SettingsKey.homeSelectedGenres) private var selectionJSON: String = ""
    @State private var availableGenres: [String] = []
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            Text(loc.localized("settings.homePage.genreRows.hint"))
                .font(.system(size: CinemaScale.pt(17), weight: .medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)

            if availableGenres.isEmpty {
                Text(loc.localized("settings.homePage.genreRows.empty"))
                    .font(.system(size: CinemaScale.pt(17), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .padding(.vertical, CinemaSpacing.spacing2)
            } else {
                selectAllChip
                FlowLayout(spacing: CinemaSpacing.spacing2) {
                    ForEach(availableGenres, id: \.self) { genre in
                        chip(genre)
                    }
                }
            }
        }
        .padding(.top, CinemaSpacing.spacing2)
        .task {
            // getGenres is cached client-side (300s); guard so the tvOS `.task`
            // re-firing on settings re-entry doesn't thrash @State.
            guard !didLoad else { return }
            didLoad = true
            await loadGenres()
        }
    }

    private var selection: Set<String> {
        let explicit = HomeGenrePreferences.decode(selectionJSON)
        if explicit.isEmpty && !HomeGenrePreferences.isConfigured() {
            return Set(availableGenres.prefix(HomeGenrePreferences.defaultRowCount))
        }
        return Set(explicit)
    }

    private var allSelected: Bool {
        !availableGenres.isEmpty && selection.count == availableGenres.count
    }

    /// Select-all / deselect-all toggle. Selecting all persists the full list;
    /// deselecting persists an explicit empty choice (zero genre rows).
    private var selectAllChip: some View {
        let scheme: ColorScheme = themeManager.darkModeEnabled ? .dark : .light
        return Button {
            HomeGenrePreferences.setSelectedGenres(allSelected ? [] : availableGenres)
        } label: {
            HStack(spacing: CinemaSpacing.spacing1) {
                Image(systemName: allSelected ? "xmark.circle" : "checkmark.circle")
                    .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                Text(loc.localized(allSelected
                    ? "settings.homePage.genreRows.deselectAll"
                    : "settings.homePage.genreRows.selectAll"))
                    .font(.system(size: CinemaScale.pt(20), weight: .semibold))
            }
            .foregroundStyle(CinemaColor.onSurface)
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing2)
            .environment(\.colorScheme, scheme)
            .background(
                Capsule()
                    .fill(CinemaColor.surfaceContainerHigh)
                    .environment(\.colorScheme, scheme)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
    }

    @ViewBuilder
    private func chip(_ genre: String) -> some View {
        let isSelected = selection.contains(genre)
        // A focused tvOS button flips its label's UITraitCollection to light
        // mode, which would invert every Color.dynamic token (near-black text
        // on a near-white capsule in dark mode). Re-inject the real scheme on
        // the label content AND the background fill — same mechanism as
        // `tvSettingsFocusable`. See CLAUDE.md trait caveat.
        let scheme: ColorScheme = themeManager.darkModeEnabled ? .dark : .light
        Button {
            toggle(genre)
        } label: {
            HStack(spacing: CinemaSpacing.spacing1) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: CinemaScale.pt(15), weight: .bold))
                }
                Text(genre)
                    .font(.system(size: CinemaScale.pt(20), weight: isSelected ? .bold : .medium))
            }
            .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurface)
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing2)
            .environment(\.colorScheme, scheme)
            .background(
                Capsule()
                    .fill(isSelected ? themeManager.accentContainer : CinemaColor.surfaceContainerHigh)
                    .environment(\.colorScheme, scheme)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
    }

    private func toggle(_ genre: String) {
        var next = selection
        if next.contains(genre) { next.remove(genre) } else { next.insert(genre) }
        // Persist in canonical (available) order so Home renders rows in the
        // same order the chips appear here.
        HomeGenrePreferences.setSelectedGenres(availableGenres.filter { next.contains($0) })
    }

    private func loadGenres() async {
        guard let userId = appState.currentUserId else { return }
        let genres = (try? await appState.apiClient.getGenres(
            userId: userId, includeItemTypes: [.movie, .series]
        )) ?? []
        availableGenres = genres.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
#endif
