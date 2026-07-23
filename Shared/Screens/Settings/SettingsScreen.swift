import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI
#if canImport(UIKit)
import UIKit
#endif
import Network

// `AccentOption` + `AccentEasterEgg`         → Shared/DesignSystem/AccentOption.swift
// `CinemaToggleIndicator` + `RainbowAccentSwatch` → Shared/DesignSystem/Components/

// MARK: - Settings Category

enum SettingsCategory: String, CaseIterable, Identifiable {
    // Declaration order = display order on both platforms (consumed by
    // `visibleCases` which preserves `allCases` order). Interface sits
    // second because it's the most-used category after Apparence — the
    // main-menu / playback / debug toggles all live there.
    case appearance
    case interface
    case account
    case server
    // Admin-only categories — gated by `AppState.isAdministrator` at the
    // render site so non-admins never see these rows. Server still enforces
    // authorization on every admin endpoint; client-side gating is UX only.
    case administration
    case advancedAdmin

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance:     "paintpalette"
        case .account:        "person"
        case .server:         "server.rack"
        case .interface:      "tv"
        case .administration: "shield.lefthalf.filled"
        case .advancedAdmin:  "wrench.and.screwdriver"
        }
    }

    @MainActor func localizedName(_ loc: LocalizationManager) -> String {
        switch self {
        case .appearance:     loc.localized("settings.appearance")
        case .account:        loc.localized("settings.account")
        case .server:         loc.localized("settings.server")
        case .interface:      loc.localized("settings.interface")
        case .administration: loc.localized("admin.landing.title")
        case .advancedAdmin:  loc.localized("admin.advanced.title")
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

    /// Whether this category is admin-gated. Used by the iOS landing to hide
    /// admin rows for non-admin users. tvOS never renders admin entries at
    /// all (admin workflows are mobile-only by product decision).
    var isAdminOnly: Bool {
        switch self {
        case .administration, .advancedAdmin: true
        default: false
        }
    }

    /// Filters `allCases` by admin visibility and platform. Use this instead
    /// of raw `allCases` in rendering code — keeps gating in one place.
    @MainActor static func visibleCases(isAdmin: Bool, isTVOS: Bool) -> [SettingsCategory] {
        allCases.filter { category in
            if isTVOS && category.isAdminOnly { return false }
            if category.isAdminOnly && !isAdmin { return false }
            return true
        }
    }
}

// MARK: - Interface Subcategory
//
// The Interface detail page is itself a hub of sub-pages — keeps each surface
// short and lets us add a "Menu" sub-page (custom main-tab layout) without
// piling more toggles into a single scroll. Order = display order on both
// platforms; rendering lives in `SettingsScreen+{iOS,tvOS}.swift`.

enum InterfaceSubcategory: String, CaseIterable, Identifiable {
    case menu
    case homePage
    case detailPage
    case playback
    case debug

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .menu:       "rectangle.grid.2x2"
        case .homePage:   "house"
        case .detailPage: "info.square"
        case .playback:   "play.rectangle"
        case .debug:      "ladybug"
        }
    }

    @MainActor func localizedName(_ loc: LocalizationManager) -> String {
        switch self {
        case .menu:       loc.localized("settings.interface.menu")
        case .homePage:   loc.localized("settings.homePage")
        case .detailPage: loc.localized("settings.detailPage")
        case .playback:   loc.localized("settings.interface.playback")
        case .debug:      loc.localized("settings.debug")
        }
    }
}

// MARK: - tvOS Focus Tracking

#if os(tvOS)
enum SettingsFocus: Hashable {
    case category(String)
    case interfaceSub(String)
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
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(LocalizationManager.self) var loc
    @Environment(ToastCenter.self) var toasts
    /// Hoisted out of this view's `@State` because tvOS's `UITabBarController`-
    /// backed `TabView` recreates the hosting controller (and resets `@State`)
    /// whenever the Settings tab's position-index in the bar shifts — toggle
    /// off / reorder / change tab source. The coordinator lives on
    /// `AppNavigation`, which never remounts during normal usage, so the
    /// sub-navigation depth survives the Settings remount.
    @Environment(SettingsNavCoordinator.self) var settingsNav
    @State var showLogOutAlert = false
    @State var showLicenses = false
    @State var showUserSwitch = false
    @State var showPrivacySecurity = false
    @State var showQuickConnectAuthorize = false
    @State var showWatchedHistory = false

