import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// `MenuConfigStore` persists through `UserDefaults.standard` under the
/// `SettingsKey.menu*` keys, so the suite is `.serialized` and every test
/// starts by wiping those keys — no leakage between tests or store instances.
///
/// Menu state is per-server: nothing persists until a profile is activated, so
/// every test goes through `makeStore()` (which activates a single test server)
/// or activates explicitly when it needs more than one.
@MainActor
@Suite("MenuConfigStore", .serialized)
struct MenuConfigStoreTests {

    /// Default server id used by `makeStore()`.
    private static let testServer = "server-1"

    /// Removes every persisted menu key so each test starts from factory state.
    private func clearMenuDefaults() {
        let defaults = UserDefaults.standard
        for key in [
            SettingsKey.menuProfiles,
            SettingsKey.menuMode,
            SettingsKey.menuCustomKind,
            SettingsKey.menuContentTypeEntries,
            SettingsKey.menuLibraryEntries,
            SettingsKey.menuCachedViews
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    /// A store with one server's profile activated — the shape every screen
    /// sees at runtime (`AppNavigation` activates before the tab bar renders).
    private func makeStore(_ serverId: String = MenuConfigStoreTests.testServer) -> MenuConfigStore {
        let created = MenuConfigStore()
        created.activate(serverId: serverId, knownServerIds: [serverId])
        return created
    }

    /// The profile dictionary as it sits on disk.
    private func persistedProfiles() -> [String: MenuProfile] {
        guard let data = UserDefaults.standard.data(forKey: SettingsKey.menuProfiles),
              let decoded = try? JSONDecoder().decode([String: MenuProfile].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Writes a profile dictionary straight to disk, simulating what a previous
    /// launch left behind.
    private func seedProfiles(_ profiles: [String: MenuProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: SettingsKey.menuProfiles)
    }

    private func makeView(id: String, name: String) -> BaseItemDto {
        var dto = BaseItemDto()
        dto.id = id
        dto.name = name
        // collectionType left nil — treated as video-bearing ("Mixed"/"Other").
        return dto
    }

    // MARK: - Cap

    @Test("enabling a 6th tab returns .refusedCapReached and mutates nothing")
    func sixthTabRefused() {
        clearMenuDefaults()
        let store = makeStore()
        let seeded: [MenuEntry] = [
            .init(id: MenuEntry.homeID, enabled: true),
            .init(id: MenuEntry.libraryID(viewId: "a"), enabled: true),
            .init(id: MenuEntry.libraryID(viewId: "b"), enabled: true),
            .init(id: MenuEntry.libraryID(viewId: "c"), enabled: true),
            .init(id: MenuEntry.settingsID, enabled: true),
            .init(id: MenuEntry.searchID, enabled: false)
        ]
        store.libraryEntries = seeded
        store.setCustomKind(.library) // entries non-empty → not repopulated
        let persistedBefore = persistedProfiles()

        let result = store.toggle(MenuEntry.searchID)

        #expect(result == .refusedCapReached)
        #expect(store.libraryEntries == seeded)
        // A refused toggle must not persist anything either — the stored
        // profile is byte-for-byte what `setCustomKind` left behind.
        #expect(persistedProfiles() == persistedBefore)

        // Cap is count-based, not sticky: freeing a slot lets the 6th in.
        #expect(store.toggle(MenuEntry.libraryID(viewId: "a")) == .disabled)
        #expect(store.toggle(MenuEntry.searchID) == .enabled)
    }

    // MARK: - Mandatory entries

    @Test("toggling the mandatory Settings entry is a silent no-op")
    func mandatoryToggleNoChange() {
        clearMenuDefaults()
        let store = makeStore()
        let before = store.contentTypeEntries

        #expect(store.toggle(MenuEntry.settingsID) == .noChange)
        #expect(store.contentTypeEntries == before)
    }

    // MARK: - Persistence round-trips

    @Test("move() persists and round-trips through a fresh store instance")
    func moveRoundTrips() {
        clearMenuDefaults()
        let store = makeStore()
        // Defaults: [home, movies, series, search, settings].
        // Moving offset 0 to toOffset 3 lands "home" before the element
        // originally at index 3 → [movies, series, home, search, settings].
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        let expected = [
            MenuEntry.moviesID, MenuEntry.seriesID, MenuEntry.homeID,
            MenuEntry.searchID, MenuEntry.settingsID
        ]
        #expect(store.contentTypeEntries.map(\.id) == expected)

        let fresh = makeStore()
        #expect(fresh.contentTypeEntries.map(\.id) == expected)
    }

    @Test("toggle persists the enabled flag across store instances")
    func togglePersists() {
        clearMenuDefaults()
        let store = makeStore()

        #expect(store.toggle(MenuEntry.moviesID) == .disabled)

        let fresh = makeStore()
        #expect(fresh.contentTypeEntries.first { $0.id == MenuEntry.moviesID }?.enabled == false)
    }

    // MARK: - Library merge (via refreshAvailableViews — mergeLibraryEntries is private)

    @Test("refreshAvailableViews preserves order/flags, adds new views, drops removed ones")
    func refreshMergesLibraryEntries() async {
        clearMenuDefaults()
        let api = MockAPIClient()
        // Server now has B (already known) and C (new); A vanished.
        api.stubbedUserViews = [makeView(id: "B", name: "Films"), makeView(id: "C", name: "Docs")]

        let store = makeStore()
        store.attach(apiClient: api, userId: "user1")
        store.libraryEntries = [
            .init(id: MenuEntry.homeID, enabled: true),
            .init(id: MenuEntry.libraryID(viewId: "A"), enabled: true),  // removed on server
            .init(id: MenuEntry.libraryID(viewId: "B"), enabled: false), // user disabled it
            .init(id: MenuEntry.searchID, enabled: true),
            .init(id: MenuEntry.settingsID, enabled: true)
        ]
        store.setCustomKind(.library)

        await store.refreshAvailableViews()

        #expect(store.lastFetchError == nil)
        #expect(store.availableViews.map(\.id) == ["B", "C"])

        let expectedIDs = [
            MenuEntry.homeID,
            MenuEntry.libraryID(viewId: "B"),
            MenuEntry.searchID,
            MenuEntry.libraryID(viewId: "C"), // new views insert before settings
            MenuEntry.settingsID
        ]
        #expect(store.libraryEntries.map(\.id) == expectedIDs)
        // User's disabled flag on B survives the merge.
        #expect(store.libraryEntries.first { $0.id == MenuEntry.libraryID(viewId: "B") }?.enabled == false)
        // New view C defaults to enabled because slots remain under the cap.
        #expect(store.libraryEntries.first { $0.id == MenuEntry.libraryID(viewId: "C") }?.enabled == true)

        // Merge result + view cache both round-trip through persistence.
        let fresh = makeStore()
        #expect(fresh.libraryEntries.map(\.id) == expectedIDs)
        #expect(fresh.availableViews.map(\.id) == ["B", "C"])
    }

    // MARK: - Resolution

    @Test("resolvedTabs: default mode yields the canonical 5 tabs")
    func resolvedDefault() {
        clearMenuDefaults()
        let store = makeStore()

        #expect(store.resolvedTabs.map(\.id) == ["home", "movies", "tvShows", "search", "settings"])
    }

    @Test("resolvedTabs: custom content-type mode honors enabled flags; default mode ignores them")
    func resolvedCustomContentType() {
        clearMenuDefaults()
        let store = makeStore()
        store.setMode(.custom)

        #expect(store.toggle(MenuEntry.moviesID) == .disabled)
        #expect(store.resolvedTabs.map(\.id) == ["home", "tvShows", "search", "settings"])

        // Back to default → canonical 5 regardless of custom entry state.
        store.setMode(.default)
        #expect(store.resolvedTabs.map(\.id) == ["home", "movies", "tvShows", "search", "settings"])
    }

    // MARK: - Resolution memoization (recompute-in-mutators)

    // `resolvedTabs` is a memoized stored cache recomputed at the end of every
    // mutator that changes an input (mode / customKind / entry arrays /
    // availableViews). These tests lock in that every mutation category keeps
    // the cache in sync — a missed `recomputeResolvedTabs()` call in any
    // mutator would surface here as a stale bar.

    @Test("resolvedTabs: setMode flips the cached array between default and custom")
    func resolvedTabsReflectsModeFlip() {
        clearMenuDefaults()
        let store = makeStore()
        #expect(store.resolvedTabs.map(\.id) == ["home", "movies", "tvShows", "search", "settings"])

        // Disable movies in the custom entries while still in default mode —
        // default mode ignores custom entries, so the cache must not change yet.
        #expect(store.toggle(MenuEntry.moviesID) == .disabled)
        #expect(store.resolvedTabs.contains { $0.id == "movies" })

        // Flipping to custom now surfaces the disabled state.
        store.setMode(.custom)
        #expect(!store.resolvedTabs.contains { $0.id == "movies" })

        // Back to default → canonical 5 regardless of custom entry state.
        store.setMode(.default)
        #expect(store.resolvedTabs.map(\.id) == ["home", "movies", "tvShows", "search", "settings"])
    }

    @Test("resolvedTabs: setCustomKind switches the cached set between content-type and library")
    func resolvedTabsReflectsKindFlip() {
        clearMenuDefaults()
        let store = makeStore()
        store.setMode(.custom)
        #expect(store.resolvedTabs.map(\.id) == ["home", "movies", "tvShows", "search", "settings"])

        // Seed a library view + entries, then flip the kind — setCustomKind
        // recomputes the cache off the freshly-seeded state.
        store.availableViews = [LibraryView(id: "v1", name: "Ciné", collectionType: "movies")]
        store.libraryEntries = [
            .init(id: MenuEntry.homeID, enabled: true),
            .init(id: MenuEntry.libraryID(viewId: "v1"), enabled: true),
            .init(id: MenuEntry.settingsID, enabled: true)
        ]
        store.setCustomKind(.library)
        #expect(store.resolvedTabs.map(\.id) == ["home", MenuEntry.libraryID(viewId: "v1"), "settings"])

        // Flip back to content-type → built-in tabs again.
        store.setCustomKind(.contentType)
        #expect(store.resolvedTabs.map(\.id) == ["home", "movies", "tvShows", "search", "settings"])
    }

    @Test("resolvedTabs: toggling a content-type entry updates the cache immediately")
    func resolvedTabsReflectsEntryToggle() {
        clearMenuDefaults()
        let store = makeStore()
        store.setMode(.custom)
        #expect(store.resolvedTabs.map(\.id) == ["home", "movies", "tvShows", "search", "settings"])

        #expect(store.toggle(MenuEntry.seriesID) == .disabled)
        #expect(store.resolvedTabs.map(\.id) == ["home", "movies", "search", "settings"])

        #expect(store.toggle(MenuEntry.seriesID) == .enabled)
        #expect(store.resolvedTabs.map(\.id) == ["home", "movies", "tvShows", "search", "settings"])
    }

    @Test("resolvedTabs: reordering entries (move + moveBy) reorders the cache")
    func resolvedTabsReflectsReorder() {
        clearMenuDefaults()
        let store = makeStore()
        store.setMode(.custom)

        // move offset 0 → 3: [movies, series, home, search, settings]
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(store.resolvedTabs.map(\.id) == ["movies", "tvShows", "home", "search", "settings"])

        // moveBy swaps neighbors: home (index 2) up one → [movies, home, series, …]
        store.moveBy(MenuEntry.homeID, delta: -1)
        #expect(store.resolvedTabs.map(\.id) == ["movies", "home", "tvShows", "search", "settings"])
    }

    @Test("resolvedTabs: refreshAvailableViews surfaces new library tabs and is idempotent for unchanged views")
    func resolvedTabsReflectsRefreshAndIsIdempotent() async {
        clearMenuDefaults()
        let api = MockAPIClient()
        api.stubbedUserViews = [makeView(id: "B", name: "Films")]

        let store = makeStore()
        store.attach(apiClient: api, userId: "user1")
        store.setMode(.custom)
        store.setCustomKind(.library)

        await store.refreshAvailableViews()
        #expect(store.resolvedTabs.contains { $0.id == MenuEntry.libraryID(viewId: "B") })

        // Idempotent: a repeat refresh with the SAME views leaves the cache
        // byte-identical (mirrors the existing availableViews/libraryEntries
        // equality guards — no spurious re-resolution).
        let snapshot = store.resolvedTabs
        await store.refreshAvailableViews()
        #expect(store.resolvedTabs == snapshot)

        // A changed view set updates the cache.
        api.stubbedUserViews = [makeView(id: "B", name: "Films"), makeView(id: "C", name: "Docs")]
        await store.refreshAvailableViews()
        #expect(store.resolvedTabs != snapshot)
        #expect(store.resolvedTabs.contains { $0.id == MenuEntry.libraryID(viewId: "C") })
    }

    @Test("resolvedTabs: reset restores the canonical 5 tabs")
    func resolvedTabsReflectsReset() {
        clearMenuDefaults()
        let store = makeStore()
        store.setMode(.custom)
        #expect(store.toggle(MenuEntry.moviesID) == .disabled)
        #expect(!store.resolvedTabs.contains { $0.id == "movies" })

        store.reset()
        #expect(store.resolvedTabs.map(\.id) == ["home", "movies", "tvShows", "search", "settings"])
    }

    @Test("resolvedTabs: library mode maps views to tabs and skips ids without a cached view")
    func resolvedLibraryMode() {
        clearMenuDefaults()
        let store = makeStore()
        store.availableViews = [LibraryView(id: "v1", name: "Ciné", collectionType: "movies")]
        store.libraryEntries = [
            .init(id: MenuEntry.homeID, enabled: true),
            .init(id: MenuEntry.libraryID(viewId: "v1"), enabled: true),
            .init(id: MenuEntry.libraryID(viewId: "ghost"), enabled: true), // no matching view
            .init(id: MenuEntry.settingsID, enabled: true)
        ]
        store.setMode(.custom)
        store.setCustomKind(.library)

        let tabs = store.resolvedTabs
        #expect(tabs.map(\.id) == ["home", MenuEntry.libraryID(viewId: "v1"), "settings"])

        let libTab = tabs.first { $0.id == MenuEntry.libraryID(viewId: "v1") }
        #expect(libTab?.title == "Ciné")
        #expect(libTab?.titleKey == nil)
        #expect(libTab?.destination == .libraryView(id: "v1", name: "Ciné", kind: .movie))
    }

    // MARK: - Empty-resolution fallback (post-login black screen)

    // `MainTabView` renders whatever `resolvedTabs` holds; an empty array means
    // a `TabView` with zero tabs — a fully black screen with no recovery path.
    // The real-world trigger: switching to a server whose profile is
    // `.custom + .library` but whose views have never been fetched (fresh
    // login, offline launch). The store must therefore NEVER publish an empty
    // list — it falls back to the canonical default 5.

    /// custom + library with nothing cached — a profile whose server hasn't
    /// answered `getUserViews` yet. Resolution comes up empty and MUST fall
    /// back rather than publish zero tabs.
    private var emptyLibraryProfile: MenuProfile {
        MenuProfile(
            mode: .custom,
            customKind: .library,
            contentTypeEntries: MenuConfigStore.defaultContentTypeEntries,
            libraryEntries: [],
            availableViews: []
        )
    }

    @Test("resolvedTabs: switching INTO an empty library profile falls back to the default 5, never empty")
    func resolvedTabsNeverEmptyInLibraryMode() {
        clearMenuDefaults()
        // These two tests persist the custom+library+empty combo — the exact
        // state that used to black-screen the app. Leaving it behind makes the
        // NEXT test run's live test-host boot into it, so scrub on exit.
        defer { clearMenuDefaults() }
        seedProfiles(["B": emptyLibraryProfile])
        let store = makeStore("A")
        store.activate(serverId: "B", knownServerIds: ["A", "B"])

        #expect(!store.resolvedTabs.isEmpty)
        #expect(store.resolvedTabs.map(\.id) == ["home", "movies", "tvShows", "search", "settings"])
    }

    @Test("resolvedTabs: a fresh store restoring an empty library profile still resolves tabs")
    func resolvedTabsNeverEmptyAfterRestore() {
        clearMenuDefaults()
        defer { clearMenuDefaults() }
        seedProfiles([MenuConfigStoreTests.testServer: emptyLibraryProfile])

        let fresh = makeStore()
        #expect(!fresh.resolvedTabs.isEmpty)
        #expect(fresh.resolvedTabs.map(\.id) == ["home", "movies", "tvShows", "search", "settings"])
    }

    // MARK: - Per-server profiles

    // Menu state is stored per registered server (`ServerEntry.id`). Switching
    // servers swaps the whole profile in; it must never bleed one server's
    // arrangement onto another, and must never destroy the one being left.

    @Test("each server keeps its own mode, order and enabled flags, across switches and launches")
    func contentTypeProfilesAreIsolatedPerServer() {
        clearMenuDefaults()
        defer { clearMenuDefaults() }
        let known: Set<String> = ["A", "B"]

        let store = MenuConfigStore()
        store.activate(serverId: "A", knownServerIds: known)
        store.setMode(.custom)
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(store.toggle(MenuEntry.moviesID) == .disabled)
        let orderA = store.contentTypeEntries
        #expect(orderA.map(\.id) == [
            MenuEntry.moviesID, MenuEntry.seriesID, MenuEntry.homeID,
            MenuEntry.searchID, MenuEntry.settingsID
        ])

        // B has never been configured → factory defaults, not A's menu.
        store.activate(serverId: "B", knownServerIds: known)
        #expect(store.mode == .default)
        #expect(store.contentTypeEntries == MenuConfigStore.defaultContentTypeEntries)

        // Back to A → exactly what the user left there.
        store.activate(serverId: "A", knownServerIds: known)
        #expect(store.mode == .custom)
        #expect(store.contentTypeEntries == orderA)

        // …and it survives a relaunch.
        let fresh = MenuConfigStore()
        fresh.activate(serverId: "A", knownServerIds: known)
        #expect(fresh.mode == .custom)
        #expect(fresh.contentTypeEntries == orderA)
        fresh.activate(serverId: "B", knownServerIds: known)
        #expect(fresh.mode == .default)
    }

    @Test("switching servers preserves each server's library arrangement")
    func libraryArrangementSurvivesServerSwitch() async {
        clearMenuDefaults()
        defer { clearMenuDefaults() }
        let api = MockAPIClient()
        let known: Set<String> = ["A", "B"]
        let a1 = MenuEntry.libraryID(viewId: "a1")
        let a2 = MenuEntry.libraryID(viewId: "a2")

        // Server A: two libraries; the user reorders them and drops Search.
        api.stubbedUserViews = [makeView(id: "a1", name: "Films A"), makeView(id: "a2", name: "Séries A")]
        let store = MenuConfigStore()
        store.activate(serverId: "A", knownServerIds: known)
        store.attach(apiClient: api, userId: "user")
        store.setMode(.custom)
        store.setCustomKind(.library)
        await store.refreshAvailableViews()
        store.moveBy(a2, delta: -1)
        #expect(store.toggle(MenuEntry.searchID) == .disabled)

        let arrangementA = store.libraryEntries
        #expect(arrangementA.map(\.id) == [MenuEntry.homeID, MenuEntry.searchID, a2, a1, MenuEntry.settingsID])
        #expect(arrangementA.first { $0.id == MenuEntry.searchID }?.enabled == false)

        // Server B: its own libraries, none of A's.
        api.stubbedUserViews = [makeView(id: "b1", name: "Films B")]
        store.activate(serverId: "B", knownServerIds: known)
        store.setMode(.custom)
        store.setCustomKind(.library)
        await store.refreshAvailableViews()
        #expect(store.availableViews.map(\.id) == ["b1"])
        #expect(!store.libraryEntries.contains { $0.id == a1 || $0.id == a2 })

        // Back to A — the whole arrangement is intact, cached views included.
        api.stubbedUserViews = [makeView(id: "a1", name: "Films A"), makeView(id: "a2", name: "Séries A")]
        store.activate(serverId: "A", knownServerIds: known)
        #expect(store.availableViews.map(\.id) == ["a1", "a2"])
        #expect(store.libraryEntries == arrangementA)
        #expect(store.resolvedTabs.map(\.id) == [MenuEntry.homeID, a2, a1, MenuEntry.settingsID])
    }

    @Test("the first activated server inherits the legacy global menu keys, and only it")
    func legacyKeysSeedTheFirstProfileOnly() {
        clearMenuDefaults()
        defer { clearMenuDefaults() }
        // Exactly what a pre-update install left behind.
        let legacyEntries: [MenuEntry] = [
            .init(id: MenuEntry.homeID, enabled: true),
            .init(id: MenuEntry.libraryID(viewId: "v1"), enabled: true),
            .init(id: MenuEntry.settingsID, enabled: true)
        ]
        let legacyViews = [LibraryView(id: "v1", name: "Ciné", collectionType: "movies")]
        let defaults = UserDefaults.standard
        defaults.set("custom", forKey: SettingsKey.menuMode)
        defaults.set("library", forKey: SettingsKey.menuCustomKind)
        if let data = try? JSONEncoder().encode(legacyEntries) {
            defaults.set(data, forKey: SettingsKey.menuLibraryEntries)
        }
        if let data = try? JSONEncoder().encode(legacyViews) {
            defaults.set(data, forKey: SettingsKey.menuCachedViews)
        }

        let store = MenuConfigStore()
        store.activate(serverId: "A", knownServerIds: ["A", "B"])
        #expect(store.mode == .custom)
        #expect(store.customKind == .library)
        #expect(store.libraryEntries == legacyEntries)
        #expect(store.availableViews == legacyViews)
        #expect(store.resolvedTabs.map(\.id) == [
            MenuEntry.homeID, MenuEntry.libraryID(viewId: "v1"), MenuEntry.settingsID
        ])
        // The seed is written, so it survives without the legacy keys.
        #expect(persistedProfiles()["A"]?.libraryEntries == legacyEntries)

        // One-shot: a second server starts clean instead of re-consuming them.
        store.activate(serverId: "B", knownServerIds: ["A", "B"])
        #expect(store.mode == .default)
        #expect(store.libraryEntries.isEmpty)
    }

