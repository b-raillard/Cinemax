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
    case appearance
    case account
    case server
    case interface
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

    /// Filters `allCases` by admin visibility and platform. Use this instead of
    /// raw `allCases` in rendering code — keeps gating in one place.
    @MainActor static func visibleCases(isAdmin: Bool, isTVOS: Bool) -> [SettingsCategory] {
        allCases.filter { category in
            if isTVOS && category.isAdminOnly { return false }
            if category.isAdminOnly && !isAdmin { return false }
            return true
        }
    }
}

// MARK: - tvOS Focus Tracking

#if os(tvOS)
enum SettingsFocus: Hashable {
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
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(LocalizationManager.self) var loc
    @Environment(ToastCenter.self) var toasts
    @State var showLogOutAlert = false
    @State var showLicenses = false
    @State var showUserSwitch = false
    @State var showPrivacySecurity = false
    @State var selectedCategory: SettingsCategory? = nil
    @State var currentUser: UserDto? = nil

    // Shared stored properties — keys + defaults live in SettingsKey
    @AppStorage(SettingsKey.motionEffects) var motionEffects: Bool = SettingsKey.Default.motionEffects
    @AppStorage(SettingsKey.forceSubtitles) var forceSubtitles: Bool = SettingsKey.Default.forceSubtitles
    @AppStorage(SettingsKey.render4K) var render4K: Bool = SettingsKey.Default.render4K
    @AppStorage(SettingsKey.autoPlayNextEpisode) var autoPlayNextEpisode: Bool = SettingsKey.Default.autoPlayNextEpisode
    @AppStorage(SettingsKey.darkMode) var darkModeStorage: Bool = SettingsKey.Default.darkMode
    @AppStorage(SettingsKey.homeShowContinueWatching) var showContinueWatching: Bool = SettingsKey.Default.homeShowContinueWatching
    @AppStorage(SettingsKey.homeShowRecentlyAdded) var showRecentlyAdded: Bool = SettingsKey.Default.homeShowRecentlyAdded
    @AppStorage(SettingsKey.homeShowGenreRows) var showGenreRows: Bool = SettingsKey.Default.homeShowGenreRows
    @AppStorage(SettingsKey.homeShowWatchingNow) var showWatchingNow: Bool = SettingsKey.Default.homeShowWatchingNow
    @AppStorage(SettingsKey.detailShowQualityBadges) var showQualityBadges: Bool = SettingsKey.Default.detailShowQualityBadges
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
    @State var showSwitchAccountAlert = false
    @State var showSleepTimerPicker = false
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

    var interfaceToggleRows: [SettingsToggleRow] {
        [
            .init(id: "motion", icon: "sparkles", label: loc.localized("settings.motionEffects"), value: $motionEffects),
            .init(id: "subtitles", icon: "captions.bubble", label: loc.localized("settings.forceSubtitles"), value: $forceSubtitles),
            .init(id: "4k", icon: "4k.tv", label: loc.localized("settings.4kRendering"), value: $render4K),
            .init(id: "autoPlayNext", icon: "play.square.stack", label: loc.localized("settings.autoPlayNextEpisode"), value: $autoPlayNextEpisode)
        ]
    }

    var homePageToggleRows: [SettingsToggleRow] {
        [
            .init(id: "homeContinueWatching", icon: "play.circle", label: loc.localized("settings.homePage.continueWatching"), value: $showContinueWatching),
            .init(id: "homeRecentlyAdded", icon: "sparkles.rectangle.stack", label: loc.localized("settings.homePage.recentlyAdded"), value: $showRecentlyAdded),
            .init(id: "homeGenreRows", icon: "square.grid.2x2", label: loc.localized("settings.homePage.genreRows"), value: $showGenreRows),
            .init(id: "homeWatchingNow", icon: "person.2.wave.2", label: loc.localized("settings.homePage.watchingNow"), value: $showWatchingNow)
        ]
    }

    var detailPageToggleRows: [SettingsToggleRow] {
        [
            .init(id: "detailQualityBadges", icon: "info.square", label: loc.localized("settings.detailPage.qualityBadges"), value: $showQualityBadges)
        ]
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

    /// Fetches the signed-in user's `UserDto` so the Account header can render
    /// the primary image (with `primaryImageTag` for cache-busting) and fall
    /// back to initials when no image exists.
    func fetchCurrentUser() async {
        guard let id = appState.currentUserId else { return }
        if let users = try? await appState.apiClient.getUsers() {
            currentUser = users.first { $0.id == id }
        }
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
        .sheet(isPresented: $showPrivacySecurity) {
            PrivacySecurityScreen()
                .environment(appState)
                .environment(themeManager)
                .environment(loc)
                .environment(toasts)
        }
    }
}
