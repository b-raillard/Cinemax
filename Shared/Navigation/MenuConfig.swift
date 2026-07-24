import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

// MARK: - LibraryView snapshot

/// Snapshot of one Jellyfin user library/view, persisted as JSON in
/// `UserDefaults` so the menu can re-render offline before a fresh
/// `getUserViews()` lands.
struct LibraryView: Codable, Equatable, Hashable {
    let id: String
    let name: String
    /// Raw `collectionType` from Jellyfin ("movies" | "tvshows" | "mixed" |
    /// "homevideos" | "music" | "books" | "photos" | …). `nil` for some
    /// special folders. Only video kinds are exposed in the menu picker.
    let collectionType: String?

    /// Non-video collection types that should be excluded — music, books,
    /// photos, and Jellyfin's special "Collections" (BoxSets) folder which
    /// only contains BoxSet entries (not playable as a flat grid). Anything
    /// else (`movies`, `tvshows`, `homevideos`, **and `nil`**) is treated as
    /// potentially video-bearing and surfaced in the picker. `nil` covers
    /// libraries created with type "Mixed Content" or "Other" — common for
    /// home setups that mix movies/series/recordings in one folder.
    // `boxsets` and `playlists` are intentionally NOT excluded: they carry
    // video content and are surfaced as folder-browse tabs (Collections /
    // Playlists) via `libraryTab(for:)` → `.libraryFolders`.
    static let nonVideoCollectionTypes: Set<String> = [
        "music", "musicvideos", "books", "photos",
        "livetv", "folders", "trailers"
    ]

    var isVideoLibrary: Bool {
        guard let collectionType else { return true }
        return !Self.nonVideoCollectionTypes.contains(collectionType)
    }
}

// MARK: - MenuEntry

/// One entry in the customizable menu. `id` doubles as identity, persistence
/// key, and as the lookup key from `ResolvedTab.destination` back to user
/// intent.
struct MenuEntry: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var enabled: Bool

    static let homeID = "home"
    static let searchID = "search"
    static let settingsID = "settings"
    static let moviesID = "movies"
    static let seriesID = "series"

    /// Always present in custom mode. Toggle attempts are silently ignored.
    /// Only Settings is strictly mandatory — without it the user couldn't
    /// reach this configuration screen again. Home and Search are
    /// non-mandatory but default to enabled.
    static let mandatoryIDs: Set<String> = [settingsID]

    static let libraryIDPrefix = "lib:"
    static func libraryID(viewId: String) -> String { libraryIDPrefix + viewId }

    var isMandatory: Bool { Self.mandatoryIDs.contains(id) }
    var libraryViewID: String? {
        id.hasPrefix(Self.libraryIDPrefix)
            ? String(id.dropFirst(Self.libraryIDPrefix.count))
            : nil
    }
}

// MARK: - ResolvedTab

/// What `MainTabView` actually renders. Built from the user's `MenuConfigStore`
/// state and (in library mode) the cached `availableViews` list.
struct ResolvedTab: Identifiable, Hashable {
    enum Destination: Hashable {
        case home
        case search
        case settings
        case mediaLibrary(BaseItemKind)
        case libraryView(id: String, name: String, kind: BaseItemKind?)
        /// A folder-of-folders library (Collections / Playlists). Items inside
        /// are themselves folders, so this routes to `LibraryFolderBrowseScreen`
        /// which lists the folders and drills into each one's contents — unlike
        /// `libraryView`, whose cards open item detail directly.
        case libraryFolders(id: String, name: String, isPlaylist: Bool)
    }

    let id: String
    let icon: String
    /// Localization key — preferred when set (`tab.home` etc.).
    let titleKey: String?
    /// Literal title — used for user-named library tabs.
    let title: String?
    let destination: Destination

    @MainActor
    func displayTitle(_ loc: LocalizationManager) -> String {
        if let titleKey { return loc.localized(titleKey) }
        return title ?? ""
    }
}

// MARK: - MenuConfigStore

/// Owns the user's customizable menu configuration and resolves it into the
/// list of tabs `MainTabView` should render. Backed by `UserDefaults` so it
/// survives launches and works offline.
@MainActor @Observable
final class MenuConfigStore {

    enum Mode: String, Codable, CaseIterable, Identifiable {
        case `default`, custom
        var id: String { rawValue }
    }

    enum CustomKind: String, Codable, CaseIterable, Identifiable {
        case contentType, library
        var id: String { rawValue }
    }