    // MARK: - No active profile (registry unavailable)

    /// `activeProfileId` stays nil whenever the registry can't say which server
    /// we are on: `migrateToMultiServerIfNeeded` returns early when its Keychain
    /// write throws, so `getActiveServerId()` is nil while the legacy mirror
    /// still restores a session. The user is signed in and the menu editor is
    /// reachable, but per-server profiles have nothing to key on. The store must
    /// then degrade to EXACTLY its pre-profiles behaviour — read *and* write the
    /// legacy global keys — so a menu is never shown wrong nor silently lost.

    @Test("with no active profile, the store shows the legacy global menu, not factory defaults")
    func noActiveProfileReadsLegacyKeys() {
        clearMenuDefaults()
        defer { clearMenuDefaults() }
        let legacyEntries: [MenuEntry] = [
            .init(id: MenuEntry.homeID, enabled: true),
            .init(id: MenuEntry.libraryID(viewId: "v1"), enabled: true),
            .init(id: MenuEntry.settingsID, enabled: true)
        ]
        let defaults = UserDefaults.standard
        defaults.set("custom", forKey: SettingsKey.menuMode)
        defaults.set("library", forKey: SettingsKey.menuCustomKind)
        if let data = try? JSONEncoder().encode(legacyEntries) {
            defaults.set(data, forKey: SettingsKey.menuLibraryEntries)
        }

        // No `activate(...)`: the registry never resolved an active server.
        let store = MenuConfigStore()

        #expect(store.activeProfileId == nil)
        #expect(store.mode == .custom, "the user's own menu must show, not the factory default")
        #expect(store.customKind == .library)
        #expect(store.libraryEntries == legacyEntries)
    }

