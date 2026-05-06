import Foundation

/// Single source of truth for every `@AppStorage` key and its default value.
/// Previously these were duplicated as string literals across `SettingsScreen`,
/// `HomeScreen`, `MediaDetailScreen`, `VideoPlayerView`, `VideoPlayerCoordinator`,
/// `ThemeManager`, `LocalizationManager`, and `AppNavigation` — a typo or default
/// drift in one site could silently break another.
///
/// Usage at call sites:
///     @AppStorage(SettingsKey.motionEffects) var motionEffects: Bool = SettingsKey.Default.motionEffects
enum SettingsKey {
    // Appearance / theme
    static let darkMode = "darkMode"
    static let accentColor = "accentColor"
    static let uiScale = "uiScale"
    static let appLanguage = "appLanguage"

    // Interface
    static let motionEffects = "motionEffects"
    static let forceSubtitles = "forceSubtitles"
    static let render4K = "render4K"
    static let autoPlayNextEpisode = "autoPlayNextEpisode"
    static let sleepTimerDefaultMinutes = "sleepTimerDefaultMinutes"

    // Home page sections
    static let homeShowContinueWatching = "home.showContinueWatching"
    static let homeShowRecentlyAdded = "home.showRecentlyAdded"
    static let homeShowGenreRows = "home.showGenreRows"
    static let homeShowWatchingNow = "home.showWatchingNow"

    // Detail page
    static let detailShowQualityBadges = "detail.showQualityBadges"

    // Library landing (tvOS only)
    /// `"browse"` (default) shows hero + genre rows; `"grid"` shows a flat poster grid using the default sort.
    static let libraryTVBrowseLayout = "library.tvBrowseLayout"

    // Privacy & Security
    /// Maximum content age (years) for items shown across the app.
    /// `0` = unrestricted; 10/12/14/16/18 select a ceiling and any item rated
    /// above it is hidden. Routes through `apiClient.applyContentRatingLimit`.
    static let privacyMaxContentAge = "privacy.maxContentAge"

    // Debug
    static let debugFastSleepTimer = "debug.fastSleepTimer"
    static let debugShowSkipToEnd = "debug.showSkipToEnd"

    // Easter eggs
    static let rainbowUnlocked = "easterEgg.rainbowUnlocked"

    enum Default {
        static let darkMode = true
        static let accentColor = "green"
        static let uiScale = 1.0
        static let appLanguage = "fr"

        static let motionEffects = true
        static let forceSubtitles = false
        static let render4K = true
        static let autoPlayNextEpisode = true
        static let sleepTimerDefaultMinutes = 0

        static let homeShowContinueWatching = true
        static let homeShowRecentlyAdded = true
        static let homeShowGenreRows = true
        static let homeShowWatchingNow = true

        static let detailShowQualityBadges = true

        static let libraryTVBrowseLayout = LibraryTVBrowseLayout.browse.rawValue

        static let privacyMaxContentAge = 0

        static let debugFastSleepTimer = false
        static let debugShowSkipToEnd = false

        static let rainbowUnlocked = false
    }
}

/// tvOS landing layout for `MediaLibraryScreen`. Controls whether the screen
/// opens on the cinematic browse view (hero + genre rows + browse grid) or on
/// the flat poster grid using the default sort. Filter state still toggles to
/// the grid regardless — this only governs the *unfiltered* landing.
enum LibraryTVBrowseLayout: String, CaseIterable, Identifiable {
    case browse
    case grid

    var id: String { rawValue }
}
