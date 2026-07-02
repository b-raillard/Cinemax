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
    static let render4K = "render4K"
    static let autoPlayNextEpisode = "autoPlayNextEpisode"
    static let sleepTimerDefaultMinutes = "sleepTimerDefaultMinutes"
    /// When `true`, online playback uses the native `AVPlayer` engine (AVKit
    /// chrome) instead of the default VLC engine. VLC DirectPlays MKV/HEVC/DV
    /// without a server transcode (no freezes); native is the escape hatch for
    /// edge cases. Default `false` ⇒ VLC.
    static let forceNativeAVPlayer = "forceNativeAVPlayer"

    // Home page sections
    static let homeShowContinueWatching = "home.showContinueWatching"
    static let homeShowRecentlyAdded = "home.showRecentlyAdded"
    static let homeShowFavorites = "home.showFavorites"
    static let homeShowGenreRows = "home.showGenreRows"
    static let homeShowWatchingNow = "home.showWatchingNow"

    // Detail page
    static let detailShowQualityBadges = "detail.showQualityBadges"
    /// iOS only — shows the "Bande-annonce" button on `MediaDetailScreen` when
    /// the item carries `remoteTrailers`. tvOS has no browser to open the URL,
    /// so the button (and its settings row) don't exist there.
    static let detailShowTrailerButton = "detail.showTrailerButton"

    // Search
    /// When `true` (default), successful search queries are persisted to
    /// `searchRecentQueries` and surfaced as tappable chips on the empty
    /// search screen. Toggle lives in Privacy & Security (it's a privacy
    /// concern, not an interface one).
    static let searchSaveHistory = "search.saveHistory"
    /// JSON `[String]` — most-recent-first list of past queries. Not a user
    /// setting; written only through `SearchViewModel`'s mutators.
    static let searchRecentQueries = "search.recentQueries"

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

    // Main menu customization
    static let menuMode = "menu.mode"                          // "default" | "custom"
    static let menuCustomKind = "menu.customKind"              // "contentType" | "library"
    static let menuContentTypeEntries = "menu.contentTypeEntries" // JSON [MenuEntry]
    static let menuLibraryEntries = "menu.libraryEntries"   // JSON [MenuEntry]
    static let menuCachedViews = "menu.cachedViews"               // JSON [LibraryView]

    // Easter eggs
    static let rainbowUnlocked = "easterEgg.rainbowUnlocked"

    // Offline-downloads feature gate — server-driven values cached locally so
    // an offline launch keeps the last-known gate (a user on a plane must
    // still reach their downloads). NOT user settings: written only by
    // `AppState` (refresh / logout), never by a Settings surface.
    static let downloadsGlobalFlagCache = "downloads.globalFlagCache" // Branding marker (server-wide)
    static let downloadsUserFlagCache = "downloads.userFlagCache"     // UserPolicy.enableContentDownloading

    enum Default {
        static let darkMode = true
        static let accentColor = "green"
        static let uiScale = 1.0
        static let appLanguage = "fr"

        static let motionEffects = true
        static let render4K = true
        static let autoPlayNextEpisode = true
        static let sleepTimerDefaultMinutes = 0
        static let forceNativeAVPlayer = false

        static let homeShowContinueWatching = true
        static let homeShowRecentlyAdded = true
        static let homeShowFavorites = true
        static let homeShowGenreRows = true
        static let homeShowWatchingNow = true

        static let detailShowQualityBadges = true
        static let detailShowTrailerButton = true

        static let searchSaveHistory = true

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
