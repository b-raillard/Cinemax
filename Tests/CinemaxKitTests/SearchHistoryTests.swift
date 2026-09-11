import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// A throwaway defaults suite per test, so nothing here touches the test
/// host's real `UserDefaults.standard`.
private func makeDefaults() -> UserDefaults {
    let name = "SearchHistoryTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: - Store

@Suite("SearchHistoryStore")
struct SearchHistoryStoreTests {

    @Test("Each server has its own key; no server means the legacy global key")
    func keying() {
        #expect(SearchHistoryStore.key(forServer: nil) == "search.recentQueries")
        #expect(SearchHistoryStore.key(forServer: "") == "search.recentQueries")
        #expect(SearchHistoryStore.key(forServer: "A") == "search.recentQueries.A")
        #expect(SearchHistoryStore.key(forServer: "A") != SearchHistoryStore.key(forServer: "B"))
    }

    @Test("Lists are isolated per server")
    func isolation() {
        let defaults = makeDefaults()
        SearchHistoryStore.save(["dune"], serverId: "A", defaults: defaults)
        SearchHistoryStore.save(["arrival"], serverId: "B", defaults: defaults)

        #expect(SearchHistoryStore.load(serverId: "A", defaults: defaults) == ["dune"])
        #expect(SearchHistoryStore.load(serverId: "B", defaults: defaults) == ["arrival"])

        SearchHistoryStore.clear(serverId: "A", defaults: defaults)
        #expect(SearchHistoryStore.load(serverId: "A", defaults: defaults).isEmpty)
        #expect(SearchHistoryStore.load(serverId: "B", defaults: defaults) == ["arrival"])
    }

    @Test("The legacy list migrates into the FIRST server only, and survives")
    func migratesOnceIntoFirstServer() {
        let defaults = makeDefaults()
        SearchHistoryStore.save(["dune", "alien"], serverId: nil, defaults: defaults)

        #expect(SearchHistoryStore.migrateLegacyIfNeeded(into: "A", defaults: defaults))
        #expect(!SearchHistoryStore.migrateLegacyIfNeeded(into: "B", defaults: defaults))
        #expect(!SearchHistoryStore.migrateLegacyIfNeeded(into: "A", defaults: defaults))   // idempotent

        #expect(SearchHistoryStore.load(serverId: "A", defaults: defaults) == ["dune", "alien"])
        #expect(SearchHistoryStore.load(serverId: "B", defaults: defaults).isEmpty)
        // Non-destructive: the legacy list is still there.
        #expect(SearchHistoryStore.load(serverId: nil, defaults: defaults) == ["dune", "alien"])
    }

    /// The reason the migration keys on a marker rather than on "no
    /// per-server list exists": clearing the inheriting server's list makes
    /// that condition true again, and an emptiness-keyed migration would then
    /// hand the old global history to another server.
    @Test("A cleared inheritor never lets the legacy list reach another server")
    func clearedInheritorDoesNotReimport() {
        let defaults = makeDefaults()
        SearchHistoryStore.save(["dune"], serverId: nil, defaults: defaults)
        SearchHistoryStore.migrateLegacyIfNeeded(into: "A", defaults: defaults)
        SearchHistoryStore.clear(serverId: "A", defaults: defaults)

        #expect(!SearchHistoryStore.migrateLegacyIfNeeded(into: "B", defaults: defaults))
        #expect(SearchHistoryStore.load(serverId: "B", defaults: defaults).isEmpty)
        #expect(SearchHistoryStore.load(serverId: "A", defaults: defaults).isEmpty)
    }

    @Test("Migration never overwrites a list the server already has")
    func migrationKeepsExistingList() {
        let defaults = makeDefaults()
        SearchHistoryStore.save(["legacy"], serverId: nil, defaults: defaults)
        SearchHistoryStore.save(["mine"], serverId: "A", defaults: defaults)

        #expect(!SearchHistoryStore.migrateLegacyIfNeeded(into: "A", defaults: defaults))
        #expect(SearchHistoryStore.load(serverId: "A", defaults: defaults) == ["mine"])
    }

    @Test("No server id: no migration, and the marker stays unset for the real first server")
    func noServerNoMigration() {
        let defaults = makeDefaults()
        SearchHistoryStore.save(["dune"], serverId: nil, defaults: defaults)

        #expect(!SearchHistoryStore.migrateLegacyIfNeeded(into: nil, defaults: defaults))
        #expect(defaults.object(forKey: SettingsKey.searchRecentQueriesMigratedTo) == nil)
        #expect(SearchHistoryStore.migrateLegacyIfNeeded(into: "A", defaults: defaults))
    }

    @Test("clearAll wipes the legacy list and every server's, and nothing else")
    func clearAllWipesEveryServer() {
        let defaults = makeDefaults()
        SearchHistoryStore.save(["legacy"], serverId: nil, defaults: defaults)
        SearchHistoryStore.save(["a"], serverId: "A", defaults: defaults)
        SearchHistoryStore.save(["b"], serverId: "B", defaults: defaults)
        defaults.set(true, forKey: SettingsKey.searchSaveHistory)

        SearchHistoryStore.clearAll(defaults: defaults)

        #expect(defaults.object(forKey: SettingsKey.searchRecentQueries) == nil)
        #expect(defaults.object(forKey: SettingsKey.searchRecentQueries(serverId: "A")) == nil)
        #expect(defaults.object(forKey: SettingsKey.searchRecentQueries(serverId: "B")) == nil)
        #expect(defaults.object(forKey: SettingsKey.searchSaveHistory) as? Bool == true)
    }

    @Test("Recording moves to the front, de-duplicates case-insensitively, caps the list")
    func recording() {
        #expect(SearchHistoryStore.recording("Dune", into: ["alien", "dune"]) == ["Dune", "alien"])
        let full = (1...SearchHistoryStore.maxEntries).map { "q\($0)" }
        let updated = SearchHistoryStore.recording("new", into: full)
        #expect(updated.count == SearchHistoryStore.maxEntries)
        #expect(updated.first == "new")
        #expect(!updated.contains("q\(SearchHistoryStore.maxEntries)"))
    }
}

// MARK: - View model

@MainActor
@Suite("SearchViewModel per-server history")
struct SearchViewModelHistoryTests {

    private func makeAppState(api: MockAPIClient, activeServerId: String) -> AppState {
        let keychain = MockKeychain()
        keychain.savedServers = [
            ServerEntry(id: activeServerId, name: "NAS", url: URL(string: "https://a.local")!,
                        accessToken: "tok", userId: "user1")
        ]
        keychain.savedActiveServerId = activeServerId
        let appState = AppState(apiClient: api, keychain: keychain)
        appState.loadServersFromKeychain()
        appState.currentUserId = "user1"
        return appState
    }

    private func makeItem(id: String, name: String) -> BaseItemDto {
        var item = BaseItemDto()
        item.id = id
        item.name = name
        return item
    }

    @Test("A query is filed under the active server, and a switch swaps the list")
    func recordsUnderActiveServer() async {
        let defaults = makeDefaults()
        let api = MockAPIClient()
        api.stubbedSearchResults = [makeItem(id: "1", name: "Dune")]
        let appState = makeAppState(api: api, activeServerId: "A")
        let vm = SearchViewModel(defaults: defaults)
        vm.loadHistory(forServer: "A")

        vm.searchText = "Dune"
        vm.search(using: appState)
        try? await Task.sleep(for: .milliseconds(700))

        #expect(vm.recentSearches == ["Dune"])
        #expect(SearchHistoryStore.load(serverId: "A", defaults: defaults) == ["Dune"])
        #expect(defaults.object(forKey: SettingsKey.searchRecentQueries) == nil)   // not the global key

        vm.loadHistory(forServer: "B")
        #expect(vm.recentSearches.isEmpty)
        vm.loadHistory(forServer: "A")
        #expect(vm.recentSearches == ["Dune"])
    }

    @Test("Clearing forgets only the server on screen")
    func clearIsPerServer() {
        let defaults = makeDefaults()
        SearchHistoryStore.save(["dune"], serverId: "A", defaults: defaults)
        SearchHistoryStore.save(["arrival"], serverId: "B", defaults: defaults)
        let vm = SearchViewModel(defaults: defaults)
        vm.loadHistory(forServer: "A")

        vm.clearRecentSearches()

        #expect(vm.recentSearches.isEmpty)
        #expect(SearchHistoryStore.load(serverId: "A", defaults: defaults).isEmpty)
        #expect(SearchHistoryStore.load(serverId: "B", defaults: defaults) == ["arrival"])
    }

    @Test("Loading a server's history migrates the legacy list into it")
    func loadMigrates() {
        let defaults = makeDefaults()
        SearchHistoryStore.save(["dune"], serverId: nil, defaults: defaults)
        let vm = SearchViewModel(defaults: defaults)

        vm.loadHistory(forServer: "A")

        #expect(vm.recentSearches == ["dune"])
        #expect(SearchHistoryStore.load(serverId: "A", defaults: defaults) == ["dune"])
    }

    @Test("With history capture off, nothing is recorded")
    func captureOff() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: SettingsKey.searchSaveHistory)
        let api = MockAPIClient()
        api.stubbedSearchResults = [makeItem(id: "1", name: "Dune")]
        let appState = makeAppState(api: api, activeServerId: "A")
        let vm = SearchViewModel(defaults: defaults)
        vm.loadHistory(forServer: "A")

        vm.searchText = "Dune"
        vm.search(using: appState)
        try? await Task.sleep(for: .milliseconds(700))

        #expect(vm.results.count == 1)
        #expect(vm.recentSearches.isEmpty)
        #expect(SearchHistoryStore.load(serverId: "A", defaults: defaults).isEmpty)
    }
}