    /// Whether the server has Quick Connect enabled — gates the account-screen
    /// "Quick Connect" (authorize) row so we never surface a flow the server
    /// will reject (mirrors the login screen's CTA gating). Resolved once by
    /// `probeQuickConnect`.
    @State var quickConnectEnabled = false
    /// Idempotency guard for `probeQuickConnect`, same rationale as
    /// `serverUsersLoadAttempted` — the tvOS `.task` re-fires on every menu
    /// mutation.
    @State var quickConnectProbeAttempted = false

    /// Convenience pass-throughs so the rest of the code keeps using
    /// `selectedCategory` / `selectedInterfaceSub` and the `$`-projection
    /// bindings without churn. The actual storage is on `settingsNav`.
    var selectedCategory: SettingsCategory? {
        get { settingsNav.selectedCategory }
        nonmutating set { settingsNav.selectedCategory = newValue }
    }
    var selectedInterfaceSub: InterfaceSubcategory? {
        get { settingsNav.selectedInterfaceSub }
        nonmutating set { settingsNav.selectedInterfaceSub = newValue }
    }

    // Shared stored properties — keys + defaults live in SettingsKey
    @AppStorage(SettingsKey.motionEffects) var motionEffects: Bool = SettingsKey.Default.motionEffects
    @AppStorage(SettingsKey.render4K) var render4K: Bool = SettingsKey.Default.render4K
    @AppStorage(SettingsKey.autoPlayNextEpisode) var autoPlayNextEpisode: Bool = SettingsKey.Default.autoPlayNextEpisode
    @AppStorage(SettingsKey.forceNativeAVPlayer) var forceNativeAVPlayer: Bool = SettingsKey.Default.forceNativeAVPlayer
    @AppStorage(SettingsKey.homeShowContinueWatching) var showContinueWatching: Bool = SettingsKey.Default.homeShowContinueWatching
    @AppStorage(SettingsKey.homeShowNextUp) var showNextUp: Bool = SettingsKey.Default.homeShowNextUp
    @AppStorage(SettingsKey.homeShowRecentlyAdded) var showRecentlyAdded: Bool = SettingsKey.Default.homeShowRecentlyAdded
    @AppStorage(SettingsKey.homeShowFavorites) var showFavorites: Bool = SettingsKey.Default.homeShowFavorites
    @AppStorage(SettingsKey.homeShowGenreRows) var showGenreRows: Bool = SettingsKey.Default.homeShowGenreRows
    @AppStorage(SettingsKey.homeShowWatchingNow) var showWatchingNow: Bool = SettingsKey.Default.homeShowWatchingNow
    @AppStorage(SettingsKey.detailShowQualityBadges) var showQualityBadges: Bool = SettingsKey.Default.detailShowQualityBadges
    @AppStorage(SettingsKey.detailShowTrailerButton) var showTrailerButton: Bool = SettingsKey.Default.detailShowTrailerButton
    @AppStorage(SettingsKey.libraryBrowseLayout) var libraryBrowseLayout: String = SettingsKey.Default.libraryBrowseLayout
    @AppStorage(SettingsKey.dimUnfocusedPosters) var dimUnfocusedPosters: Bool = SettingsKey.Default.dimUnfocusedPosters
    @AppStorage(SettingsKey.sleepTimerDefaultMinutes) var sleepTimerMinutes: Int = SettingsKey.Default.sleepTimerDefaultMinutes
    @AppStorage(SettingsKey.debugFastSleepTimer) var debugFastSleepTimer: Bool = SettingsKey.Default.debugFastSleepTimer
    @AppStorage(SettingsKey.debugShowSkipToEnd) var debugShowSkipToEnd: Bool = SettingsKey.Default.debugShowSkipToEnd
    @AppStorage(SettingsKey.rainbowUnlocked) var rainbowUnlocked: Bool = SettingsKey.Default.rainbowUnlocked
    @State var fontScale: Double = UserDefaults.standard.object(forKey: SettingsKey.uiScale) as? Double ?? SettingsKey.Default.uiScale
    @State var showFontSizePicker = false
    let fontScaleOptions: [Double] = [0.80, 0.85, 0.90, 0.95, 1.00, 1.05, 1.10, 1.15, 1.20, 1.25, 1.30]

