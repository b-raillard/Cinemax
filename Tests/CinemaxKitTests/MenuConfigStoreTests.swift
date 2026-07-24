import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// `MenuConfigStore` persists through `UserDefaults.standard` under the
/// `SettingsKey.menu*` keys, so the suite is `.serialized` and every test
/// starts by wiping those keys — no leakage between tests or store instances.
@MainActor
@Suite("MenuConfigStore", .serialized)
struct MenuConfigStoreTests {

    /// Removes every persisted menu key so each test starts from factory state.
    private func clearMenuDefaults() {
        let defaults = UserDefaults.standard
        for key in [
            SettingsKey.menuMode,
            SettingsKey.menuCustomKind,
            SettingsKey.menuContentTypeEntries,
            SettingsKey.menuLibraryEntries,
            SettingsKey.menuCachedViews
        ] {
            defaults.removeObject(forKey: key)
        }
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
        let store = MenuConfigStore()
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

        let result = store.toggle(MenuEntry.searchID)

        #expect(result == .refusedCapReached)
        #expect(store.libraryEntries == seeded)
        // A refused toggle must not persist anything either (direct seeding
        // above bypassed persistence, so the key must still be absent).
        #expect(UserDefaults.standard.data(forKey: SettingsKey.menuLibraryEntries) == nil)

        // Cap is count-based, not sticky: freeing a slot lets the 6th in.
        #expect(store.toggle(MenuEntry.libraryID(viewId: "a")) == .disabled)
        #expect(store.toggle(MenuEntry.searchID) == .enabled)
    }

    // MARK: - Mandatory entries

    @Test("toggling the mandatory Settings entry is a silent no-op")
    func mandatoryToggleNoChange() {
        clearMenuDefaults()
        let store = MenuConfigStore()
        let before = store.contentTypeEntries

        #expect(store.toggle(MenuEntry.settingsID) == .noChange)
        #expect(store.contentTypeEntries == before)
    }

    // MARK: - Persistence round-trips

    @Test("move() persists and round-trips through a fresh store instance")
    func moveRoundTrips() {
        clearMenuDefaults()
        let store = MenuConfigStore()
        // Defaults: [home, movies, series, search, settings].
        // Moving offset 0 to toOffset 3 lands "home" before the element
        // originally at index 3 → [movies, series, home, search, settings].
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        let expected = [
            MenuEntry.moviesID, MenuEntry.seriesID, MenuEntry.homeID,
            MenuEntry.searchID, MenuEntry.settingsID
        ]
        #expect(store.contentTypeEntries.map(\.id) == expected)

        let fresh = MenuConfigStore()
        #expect(fresh.contentTypeEntries.map(\.id) == expected)
    }

    @Test("toggle persists the enabled flag across store instances")
    func togglePersists() {
        clearMenuDefaults()
        let store = MenuConfigStore()

        #expect(store.toggle(MenuEntry.moviesID) == .disabled)

        let fresh = MenuConfigStore()
        #expect(fresh.contentTypeEntries.first { $0.id == MenuEntry.moviesID }?.enabled == false)
    }

    // MARK: - Library merge (via refreshAvailableViews — mergeLibraryEntries is private)

    @Test("refreshAvailableViews preserves order/flags, adds new views, drops removed ones")
    func refreshMergesLibraryEntries() async {
        clearMenuDefaults()
        let api = MockAPIClient()
        // Server now has B (already known) and C (new); A vanished.
        api.stubbedUserViews = [makeView(id: "B", name: "Films"), makeView(id: "C", name: "Docs")]

        let store = MenuConfigStore()
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
        let fresh = MenuConfigStore()
        #expect(fresh.libraryEntries.map(\.id) == expectedIDs)
        #expect(fresh.availableViews.map(\.id) == ["B", "C"])
    }

    // MARK: - Resolution

    @Test("resolvedTabs: default mode yields the canonical 5 tabs")
    func resolvedDefault() {
        clearMenuDefaults()
        let store = MenuConfigStore()

        #expect(store.resolvedTabs.map(\.id) == ["home", "movies", "tvShows", "search", "settings"])
    }

    @Test("resolvedTabs: custom content-type mode honors enabled flags; default mode ignores them")
    func resolvedCustomContentType() {
        clearMenuDefaults()
        let store = MenuConfigStore()
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
        let store = MenuConfigStore()
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
        let store = MenuConfigStore()
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
        let store = MenuConfigStore()
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
        let store = MenuConfigStore()
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

        let store = MenuConfigStore()
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
        let store = MenuConfigStore()
        store.setMode(.custom)
        #expect(store.toggle(MenuEntry.moviesID) == .disabled)
        #expect(!store.resolvedTabs.contains { $0.id == "movies" })

        store.reset()
        #expect(store.resolvedTabs.map(\.id) == ["home", "movies", "tvShows", "search", "settings"])
    }

    @Test("resolvedTabs: library mode maps views to tabs and skips ids without a cached view")
    func resolvedLibraryMode() {
        clearMenuDefaults()
        let store = MenuConfigStore()
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
    // The real-world trigger: `.custom + .library` mode whose cache was wiped
    // (server switch → `invalidateViews()`), then a fresh login that never
    // re-fetches the views. The store must therefore NEVER publish an empty
    // list — it falls back to the canonical default 5.

    @Test("resolvedTabs: library mode with an empty cache falls back to the default 5, never empty")
    func resolvedTabsNeverEmptyInLibraryMode() {
        clearMenuDefaults()
        // These two tests persist the custom+library+empty combo — the exact
        // state that used to black-screen the app. Leaving it behind makes the
        // NEXT test run's live test-host boot into it, so scrub on exit.
        defer { clearMenuDefaults() }
        let store = MenuConfigStore()
        store.setMode(.custom)
        // Force the pathological persisted state directly (entries emptied,
        // as `invalidateViews` leaves them), then recompute via a mutator.
        store.libraryEntries = []
        store.availableViews = []
        store.setCustomKind(.library)
        // `ensureLibraryEntriesPopulated` seeds builtins when empty — wipe
        // again through the public API to simulate the invalidated state.
        store.invalidateViews()

        #expect(!store.resolvedTabs.isEmpty)
        #expect(store.resolvedTabs.map(\.id) == ["home", "movies", "tvShows", "search", "settings"])
    }

    @Test("resolvedTabs: a fresh store restoring an invalidated library config still resolves tabs")
    func resolvedTabsNeverEmptyAfterRestore() {
        clearMenuDefaults()
        defer { clearMenuDefaults() }
        // Persist the exact on-disk state a server switch leaves behind:
        // custom+library mode with both arrays empty.
        let seed = MenuConfigStore()
        seed.setMode(.custom)
        seed.setCustomKind(.library)
        seed.invalidateViews()

        let fresh = MenuConfigStore()
        #expect(!fresh.resolvedTabs.isEmpty)
        #expect(fresh.resolvedTabs.map(\.id) == ["home", "movies", "tvShows", "search", "settings"])
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
