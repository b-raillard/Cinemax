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
    static let homeShowNextUp = "home.showNextUp"
    static let homeShowRecentlyAdded = "home.showRecentlyAdded"
    static let homeShowFavorites = "home.showFavorites"
    static let homeShowGenreRows = "home.showGenreRows"
    static let homeShowWatchingNow = "home.showWatchingNow"
    /// JSON `[String]` — the genres the user picked to surface as Home rows.
    /// An **empty string** (the default) means "never configured" → Home shows
    /// a deterministic default set; once the user touches the picker the value
    /// becomes a JSON array (possibly `[]`, meaning an explicit empty choice).
    /// Stored as a string so `@AppStorage` drives live re-renders even inside a
    /// `navigationDestination` rendered from an extension method (where
    /// `@Observable` changes don't re-render — see CLAUDE.md). Read/write
    /// through `HomeGenrePreferences`.
    static let homeSelectedGenres = "home.selectedGenres"

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

    // Library landing (iOS + tvOS)
    /// `"browse"` (default) shows the cinematic hero + genre rows ("By genre");
    /// `"grid"` shows a flat poster grid using the default sort ("Show all").
    /// Honored on both platforms — the iOS toggle lives in Appearance, the
    /// tvOS one in Appearance too. Raw key keeps its legacy `tv` name to
    /// preserve any existing on-device preference; the value is platform-neutral.
    static let libraryBrowseLayout = "library.tvBrowseLayout"

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
        static let homeShowNextUp = true
        static let homeShowRecentlyAdded = true
        static let homeShowFavorites = true
        static let homeShowGenreRows = true
        static let homeShowWatchingNow = true

        static let detailShowQualityBadges = true
        static let detailShowTrailerButton = true

        static let searchSaveHistory = true

        static let libraryBrowseLayout = LibraryBrowseLayout.browse.rawValue

        static let privacyMaxContentAge = 0

        static let debugFastSleepTimer = false
        static let debugShowSkipToEnd = false

        static let rainbowUnlocked = false
    }
}

/// Landing layout for `MediaLibraryScreen` (iOS + tvOS). Controls whether the
/// screen opens on the cinematic browse view (hero + genre rows + browse grid,
/// "By genre") or on the flat poster grid using the default sort ("Show all").
/// Filter state still toggles to the grid regardless — this only governs the
/// *unfiltered* landing.
enum LibraryBrowseLayout: String, CaseIterable, Identifiable {
    case browse
    case grid

    var id: String { rawValue }
}

/// Read/write helper for the user-configurable Home genre rows
/// (`SettingsKey.homeSelectedGenres`). Centralizes the JSON encoding and the
/// "empty string = never configured" sentinel so `HomeViewModel` (not a View,
/// reads `UserDefaults` directly) and the Settings genre pickers (Views, bind
/// through `@AppStorage`) agree on the exact same semantics.
enum HomeGenrePreferences {
    /// How many genre rows Home shows when the user hasn't picked any. A
    /// deterministic prefix of the server's (sorted) genre list — coherent,
    /// not random (see the de-randomization decision).
    static let defaultRowCount = 6

    /// `true` once the user has made an explicit choice in the picker. Distinct
    /// from "has selected genres" so an explicit empty choice (zero rows) is not
    /// mistaken for the unconfigured default.
    static func isConfigured() -> Bool {
        guard let raw = UserDefaults.standard.string(forKey: SettingsKey.homeSelectedGenres) else { return false }
        return !raw.isEmpty
    }

    /// The user's explicit genre picks (empty if unconfigured or explicitly empty).
    static func selectedGenres() -> [String] {
        decode(UserDefaults.standard.string(forKey: SettingsKey.homeSelectedGenres))
    }

    /// Persist an explicit selection. Always marks the preference configured —
    /// even for an empty array, which means "no genre rows".
    static func setSelectedGenres(_ genres: [String]) {
        guard let data = try? JSONEncoder().encode(genres),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: SettingsKey.homeSelectedGenres)
    }

    /// The genres to actually render as Home rows, given the full available
    /// list (already sorted by the caller). Unconfigured → default prefix;
    /// configured → the explicit picks intersected with what's available and
    /// re-ordered to the canonical (available) order. No cap on count.
    static func effectiveGenres(available: [String]) -> [String] {
        guard isConfigured() else { return Array(available.prefix(defaultRowCount)) }
        let chosen = Set(selectedGenres())
        return available.filter { chosen.contains($0) }
    }

    /// Decodes the JSON `[String]` payload of `homeSelectedGenres`. Shared by
    /// the static accessors and the picker Views (which hold the raw string in
    /// `@AppStorage` for reactivity and decode it for display).
    static func decode(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }
}