    /// Hard cap on the number of enabled entries. Matches iOS's native tab
    /// bar capacity in compact width — beyond 5, `TabView` instantiates a
    /// `UIMoreNavigationController` to host an overflow page, and any tab
    /// list mutation crossing the threshold tears it down and dumps the
    /// user back to the first tab (an UIKit lifecycle quirk we can't
    /// override from SwiftUI). Refusing the 6th toggle keeps `TabView`
    /// inside its happy-path and avoids that whole class of bug.
    static let maxEnabledTabs = 5

    // Stored properties — no `didSet` on purpose. Mixing `@Observable` macro
    // with `didSet` can cause subtle propagation issues: the macro instruments
    // the setter via `withMutation { ... }`, but a `didSet` body running
    // afterwards may race with the SwiftUI dependency-tracking commit phase
    // (especially on collections of `Codable` value types). All persistence
    // is performed explicitly inside the mutator methods below — single
    // responsibility, deterministic ordering, no hidden side effects.
    var mode: Mode
    var customKind: CustomKind
    var contentTypeEntries: [MenuEntry]
    var libraryEntries: [MenuEntry]
    /// Cache of last-fetched video libraries. Persisted so library mode still
    /// renders on an offline launch without a network call.
    var availableViews: [LibraryView]

    /// Memoized final tab list for `MainTabView` — the resolution of `mode` /
    /// `customKind` / entry arrays / `availableViews`. Recomputed by
    /// `recomputeResolvedTabs()` at the end of every mutator that changes an
    /// input (see that method); consumers read this stored value so Observation
    /// re-renders them exactly when the resolved tabs change. `private(set)` so
    /// only the store's mutators can publish a new value.
    ///
    /// No truncation/cap — SwiftUI's `TabView` on iPhone in compact width
    /// natively creates an overflow ("More") tab when the count exceeds 5,
    /// rendered with the iOS 26 liquid-glass treatment. We don't replace that
    /// behaviour with a custom synthetic tab.
    private(set) var resolvedTabs: [ResolvedTab] = []

    var isLoadingViews: Bool = false
    var lastFetchError: String?

    private var apiClient: (any APIClientProtocol)?
    private var userId: String?
    /// Monotonic id for refreshAvailableViews — newest call wins (see method).
    private var refreshGeneration = 0

    init() {
        let defaults = UserDefaults.standard
        self.mode = Mode(rawValue: defaults.string(forKey: SettingsKey.menuMode) ?? "") ?? .default
        self.customKind = CustomKind(rawValue: defaults.string(forKey: SettingsKey.menuCustomKind) ?? "") ?? .contentType
        let storedContentType = Self.load([MenuEntry].self, forKey: SettingsKey.menuContentTypeEntries) ?? Self.defaultContentTypeEntries
        let storedLibrary = Self.load([MenuEntry].self, forKey: SettingsKey.menuLibraryEntries) ?? []
        // Enforce the cap on persisted state — defensive against snapshots
        // saved before the cap existed.
        self.contentTypeEntries = Self.applyCap(to: storedContentType)
        self.libraryEntries = Self.applyCap(to: storedLibrary)
        self.availableViews = Self.load([LibraryView].self, forKey: SettingsKey.menuCachedViews) ?? []
        // Seed the memoized tab list from the restored state (all stored
        // properties are initialized by this point).
        recomputeResolvedTabs()
    }

    /// Trims the enabled flags of `entries` so the total enabled count does
    /// not exceed `maxEnabledTabs`. Mandatory entries always stay enabled;
    /// excess non-mandatory entries get their `enabled` flipped to false,
    /// starting from the tail of the list.
    private static func applyCap(to entries: [MenuEntry]) -> [MenuEntry] {
        let mandatoryEnabled = entries.filter { $0.isMandatory && $0.enabled }.count
        let nonMandatoryBudget = max(0, maxEnabledTabs - mandatoryEnabled)
        var nonMandatoryUsed = 0
        return entries.map { entry in
            if !entry.enabled || entry.isMandatory { return entry }
            if nonMandatoryUsed < nonMandatoryBudget {
                nonMandatoryUsed += 1
                return entry
            }
            return MenuEntry(id: entry.id, enabled: false)
        }
    }

    // MARK: - Setters with side effects

