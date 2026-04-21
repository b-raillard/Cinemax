import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI
#if canImport(UIKit)
import UIKit
#endif
import Network

// MARK: - Shared Toggle Indicator

/// Custom toggle capsule used on both iOS and tvOS to ensure visual consistency.
/// Renders a pill-shaped track that fills with `accent` when on, with a white
/// sliding knob. Interaction is handled by the parent row / button.
struct CinemaToggleIndicator: View {
    let isOn: Bool
    let accent: Color
    var animated: Bool = true

    var body: some View {
        Capsule()
            .fill(isOn ? accent : CinemaColor.surfaceContainerHighest)
            .frame(width: 52, height: 32)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 26, height: 26)
                    .padding(3)
            }
            .animation(animated ? .easeInOut(duration: 0.15) : nil, value: isOn)
    }
}

// MARK: - Accent Color Definition

enum AccentOption: String, CaseIterable, Identifiable {
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

enum SettingsCategory: String, CaseIterable, Identifiable {
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
    @State var selectedCategory: SettingsCategory? = nil

    // Shared stored properties
    @AppStorage("motionEffects") var motionEffects: Bool = true
    @AppStorage("forceSubtitles") var forceSubtitles: Bool = false
    @AppStorage("render4K") var render4K: Bool = true
    @AppStorage("autoPlayNextEpisode") var autoPlayNextEpisode: Bool = true
    @AppStorage("darkMode") var darkModeStorage: Bool = true
    @AppStorage("home.showContinueWatching") var showContinueWatching: Bool = true
    @AppStorage("home.showRecentlyAdded") var showRecentlyAdded: Bool = true
    @AppStorage("home.showGenreRows") var showGenreRows: Bool = true
    @AppStorage("home.showWatchingNow") var showWatchingNow: Bool = true
    @AppStorage("detail.showQualityBadges") var showQualityBadges: Bool = true
    @AppStorage("sleepTimerDefaultMinutes") var sleepTimerMinutes: Int = 0
    @AppStorage("debug.fastSleepTimer") var debugFastSleepTimer: Bool = false
    @AppStorage("debug.showSkipToEnd") var debugShowSkipToEnd: Bool = false
    @State var fontScale: Double = UserDefaults.standard.object(forKey: "uiScale") as? Double ?? 1.0
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
        .alert(loc.localized("action.logOut"), isPresented: $showLogOutAlert) {
            Button(loc.localized("action.logOut"), role: .destructive) {
                appState.logout()
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("settings.logOutConfirm"))
        }
    }
}