    @Test("with no active profile, an edit survives a relaunch and is adopted on the next activation")
    func noActiveProfileWritesLegacyKeys() {
        clearMenuDefaults()
        defer { clearMenuDefaults() }

        let store = MenuConfigStore()
        #expect(store.activeProfileId == nil)
        store.setMode(.custom)
        #expect(store.toggle(MenuEntry.moviesID) == .disabled)

        // Relaunch, registry still unavailable: the edit must still be there.
        let relaunched = MenuConfigStore()
        #expect(relaunched.mode == .custom, "a menu edit must never be silently lost")
        #expect(relaunched.contentTypeEntries.first { $0.id == MenuEntry.moviesID }?.enabled == false)

        // Registry recovers: the first activated server adopts the edit.
        relaunched.activate(serverId: "A", knownServerIds: ["A"])
        #expect(relaunched.mode == .custom)
        #expect(persistedProfiles()["A"]?.contentTypeEntries
            .first { $0.id == MenuEntry.moviesID }?.enabled == false)
    }

    @Test("activate drops the profiles of servers that are no longer registered")
    func pruneRemovesOrphanProfiles() {
        clearMenuDefaults()
        defer { clearMenuDefaults() }
        seedProfiles(["A": MenuProfile.factoryDefault, "gone": emptyLibraryProfile])

        let store = MenuConfigStore()
        store.activate(serverId: "A", knownServerIds: ["A"])

        #expect(persistedProfiles().keys.sorted() == ["A"])
        #expect(store.activeProfileId == "A")
    }

    @Test("activate prunes nothing when the registry snapshot is empty")
    func pruneSkippedWithEmptyRegistry() {
        clearMenuDefaults()
        defer { clearMenuDefaults() }
        seedProfiles(["A": MenuProfile.factoryDefault, "B": emptyLibraryProfile])

        let store = MenuConfigStore()
        store.activate(serverId: "A", knownServerIds: [])

        #expect(persistedProfiles().keys.sorted() == ["A", "B"])
        #expect(store.activeProfileId == "A")
    }

    @Test("activate(nil) keeps the loaded profile, prunes nothing, and re-activating is a no-op")
    func activateNoOps() {
        clearMenuDefaults()
        defer { clearMenuDefaults() }
        seedProfiles(["B": emptyLibraryProfile])

        let store = MenuConfigStore()
        store.activate(serverId: "A", knownServerIds: ["A", "B"])
        store.setMode(.custom)
        #expect(store.toggle(MenuEntry.moviesID) == .disabled)
        let entries = store.contentTypeEntries
        let tabs = store.resolvedTabs

        // Logout: no active server. The menu must not blank out, and B's
        // profile must not be collected just because it isn't the target.
        store.activate(serverId: nil, knownServerIds: ["A"])
        #expect(store.activeProfileId == "A")
        #expect(store.contentTypeEntries == entries)
        #expect(store.resolvedTabs == tabs)
        #expect(persistedProfiles()["B"] != nil)

        // Re-activating the same server (cold launch fires `.task` AND the
        // observer) changes nothing.
        store.activate(serverId: "A", knownServerIds: ["A", "B"])
        #expect(store.contentTypeEntries == entries)
        #expect(store.resolvedTabs == tabs)
    }

    // MARK: - LibraryView filtering

    @Test("LibraryView.isVideoLibrary excludes non-video collection types, keeps nil/mixed")
    func isVideoLibrary() {
        #expect(LibraryView(id: "1", name: "Films", collectionType: "movies").isVideoLibrary)
        #expect(LibraryView(id: "2", name: "Mixed", collectionType: nil).isVideoLibrary)
        #expect(!LibraryView(id: "3", name: "Musique", collectionType: "music").isVideoLibrary)
        #expect(!LibraryView(id: "5", name: "Photos", collectionType: "photos").isVideoLibrary)
        // Collections (boxsets) and playlists carry video content and ARE
        // surfaced — they route to the folder-browse screen, not the flat grid.
        #expect(LibraryView(id: "4", name: "Coffrets", collectionType: "boxsets").isVideoLibrary)
        #expect(LibraryView(id: "6", name: "Listes", collectionType: "playlists").isVideoLibrary)
    }
}