    /// Use these in UI bindings so persistence and downstream effects fire on
    /// every write. Direct `store.mode = …` on the property still mutates
    /// in-memory state but **won't persist** — callers must go through here.
    func setMode(_ value: Mode) {
        mode = value
        Self.persist(value.rawValue, forKey: SettingsKey.menuMode)
        recomputeResolvedTabs()
    }

    func setCustomKind(_ value: CustomKind) {
        customKind = value
        Self.persist(value.rawValue, forKey: SettingsKey.menuCustomKind)
        if value == .library { ensureLibraryEntriesPopulated() }
        recomputeResolvedTabs()
    }

    func attach(apiClient: any APIClientProtocol, userId: String?) {
        self.apiClient = apiClient
        self.userId = userId
    }

    // MARK: - Defaults

    static let defaultContentTypeEntries: [MenuEntry] = [
        .init(id: MenuEntry.homeID, enabled: true),
        .init(id: MenuEntry.moviesID, enabled: true),
        .init(id: MenuEntry.seriesID, enabled: true),
        .init(id: MenuEntry.searchID, enabled: true),
        .init(id: MenuEntry.settingsID, enabled: true)
    ]

    // MARK: - Mutations

    /// Flips `enabled` on the entry with `id`. Mandatory entries (home/search/
    /// settings) are silent no-ops — UI grays them out as a hint.
    ///
    /// All mutators build a fresh copy and assign back through the property
    /// setter. In-place mutating methods (`Array.move`, `Array[i].x = …`,
    /// `Array.swapAt`) sometimes fail to deliver an `@Observable` change
    /// notification to downstream views — the macro instruments the property
    /// setter, but `mutating` calls on stored properties of value types can
    /// bypass it depending on how the optimiser folds the access. Copy +
    /// reassign always goes through the setter, so `MainTabView`'s
    /// `resolvedTabs` read re-evaluates immediately after a reorder/toggle.
    /// Outcome of a toggle attempt — UI uses this to decide whether to play
    /// haptic / show a "max reached" toast.
    enum ToggleResult {
        /// The entry is now enabled.
        case enabled
        /// The entry is now disabled.
        case disabled
        /// Toggle refused — would have pushed enabled count past
        /// `maxEnabledTabs`. UI should show a toast.
        case refusedCapReached
        /// No-op (mandatory entry, or entry id not found).
        case noChange
    }

    @discardableResult
    func toggle(_ id: String) -> ToggleResult {
        guard !MenuEntry.mandatoryIDs.contains(id) else { return .noChange }
        switch customKind {
        case .contentType:
            return toggleInternal(id, in: \.contentTypeEntries, persist: persistContentTypeEntries)
        case .library:
            return toggleInternal(id, in: \.libraryEntries, persist: persistLibraryEntries)
        }
    }

    private func toggleInternal(
        _ id: String,
        in keyPath: ReferenceWritableKeyPath<MenuConfigStore, [MenuEntry]>,
        persist: () -> Void
    ) -> ToggleResult {
        var copy = self[keyPath: keyPath]
        guard let idx = copy.firstIndex(where: { $0.id == id }) else { return .noChange }
        let wantsEnable = !copy[idx].enabled
        if wantsEnable {
            let currentEnabled = copy.filter { $0.enabled }.count
            // `currentEnabled` doesn't include the flip-target yet (still
            // disabled in `copy`); enabling pushes the count to + 1.
            if currentEnabled + 1 > Self.maxEnabledTabs {
                return .refusedCapReached
            }
        }
        copy[idx].enabled.toggle()
        self[keyPath: keyPath] = copy
        persist()
        recomputeResolvedTabs()
        return wantsEnable ? .enabled : .disabled
    }

    /// iOS native `.onMove` bridge — applies to whichever list is active.
    func move(fromOffsets: IndexSet, toOffset: Int) {
        switch customKind {
        case .contentType:
            var copy = contentTypeEntries
            copy.move(fromOffsets: fromOffsets, toOffset: toOffset)
            contentTypeEntries = copy
            persistContentTypeEntries()
        case .library:
            var copy = libraryEntries
            copy.move(fromOffsets: fromOffsets, toOffset: toOffset)
            libraryEntries = copy
            persistLibraryEntries()
        }
        recomputeResolvedTabs()
    }

