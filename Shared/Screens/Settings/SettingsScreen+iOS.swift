import SwiftUI
import CinemaxKit

// MARK: - iOS Layout

#if os(iOS)
extension SettingsScreen {

    /// Renders directly into whatever `NavigationStack` wraps this screen
    /// (provided by `MainTabView`'s `Tab` block, or by `MoreTabScreen`'s push
    /// path). A *second* nested `NavigationStack` here would silently swallow
    /// the `.navigationDestination(item:)` of `selectedInterfaceSub` when the
    /// screen is reached through the More tab — SwiftUI gets confused about
    /// which stack owns the push when there are 3+ nested stacks.
    var iOSLayout: some View {
        // `@Bindable` is the iOS 17+ way to project bindings off an
        // `@Observable` reference type — replaces the previous `$`-projection
        // on `@State` (now hoisted to `settingsNav` so the depth survives
        // a `SettingsScreen` remount triggered by tvOS tab reorder).
        @Bindable var nav = settingsNav
        return ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                iOSHeader
                iOSNavigationList
                iOSDeviceInfo
            }
        }
        .background(CinemaColor.surfaceContainerLowest)
        .task { await probeQuickConnect() }
        .navigationDestination(item: $nav.selectedCategory) { category in
            settingsDetailView(for: category)
        }
        .navigationDestination(item: $nav.selectedInterfaceSub) { sub in
            iOSInterfaceSubDetailView(for: sub)
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
            ForEach(SettingsCategory.visibleCases(isAdmin: appState.isAdministrator, isTVOS: false)) { category in
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
                        .font(.system(size: CinemaScale.pt(18), weight: .semibold))
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
                .font(.system(size: CinemaScale.pt(10), weight: .bold))
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
        // Admin landings manage their own scrolling + background so pushed
        // sub-screens aren't fighting the wrapping ScrollView. The remaining
        // static-form categories keep the original wrapper.
        switch category {
        case .administration:
            AdminLandingScreen()
        case .advancedAdmin:
            AdvancedAdminLandingScreen()
        default:
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
                    case .administration, .advancedAdmin:
                        EmptyView() // handled above
                    }
                }
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.bottom, CinemaSpacing.spacing8)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationTitle(category.localizedName(loc))
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: Account Detail (iOS)

    var iOSAccountDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            profileHeader

            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                iOSSettingsSectionHeader(loc.localized("settings.account"))

                // TODO(v2): wire a user-facing Profile Settings screen
                // (password change + avatar) — see docs/v2-todo.md.
                VStack(spacing: 0) {
                    navigationRow(icon: "clock.arrow.circlepath", label: loc.localized("settings.watchedHistory")) {
                        showWatchedHistory = true
                    }

                    iOSSettingsDivider

                    navigationRow(icon: "lock.shield", label: loc.localized("settings.privacySecurity")) {
                        showPrivacySecurity = true
                    }

                    iOSSettingsDivider

                    if quickConnectEnabled {
                        navigationRow(icon: "qrcode.viewfinder", label: loc.localized("settings.quickConnect")) {
                            showQuickConnectAuthorize = true
                        }

                        iOSSettingsDivider
                    }

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
        .alert(loc.localized("action.logOut"), isPresented: $showLogOutAlert) {
            Button(loc.localized("action.logOut"), role: .destructive) {
                appState.logout()
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("settings.logOutConfirm"))
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

                    liveBadge
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

    // MARK: Interface Detail (iOS) — Hub of sub-pages
    //
    // Renders Interface sub-pages as standalone pill buttons mirroring the
    // Settings landing chrome (accent-filled hero on the first row, glass
    // material on the others). Keeps the visual identity consistent between
    // the two hubs and makes the accent-color theme front-and-center.

    var iOSInterfaceDetail: some View {
        VStack(spacing: CinemaSpacing.spacing2) {
            ForEach(InterfaceSubcategory.allCases) { sub in
                iOSInterfaceSubButton(sub)
            }
        }
    }

    @ViewBuilder
    func iOSInterfaceSubButton(_ sub: InterfaceSubcategory) -> some View {
        let isFirst = sub == InterfaceSubcategory.allCases.first

        Button {
            selectedInterfaceSub = sub
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                // Icon circle — accent-filled on the hero, neutral material on the rest
                ZStack {
                    Circle()
                        .fill(isFirst ? themeManager.accent.opacity(0.18) : CinemaColor.surfaceContainerHighest)
                        .frame(width: 40, height: 40)
                    Image(systemName: sub.icon)
                        .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                        .foregroundStyle(isFirst ? .white : themeManager.accent)
                }

                Text(sub.localizedName(loc))
                    .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(isFirst ? .white : CinemaColor.onSurface)

                Spacer()

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
        }
        .buttonStyle(.plain)
    }

    // MARK: - iOS Interface Sub-Detail Views

    @ViewBuilder
    func iOSInterfaceSubDetailView(for sub: InterfaceSubcategory) -> some View {
        // Menu has its own root chrome (background + title); the other
        // sub-pages share the standard ScrollView + glassPanel wrapper.
        if sub == .menu {
            MenuSettingsScreen()
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                    switch sub {
                    case .menu:       EmptyView() // handled above
                    case .homePage:   iOSHomePageSection
                    case .detailPage: iOSDetailPageSection
                    case .playback:   iOSPlaybackSection
                    case .debug:      iOSDebugSection
                    }
                }
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.bottom, CinemaSpacing.spacing8)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationTitle(sub.localizedName(loc))
            .navigationBarTitleDisplayMode(.large)
        }
    }

    var iOSHomePageSection: some View {
        VStack(spacing: 0) {
            iOSToggleRowsJoined(homePageToggleRows, accent: themeManager.accent, animated: motionEffects, loc: loc)

            // "Genre rows" is a section toggle; when on, drill into a native
            // multi-select to choose which genres surface as rows on Home.
            if showGenreRows {
                iOSSettingsDivider
                NavigationLink {
                    IOSHomeGenrePickerView()
                } label: {
                    iOSSettingsRow {
                        HStack {
                            iOSRowIcon(systemName: "theatermasks", color: themeManager.accent)
                            Text(loc.localized("settings.homePage.genreRows.choose"))
                                .font(CinemaFont.label(.large))
                                .foregroundStyle(CinemaColor.onSurface)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: CinemaScale.pt(13), weight: .semibold))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .glassPanel(cornerRadius: CinemaRadius.extraLarge)
    }

    var iOSPlaybackSection: some View {
        VStack(spacing: 0) {
            iOSToggleRowsJoined(playbackToggleRows, accent: themeManager.accent, animated: motionEffects, loc: loc)
            iOSSettingsDivider
            iOSSleepTimerRow
        }
        .glassPanel(cornerRadius: CinemaRadius.extraLarge)
    }

    var iOSDetailPageSection: some View {
        VStack(spacing: 0) {
            iOSToggleRowsJoined(detailPageToggleRows, accent: themeManager.accent, animated: motionEffects, loc: loc)
        }
        .glassPanel(cornerRadius: CinemaRadius.extraLarge)
    }

    var iOSDebugSection: some View {
        VStack(spacing: 0) {
            iOSToggleRowsJoined(debugToggleRows, accent: themeManager.accent, animated: motionEffects, loc: loc)
        }
        .glassPanel(cornerRadius: CinemaRadius.extraLarge)
    }

    // MARK: - iOS Reusable Components

    var profileHeader: some View {
        HStack(spacing: CinemaSpacing.spacing4) {
            profileAvatar
                .frame(width: 56, height: 56)

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

    /// Account avatar. Renders the Jellyfin primary image for the signed-in
    /// user when available, with an accent gradient + initial underneath as
    /// the fallback (covers "no image set" and offline cases uniformly).
    @ViewBuilder
    var profileAvatar: some View {
        // `appState.currentUser` is hydrated by `refreshCurrentUser()` via
        // `getUserByID` for every account — unlike `getUsers()` which is
        // admin-only and 401s for regular users (the avatar silently never
        // rendered for them when this fetched its own copy).
        UserAvatar(
            userId: appState.currentUserId,
            name: username,
            primaryImageTag: appState.currentUser?.primaryImageTag,
            size: 56
        )
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

// MARK: - iOS Home Genre Rows Picker

/// Native multi-select `List` for choosing which genres appear as rows on
/// Home. Pushed from the Home page settings section. Standalone `View` so its
/// `@State` (fetched genres) and `@AppStorage` selection drive re-renders even
/// though it's reached through a `NavigationLink` inside the settings stack.
/// Selection persists through `HomeGenrePreferences` (`home.selectedGenres`).
struct IOSHomeGenrePickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    /// Held only for reactivity — the source of truth is `HomeGenrePreferences`.
    @AppStorage(SettingsKey.homeSelectedGenres) private var selectionJSON: String = ""
    @State private var availableGenres: [String] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if availableGenres.isEmpty {
                EmptyStateView(
                    systemImage: "theatermasks",
                    title: loc.localized("settings.homePage.genreRows.empty")
                )
            } else {
                List(availableGenres, id: \.self, selection: selectionBinding) { genre in
                    Text(genre)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                        .listRowBackground(CinemaColor.surfaceContainer)
                }
                .environment(\.editMode, .constant(.active))
                .scrollContentBackground(.hidden)
                .tint(themeManager.accent)
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("settings.homePage.genreRows"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !availableGenres.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.localized(allSelected
                        ? "settings.homePage.genreRows.deselectAll"
                        : "settings.homePage.genreRows.selectAll")) {
                        HomeGenrePreferences.setSelectedGenres(allSelected ? [] : availableGenres)
                    }
                    .tint(themeManager.accent)
                }
            }
        }
        .task { await loadGenres() }
    }

    /// `true` when every available genre is currently selected — drives the
    /// select-all / deselect-all toggle label and action.
    private var allSelected: Bool {
        !availableGenres.isEmpty && selectionBinding.wrappedValue.count == availableGenres.count
    }

    /// `Set` binding the multi-select `List` drives. The getter falls back to a
    /// default prefix while unconfigured so the checkmarks match what Home
    /// shows; the first edit materializes the explicit selection.
    private var selectionBinding: Binding<Set<String>> {
        Binding(
            get: {
                let explicit = HomeGenrePreferences.decode(selectionJSON)
                if explicit.isEmpty && !HomeGenrePreferences.isConfigured() {
                    return Set(availableGenres.prefix(HomeGenrePreferences.defaultRowCount))
                }
                return Set(explicit)
            },
            set: { newValue in
                // Persist in canonical (available) order — matches Home's row order.
                HomeGenrePreferences.setSelectedGenres(availableGenres.filter { newValue.contains($0) })
            }
        )
    }

    private func loadGenres() async {
        guard let userId = appState.currentUserId else { isLoading = false; return }
        let genres = (try? await appState.apiClient.getGenres(
            userId: userId, includeItemTypes: [.movie, .series]
        )) ?? []
        availableGenres = genres.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        isLoading = false
    }
}

#endif
