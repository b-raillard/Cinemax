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

/// Single source of truth for the accent palette. Each case carries a full `Palette`
/// (accent / container / dim / onAccent × light+dark). `ThemeManager` reads these
/// values — adding a new accent means adding one case + one `Palette` entry here.
///
/// Order of cases follows the natural spectrum (rainbow) so the picker reads left-to-right.
enum AccentOption: String, CaseIterable, Identifiable {
    case red    = "red"
    case orange = "orange"
    case yellow = "yellow"
    case green  = "green"
    case cyan   = "cyan"
    case blue   = "blue"
    case indigo = "indigo"
    case purple = "purple"
    case pink   = "pink"
    /// Easter egg accent — hidden from the picker until unlocked via the Server/Login
    /// logo tap sequence. When active, `ThemeManager` ignores the palette below and
    /// drives `accent`/`accentContainer`/`accentDim` from an animated HSB hue phase.
    case rainbow = "rainbow"

    var id: String { rawValue }

    /// Cases visible in the accent picker. Rainbow is filtered out unless the user
    /// has unlocked it via the easter egg.
    static func visibleCases(rainbowUnlocked: Bool) -> [AccentOption] {
        rainbowUnlocked ? allCases : allCases.filter { $0 != .rainbow }
    }

    /// The nine base accents the easter egg cycles through.
    static var cyclingCases: [AccentOption] {
        allCases.filter { $0 != .rainbow }
    }

    struct Palette {
        let accentLight: UInt
        let accentDark: UInt
        let containerLight: UInt
        let containerDark: UInt
        let dimLight: UInt
        let dimDark: UInt
        let onAccentLight: UInt
        let onAccentDark: UInt
    }

    var palette: Palette {
        switch self {
        case .red:    Palette(accentLight: 0xC1272D, accentDark: 0xFF6B6B,
                              containerLight: 0xE53935, containerDark: 0xE53935,
                              dimLight: 0x8C1C20, dimDark: 0xCC2C30,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x3D0000)
        case .orange: Palette(accentLight: 0xCC5A0A, accentDark: 0xFF8C42,
                              containerLight: 0xE06A1A, containerDark: 0xE06A1A,
                              dimLight: 0xA84508, dimDark: 0xCC5500,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x3D1500)
        case .yellow: Palette(accentLight: 0x8A5A00, accentDark: 0xFFC940,
                              containerLight: 0xD19500, containerDark: 0xD19500,
                              dimLight: 0x6B4500, dimDark: 0xB37B00,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x2B1F00)
        case .green:  Palette(accentLight: 0x1F7A50, accentDark: 0x4CAF82,
                              containerLight: 0x2E8A5E, containerDark: 0x2E8A5E,
                              dimLight: 0x155F3E, dimDark: 0x1F7A50,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x001A0D)
        case .cyan:   Palette(accentLight: 0x0E8F84, accentDark: 0x2DD4BF,
                              containerLight: 0x0BAEA0, containerDark: 0x0BAEA0,
                              dimLight: 0x08756B, dimDark: 0x009A8C,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x001A18)
        case .blue:   Palette(accentLight: 0x0060D6, accentDark: 0x679CFF,
                              containerLight: 0x007AFF, containerDark: 0x007AFF,
                              dimLight: 0x0050B8, dimDark: 0x0070EB,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x001F4A)
        case .indigo: Palette(accentLight: 0x3730A3, accentDark: 0x818CF8,
                              containerLight: 0x4F46E5, containerDark: 0x4F46E5,
                              dimLight: 0x262183, dimDark: 0x3B3FB5,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x0A0A2B)
        case .purple: Palette(accentLight: 0x7A2BD0, accentDark: 0xBF7FFF,
                              containerLight: 0x8E3CE0, containerDark: 0x9B57E0,
                              dimLight: 0x651FB0, dimDark: 0x8B44CF,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x1A0040)
        case .pink:   Palette(accentLight: 0xC2185B, accentDark: 0xFF6BB5,
                              containerLight: 0xD63384, containerDark: 0xE0458F,
                              dimLight: 0xA0144A, dimDark: 0xCC3578,
                              onAccentLight: 0xFFFFFF, onAccentDark: 0x3D001A)
        case .rainbow: Palette(accentLight: 0x6B46C1, accentDark: 0xA78BFA,
                               containerLight: 0x7C3AED, containerDark: 0x8B5CF6,
                               dimLight: 0x5B21B6, dimDark: 0x7C3AED,
                               onAccentLight: 0xFFFFFF, onAccentDark: 0x1A0040)
        }
    }

    /// Preview swatch — resolves against the active trait collection so the dot
    /// matches the live accent in both light and dark mode.
    var color: Color { Color.dynamic(light: palette.accentLight, dark: palette.accentDark) }
}

// MARK: - Rainbow Swatch

/// Shared rainbow preview dot used by every accent picker. Kept here so the iOS +
/// tvOS Settings pickers render identical visuals.
struct RainbowAccentSwatch: View {
    var diameter: CGFloat = 28

    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    gradient: Gradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red]),
                    center: .center
                )
            )
            .frame(width: diameter, height: diameter)
    }
}

// MARK: - Accent Easter Egg

/// Pure resolver that powers the logo-tap easter egg on `ServerSetupScreen` and
/// `LoginScreen`. Each tap advances the accent through `AccentOption.cyclingCases`;
/// after a full loop during the session the rainbow accent is unlocked + applied.
/// Once unlocked it stays available in the settings picker forever.
///
/// The resolver is pure (no state mutation) so callers can bind directly to `@State`
/// and `@AppStorage` without wrestling with inout on property-wrapper-backed values.
enum AccentEasterEgg {
    struct TapResult {
        /// Accent key to apply after this tap.
        let nextAccentKey: String
        /// `true` when this tap completed the loop and rainbow should become unlocked.
        let unlockedRainbow: Bool
    }

    static func tap(
        currentAccentKey: String,
        previousTapCount: Int,
        rainbowAlreadyUnlocked: Bool
    ) -> TapResult {
        let cycle = AccentOption.cyclingCases
        let nextTapCount = previousTapCount + 1

        if nextTapCount >= cycle.count, !rainbowAlreadyUnlocked {
            return TapResult(nextAccentKey: AccentOption.rainbow.rawValue, unlockedRainbow: true)
        }

        if let idx = cycle.firstIndex(where: { $0.rawValue == currentAccentKey }) {
            return TapResult(nextAccentKey: cycle[(idx + 1) % cycle.count].rawValue, unlockedRainbow: false)
        }
        // Currently on rainbow (already unlocked) — jump back to start of cycle.
        return TapResult(nextAccentKey: cycle.first?.rawValue ?? "green", unlockedRainbow: false)
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