    /// tvOS bridge — swap with neighbor at `delta` offset (-1 = up, +1 = down).
    func moveBy(_ id: String, delta: Int) {
        switch customKind {
        case .contentType:
            guard let i = contentTypeEntries.firstIndex(where: { $0.id == id }) else { return }
            let target = i + delta
            guard target >= 0, target < contentTypeEntries.count else { return }
            var copy = contentTypeEntries
            copy.swapAt(i, target)
            contentTypeEntries = copy
            persistContentTypeEntries()
        case .library:
            guard let i = libraryEntries.firstIndex(where: { $0.id == id }) else { return }
            let target = i + delta
            guard target >= 0, target < libraryEntries.count else { return }
            var copy = libraryEntries
            copy.swapAt(i, target)
            libraryEntries = copy
            persistLibraryEntries()
        }
        // Only reached on a successful swap — the guards above `return` early
        // when nothing moved, so this never recomputes for a no-op.
        recomputeResolvedTabs()
    }

    // MARK: - Persistence (explicit)

    private func persistContentTypeEntries() {
        Self.persist(contentTypeEntries, forKey: SettingsKey.menuContentTypeEntries)
    }

    private func persistLibraryEntries() {
        Self.persist(libraryEntries, forKey: SettingsKey.menuLibraryEntries)
    }

    private func persistAvailableViews() {
        Self.persist(availableViews, forKey: SettingsKey.menuCachedViews)
    }

    /// Restore factory defaults (mode + both entry lists, but keep
    /// `availableViews` cache — it's tied to the server, not the menu).
    func reset() {
        mode = .default
        customKind = .contentType
        contentTypeEntries = Self.defaultContentTypeEntries
        libraryEntries = makeLibraryDefaultEntries(from: availableViews)
        Self.persist(mode.rawValue, forKey: SettingsKey.menuMode)
        Self.persist(customKind.rawValue, forKey: SettingsKey.menuCustomKind)
        persistContentTypeEntries()
        persistLibraryEntries()
        recomputeResolvedTabs()
    }

    // MARK: - Views fetching

    /// Loads the user's libraries from the server, filters to video kinds,
    /// reconciles the persisted library-mode list. Safe to call from any
    /// MainActor context — sets `lastFetchError` on failure rather than
    /// throwing (callers show a toast).
    ///
    /// Overlap rule: the NEWEST call wins. Every caller runs its own fetch,
    /// but only the latest generation writes back / clears the spinner — so a
    /// double-tap can't interleave two `mergeLibraryEntries` passes, a retry
    /// during an in-flight fetch isn't silently dropped, and an account
    /// switch mid-flight can't persist the previous user's libraries (the
    /// stale fetch fails both the generation and the `userId` re-check).
    func refreshAvailableViews() async {
        guard let api = apiClient, let userId else { return }
        refreshGeneration += 1
        let gen = refreshGeneration
        isLoadingViews = true
        lastFetchError = nil
        defer { if gen == refreshGeneration { isLoadingViews = false } }

        do {
            let dtos = try await api.getUserViews(userId: userId)
            guard gen == refreshGeneration, userId == self.userId else { return }
            let views: [LibraryView] = dtos.compactMap { dto -> LibraryView? in
                guard let id = dto.id, let name = dto.name else { return nil }
                return LibraryView(id: id, name: name, collectionType: dto.collectionType?.rawValue)
            }.filter { $0.isVideoLibrary }

            // Idempotent: only fire an `@Observable` write when the data
            // actually changed. Prevents a spurious second re-render right
            // after the user opened the menu (which was racing with their
            // first toggle and surfaced as "redirected to Home").
            if views != availableViews {
                availableViews = views
                persistAvailableViews()
            }
            let merged = mergeLibraryEntries(existing: libraryEntries, views: views)
            if merged != libraryEntries {
                libraryEntries = merged
                persistLibraryEntries()
            }
            // Refresh the memoized tab list; the equality guard inside makes a
            // same-views refresh a no-op (no spurious re-render), preserving the
            // idempotence the two guards above establish.
            recomputeResolvedTabs()
        } catch {
            guard gen == refreshGeneration else { return }
            lastFetchError = "\(error)"
        }
    }

    /// Wipe the cached views (e.g., on server switch — view IDs are
    /// server-scoped). The mode itself is kept; on next switch to library
    /// the user sees an empty list until a refresh completes.
    func invalidateViews() {
        availableViews = []
        libraryEntries = []
        persistAvailableViews()
        persistLibraryEntries()
        recomputeResolvedTabs()
    }