    // tvOS-only stored properties
    #if os(tvOS)
    @FocusState var focusedItem: SettingsFocus?
    @State var serverUsers: [UserDto] = []
    /// Idempotency guard for `loadServerUsers`. tvOS `.task` re-fires every
    /// time SwiftUI re-enters the view hierarchy (which happens whenever
    /// `MenuConfigStore` mutates — refresh libraries, change tab source,
    /// reorder), and we don't want to spam `getUsers`/`getPublicUsers`
    /// requests (and any toast on failure) on every menu interaction.
    @State var serverUsersLoadAttempted = false
    @State var showSleepTimerPicker = false
    @State var showLibraryLayoutPicker = false
    #endif

    // MARK: Shared Computed Properties

    var username: String {
        appState.keychain.getUserSession()?.username ?? "User"
    }

    var userInitial: String {
        String(username.prefix(1)).uppercased()
    }

    var serverName: String {
        appState.serverInfo?.name ?? "Jellyfin Server"
    }

    var serverAddress: String {
        appState.serverURL?.host ?? appState.serverURL?.absoluteString ?? "Unknown"
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.6.0"
    }

    var deviceName: String {
        #if os(tvOS)
        UIDevice.current.name
        #elseif os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    var networkName: String {
        // Fallback display — actual SSID requires entitlements
        serverAddress
    }

    // MARK: - Shared Toggle Row Lists
    //
    // Single source of truth for every boolean settings row. Both platform
    // renderers (iOS glass-panel + divider stack, tvOS focused accent row)
    // consume these arrays via `iOSToggleRowsJoined` / inline `ForEach`.
    // Adding or renaming a toggle is now a single-file change.

    /// Playback toggles (4K rendering, auto-play next, native player). The
    /// sleep timer picker is a non-boolean row appended per platform.
    var playbackToggleRows: [SettingsToggleRow] {
        [
            .init(id: "4k", icon: "4k.tv", label: loc.localized("settings.4kRendering"), value: $render4K),
            .init(id: "autoPlayNext", icon: "play.square.stack", label: loc.localized("settings.autoPlayNextEpisode"), value: $autoPlayNextEpisode),
            .init(id: "nativePlayer", icon: "play.rectangle.on.rectangle", label: loc.localized("settings.forceNativeAVPlayer"), value: $forceNativeAVPlayer)
        ]
    }

    var homePageToggleRows: [SettingsToggleRow] {
        var rows: [SettingsToggleRow] = [
            .init(id: "homeContinueWatching", icon: "play.circle", label: loc.localized("settings.homePage.continueWatching"), value: $showContinueWatching),
            .init(id: "homeNextUp", icon: "forward.end", label: loc.localized("settings.homePage.nextUp"), value: $showNextUp),
            .init(id: "homeRecentlyAdded", icon: "sparkles.rectangle.stack", label: loc.localized("settings.homePage.recentlyAdded"), value: $showRecentlyAdded),
            .init(id: "homeFavorites", icon: "heart", label: loc.localized("settings.homePage.favorites"), value: $showFavorites),
            .init(id: "homeGenreRows", icon: "square.grid.2x2", label: loc.localized("settings.homePage.genreRows"), value: $showGenreRows)
        ]
        // "Watching Now" ("En direct") exposes other users' active sessions —
        // admin-only data (Jellyfin's /Sessions is meant to be elevated, and
        // even leaks to non-admins on some servers, see jellyfin#5210). Hide
        // the toggle entirely for non-admins so the feature is unreachable.
        if appState.isAdministrator {
            rows.append(.init(id: "homeWatchingNow", icon: "person.2.wave.2", label: loc.localized("settings.homePage.watchingNow"), value: $showWatchingNow))
        }
        return rows
    }