// MARK: - Settings categories

/// Verrouille la structure du landing Réglages après la réorganisation
/// (Lecture promue au 1er niveau) : l'ordre de déclaration = l'ordre
/// d'affichage, et `.playback` doit rester visible sur les deux plateformes
/// pour tout utilisateur — ni admin-gated, ni platform-gated.
@Suite("SettingsCategory")
struct SettingsCategoryTests {
    @Test("le landing non-admin résout les 5 catégories canoniques, dans l'ordre, sur les deux plateformes")
    @MainActor func nonAdminOrder() {
        let expected: [SettingsCategory] = [.appearance, .interface, .playback, .account, .server]
        #expect(SettingsCategory.visibleCases(isAdmin: false, isTVOS: false) == expected)
        #expect(SettingsCategory.visibleCases(isAdmin: false, isTVOS: true) == expected)
    }

    @Test("l'admin iOS ajoute les deux catégories admin ; tvOS ne les montre jamais")
    @MainActor func adminGating() {
        #expect(SettingsCategory.visibleCases(isAdmin: true, isTVOS: false)
                == [.appearance, .interface, .playback, .account, .server, .administration, .advancedAdmin])
        #expect(SettingsCategory.visibleCases(isAdmin: true, isTVOS: true)
                == [.appearance, .interface, .playback, .account, .server])
    }

    @Test("le hub Interface expose exactement les quatre sous-pages écran, dans l'ordre")
    func interfaceSubPages() {
        #expect(InterfaceSubcategory.allCases == [.menu, .homePage, .library, .detailPage])
    }
}