    private func ensureLibraryEntriesPopulated() {
        if libraryEntries.isEmpty {
            libraryEntries = makeLibraryDefaultEntries(from: availableViews)
            persistLibraryEntries()
        }
    }

    /// Default library-mode layout. Home + Search + Settings are enabled by
    /// default (3 of the 5 cap), and the first 2 libraries are enabled to
    /// fill the remaining slots. Extra libraries land in the list **but
    /// disabled**, leaving the user to pick which ones to surface.
    ///
    /// Note: only Settings is *mandatory* (`isMandatory == true`) — Home and
    /// Search are toggleable but default-on for a sensible out-of-box
    /// experience.
    private func makeLibraryDefaultEntries(from views: [LibraryView]) -> [MenuEntry] {
        // Reserve 3 slots for the built-in entries we enable by default
        // (home, search, settings). Whatever's left = libraries enabled.
        let reservedSlots = 3
        let librarySlots = max(0, Self.maxEnabledTabs - reservedSlots)
        var base: [MenuEntry] = [
            .init(id: MenuEntry.homeID, enabled: true)
        ]
        for (offset, view) in views.enumerated() {
            base.append(.init(
                id: MenuEntry.libraryID(viewId: view.id),
                enabled: offset < librarySlots
            ))
        }
        base.append(.init(id: MenuEntry.searchID, enabled: true))
        base.append(.init(id: MenuEntry.settingsID, enabled: true))
        return base
    }

    /// Reconcile persisted entries with the fresh view list: keep existing
    /// order, drop entries whose libraries vanished, append new libraries
    /// before settings, ensure built-in ids (home/search/settings) are
    /// present.
    private func mergeLibraryEntries(existing: [MenuEntry], views: [LibraryView]) -> [MenuEntry] {
        let viewIDs = Set(views.map { $0.id })
        var result: [MenuEntry] = []
        var seenLibraryIDs: Set<String> = []

        for entry in existing {
            if let vid = entry.libraryViewID {
                // Library entry: keep only if the library still exists on
                // the server.
                if viewIDs.contains(vid) {
                    result.append(entry)
                    seenLibraryIDs.insert(vid)
                }
            } else {
                // Built-in entry (home / search / settings). Always
                // preserved — `mandatoryIDs` only governs the lock icon
                // and toggle-refusal, not list membership.
                result.append(entry)
            }
        }

        let newViews = views.filter { !seenLibraryIDs.contains($0.id) }
        if !newViews.isEmpty {
            let insertIdx = result.firstIndex(where: { $0.id == MenuEntry.settingsID }) ?? result.endIndex
            // Default new libraries to disabled if enabling them would push
            // past the cap — gives the user a chance to pick instead of
            // silently truncating what already worked.
            var availableSlots = Self.maxEnabledTabs - result.filter { $0.enabled }.count
            for view in newViews.reversed() {
                let enable = availableSlots > 0
                if enable { availableSlots -= 1 }
                result.insert(.init(id: MenuEntry.libraryID(viewId: view.id), enabled: enable), at: insertIdx)
            }
        }

        for id in [MenuEntry.homeID, MenuEntry.searchID, MenuEntry.settingsID] where !result.contains(where: { $0.id == id }) {
            result.append(.init(id: id, enabled: true))
        }

        return result
    }

    // MARK: - Resolution

    /// Recomputes `resolvedTabs` and publishes it only when the value actually
    /// changed. The equality guard mirrors the `availableViews`/`libraryEntries`
    /// guards in `refreshAvailableViews` — an idempotent mutation (e.g. a repeat
    /// refresh with the same views) must NOT fire a spurious `@Observable`
    /// notification (which previously surfaced as a "redirected to Home"
    /// flicker on iOS). Because inputs never carry `didSet` (see the RULE on
    /// `@Observable` + property observers), every mutator that changes an
    /// input to the resolution calls this at its end: `setMode`,
    /// `setCustomKind`, `toggleInternal`, `move`, `moveBy`, `reset`,
    /// `refreshAvailableViews`, `invalidateViews`, plus `init`.
    private func recomputeResolvedTabs() {
        let updated = computeResolvedTabs()
        if updated != resolvedTabs { resolvedTabs = updated }
    }

