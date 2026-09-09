import Testing
import Foundation
@preconcurrency import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// The browse layout's « Collections » row: which libraries it asks about, that
/// it is a silent side task, and that the query is gated on a KNOWN 12.0.
@Suite("Library collections row")
struct LibraryCollectionsRowTests {

    private static func view(_ id: String, _ type: CollectionType?) -> BaseItemDto {
        var dto = BaseItemDto()
        dto.id = id
        dto.name = id
        dto.collectionType = type
        return dto
    }

    private static func boxSet(_ id: String, _ name: String) -> BaseItemDto {
        var dto = BaseItemDto()
        dto.id = id
        dto.name = name
        dto.type = .boxSet
        return dto
    }

    @MainActor
    private static func makeAppState(api: MockAPIClient) -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = "u1"
        return appState
    }

    @Test("a library-mode tab scopes on its own view id, whatever the views say")
    func scopedTab() {
        let ids = LibraryCollectionsScope.libraryIds(
            parentId: "lib-films-2",
            itemType: .movie,
            views: [Self.view("lib-films-1", .movies)]
        )
        #expect(ids == ["lib-films-2"])
    }

    @Test("the default Films tab resolves to every film view, and Séries to every series view")
    func typedTabs() {
        let views = [
            Self.view("films", .movies),
            Self.view("films-4k", .movies),
            Self.view("series", .tvshows),
            Self.view("music", .music),
            Self.view("boxsets", .boxsets),
        ]
        #expect(LibraryCollectionsScope.libraryIds(parentId: nil, itemType: .movie, views: views) == ["films", "films-4k"])
        #expect(LibraryCollectionsScope.libraryIds(parentId: nil, itemType: .series, views: views) == ["series"])
    }

    @Test("an untyped tab with no id asks for nothing — never the global query")
    func untypedTabIsSilent() {
        let views = [Self.view("films", .movies)]
        #expect(LibraryCollectionsScope.libraryIds(parentId: nil, itemType: nil, views: views).isEmpty)
        #expect(LibraryCollectionsScope.libraryIds(parentId: "", itemType: nil, views: views).isEmpty)
    }

    @Test("the gate is 12.0.0 — 10.11 and an unknown version stay silent")
    func threshold() {
        #expect(ServerVersion.libraryScopedCollections == ServerVersion(12, 0, 0))
        #expect(ServerVersion(12, 0, 0).supports(.libraryScopedCollections))
        #expect(ServerVersion(12, 1, 3).supports(.libraryScopedCollections))
        #expect(!ServerVersion(10, 11, 11).supports(.libraryScopedCollections))
        #expect(!ServerVersion(10, 12, 0).supports(.libraryScopedCollections),
                "there is no 10.12, and a hypothetical one would still be below 12.0")
    }

    @Test("the Films tab fills the row from the film views' collections")
    @MainActor
    func filmsTabRow() async throws {
        let api = MockAPIClient()
        api.stubbedUserViews = [Self.view("films", .movies), Self.view("series", .tvshows)]
        api.stubbedLibraryCollections = [Self.boxSet("c1", "Pirates des Caraïbes"), Self.boxSet("c2", "Alien")]
        let appState = Self.makeAppState(api: api)
        let vm = MediaLibraryViewModel(itemType: .movie)

        await vm.loadCollections(using: appState, userId: "u1")

        #expect(api.libraryCollectionsRequestedIds == [["films"]])
        #expect(vm.collections.map(\.id) == ["c1", "c2"])
    }

    @Test("a scoped tab never spends a getUserViews and asks for its own id")
    @MainActor
    func scopedTabRow() async throws {
        let api = MockAPIClient()
        api.stubbedUserViews = [Self.view("films", .movies)]
        api.stubbedLibraryCollections = [Self.boxSet("c1", "Alien")]
        let appState = Self.makeAppState(api: api)
        let vm = MediaLibraryViewModel(itemType: .movie, parentId: "lib-x")

        await vm.loadCollections(using: appState, userId: "u1")

        #expect(api.libraryCollectionsRequestedIds == [["lib-x"]])
        #expect(vm.collections.map(\.id) == ["c1"])
    }

    @Test("a series library on a server whose sagas are all films draws no row")
    @MainActor
    func emptyScopeIsEmptyRow() async throws {
        let api = MockAPIClient()
        api.stubbedUserViews = [Self.view("films", .movies)]   // no tvshows view at all
        api.stubbedLibraryCollections = [Self.boxSet("c1", "Alien")]
        let appState = Self.makeAppState(api: api)
        let vm = MediaLibraryViewModel(itemType: .series)

        await vm.loadCollections(using: appState, userId: "u1")

        #expect(api.libraryCollectionsRequestedIds == [[]])
        #expect(vm.collections.isEmpty)
    }

    @Test("a failed fetch leaves the row absent — no error state")
    @MainActor
    func failureIsSilent() async throws {
        let api = MockAPIClient()
        api.stubbedUserViews = [Self.view("films", .movies)]
        api.shouldThrow = true
        let appState = Self.makeAppState(api: api)
        let vm = MediaLibraryViewModel(itemType: .movie)

        await vm.loadCollections(using: appState, userId: "u1")

        #expect(vm.collections.isEmpty)
        #expect(vm.errorMessage == nil)
    }
}