    var detailPageToggleRows: [SettingsToggleRow] {
        var rows: [SettingsToggleRow] = [
            .init(id: "detailQualityBadges", icon: "info.square", label: loc.localized("settings.detailPage.qualityBadges"), value: $showQualityBadges)
        ]
        // The trailer button opens the URL in Safari — tvOS has no browser,
        // so neither the button nor its toggle exist there.
        #if os(iOS)
        rows.append(.init(id: "detailTrailerButton", icon: "movieclapper", label: loc.localized("settings.detailPage.trailerButton"), value: $showTrailerButton))
        #endif
        return rows
    }

    /// iOS marks debug icons orange to signal developer territory. tvOS
    /// currently ignores `tint` and uses `themeManager.accent` — preserving
    /// the existing platform difference.
    var debugToggleRows: [SettingsToggleRow] {
        [
            .init(id: "debugFastSleep", icon: "moon.zzz.fill", label: loc.localized("settings.debug.fastSleepTimer"), value: $debugFastSleepTimer, tint: .orange),
            .init(id: "debugSkipToEnd", icon: "forward.end.fill", label: loc.localized("settings.debug.skipToEnd"), value: $debugShowSkipToEnd, tint: .orange)
        ]
    }

    // MARK: Body

    /// Clears the API client cache and broadcasts `cinemaxShouldRefreshCatalogue` so Home
    /// and Library reload from the server on their next render. Shown as a toast for feedback.
    func refreshCatalogue() {
        appState.apiClient.clearCache()
        NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
        toasts.success(loc.localized("toast.catalogueRefreshed"))
    }

    /// Probes Quick Connect availability once so the account screen only shows
    /// the authorize row on servers that support it. Silent on failure (the row
    /// just stays hidden). Guarded against the tvOS `.task` re-fire storm like
    /// `loadServerUsers`.
    func probeQuickConnect() async {
        guard !quickConnectProbeAttempted else { return }
        quickConnectProbeAttempted = true
        quickConnectEnabled = (try? await appState.apiClient.isQuickConnectEnabled()) ?? false
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
        .sheet(isPresented: $showLicenses) {
            LicensesView()
        }
        .sheet(isPresented: $showUserSwitch) {
            UserSwitchSheet()
                .environment(appState)
                .environment(themeManager)
                .environment(loc)
        }
        // tvOS `.sheet` renders a cramped modal (same reason the login Quick
        // Connect sheet uses `.fullScreenCover` there), so split the
        // presentation by platform.
        #if os(iOS)
        .sheet(isPresented: $showPrivacySecurity) { privacySecuritySheet }
        .sheet(isPresented: $showQuickConnectAuthorize) { quickConnectAuthorizeSheet }
        .sheet(isPresented: $showWatchedHistory) { watchedHistorySheet }
        #else
        .fullScreenCover(isPresented: $showPrivacySecurity) { privacySecuritySheet }
        .fullScreenCover(isPresented: $showQuickConnectAuthorize) { quickConnectAuthorizeSheet }
        .fullScreenCover(isPresented: $showWatchedHistory) { watchedHistorySheet }
        #endif
    }

    private var watchedHistorySheet: some View {
        WatchedHistoryScreen()
            .environment(appState)
            .environment(themeManager)
            .environment(loc)
            .environment(toasts)
    }

    private var privacySecuritySheet: some View {
        PrivacySecurityScreen()
            .environment(appState)
            .environment(themeManager)
            .environment(loc)
            .environment(toasts)
    }

    private var quickConnectAuthorizeSheet: some View {
        QuickConnectAuthorizeSheet()
            .environment(appState)
            .environment(themeManager)
            .environment(loc)
            .environment(toasts)
    }
}