    /// Pure derivation of the tab list from the current mode / customKind /
    /// entry arrays / `availableViews`. Never observed directly — consumers
    /// read the memoized `resolvedTabs` instead.
    ///
    /// Never returns an empty list: `MainTabView` renders exactly this array,
    /// and zero tabs is a `TabView` with no content — a fully black screen
    /// with no recovery affordance. A custom/library resolution can
    /// legitimately come up empty (library cache invalidated by a server
    /// switch, then a fresh login that hasn't re-fetched views yet), so an
    /// empty resolution falls back to the canonical default 5.
    private func computeResolvedTabs() -> [ResolvedTab] {
        let resolved: [ResolvedTab]
        switch mode {
        case .default: resolved = defaultResolved
        case .custom:
            switch customKind {
            case .contentType: resolved = resolveContentType()
            case .library: resolved = resolveLibrary()
            }
        }
        return resolved.isEmpty ? defaultResolved : resolved
    }

    private var defaultResolved: [ResolvedTab] {
        [
            .init(id: "home", icon: "house.fill", titleKey: "tab.home", title: nil, destination: .home),
            .init(id: "movies", icon: "film", titleKey: "tab.movies", title: nil, destination: .mediaLibrary(.movie)),
            .init(id: "tvShows", icon: "tv.fill", titleKey: "tab.tvShows", title: nil, destination: .mediaLibrary(.series)),
            .init(id: "search", icon: "magnifyingglass", titleKey: "tab.search", title: nil, destination: .search),
            .init(id: "settings", icon: "gearshape", titleKey: "tab.settings", title: nil, destination: .settings)
        ]
    }

    private func resolveContentType() -> [ResolvedTab] {
        contentTypeEntries
            .filter { $0.enabled }
            .compactMap { builtinTab(for: $0.id) }
    }

    private func resolveLibrary() -> [ResolvedTab] {
        var tabs: [ResolvedTab] = []
        for entry in libraryEntries where entry.enabled {
            if let tab = builtinTab(for: entry.id) {
                tabs.append(tab)
            } else if let vid = entry.libraryViewID,
                      let view = availableViews.first(where: { $0.id == vid }) {
                tabs.append(libraryTab(for: view))
            }
        }
        return tabs
    }

    private func builtinTab(for id: String) -> ResolvedTab? {
        switch id {
        case MenuEntry.homeID:
            return .init(id: "home", icon: "house.fill", titleKey: "tab.home", title: nil, destination: .home)
        case MenuEntry.searchID:
            return .init(id: "search", icon: "magnifyingglass", titleKey: "tab.search", title: nil, destination: .search)
        case MenuEntry.settingsID:
            return .init(id: "settings", icon: "gearshape", titleKey: "tab.settings", title: nil, destination: .settings)
        case MenuEntry.moviesID:
            return .init(id: "movies", icon: "film", titleKey: "tab.movies", title: nil, destination: .mediaLibrary(.movie))
        case MenuEntry.seriesID:
            return .init(id: "tvShows", icon: "tv.fill", titleKey: "tab.tvShows", title: nil, destination: .mediaLibrary(.series))
        default:
            return nil
        }
    }

    private func libraryTab(for view: LibraryView) -> ResolvedTab {
        // Collections / Playlists are folders-of-folders — route them to the
        // folder-browse screen instead of the flat-grid library screen.
        if view.collectionType == "boxsets" || view.collectionType == "playlists" {
            let isPlaylist = view.collectionType == "playlists"
            return .init(
                id: MenuEntry.libraryID(viewId: view.id),
                icon: isPlaylist ? "music.note.list" : "rectangle.stack.fill",
                titleKey: nil,
                title: view.name,
                destination: .libraryFolders(id: view.id, name: view.name, isPlaylist: isPlaylist)
            )
        }

        let kind: BaseItemKind?
        let icon: String
        // `kind == nil` tells `MediaLibraryScreen` to skip the
        // `includeItemTypes` filter, so mixed/Other libraries still surface
        // every item they contain instead of returning empty because nothing
        // is typed as a movie.
        switch view.collectionType {
        case "movies":     kind = .movie;  icon = "film"
        case "tvshows":    kind = .series; icon = "tv.fill"
        case "homevideos": kind = nil;     icon = "video"
        default:           kind = nil;     icon = "rectangle.stack"
        }
        return .init(
            id: MenuEntry.libraryID(viewId: view.id),
            icon: icon,
            titleKey: nil,
            title: view.name,
            destination: .libraryView(id: view.id, name: view.name, kind: kind)
        )
    }

    // MARK: - Persistence helpers

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func persist<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func persist(_ value: String, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
