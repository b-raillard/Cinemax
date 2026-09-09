import Foundation
@preconcurrency import JellyfinAPI

/// Which Jellyfin libraries the browse layout's « Collections » row asks about.
///
/// A library-mode tab names its own view (`parentId`) and that is the whole
/// scope. The default Films / Séries tabs carry NO id — they are typed, not
/// scoped — so they resolve to every user view of the matching collection
/// type (`movies` for films, `tvshows` for series), which is what makes a
/// server with two film libraries list both libraries' sagas on the Films tab
/// and none of them on Séries. A mixed / untyped tab without an id has nothing
/// to scope on and asks for nothing: the alternative, no `parentId` at all, is
/// exactly the global query Home's own rail issues, and duplicating Home's
/// rail under every library is the one shape this row must never take.
///
/// Pure and `nonisolated` so it can be unit-tested and called off any actor;
/// it reads scalars off the DTOs and returns ids only.
enum LibraryCollectionsScope {
    nonisolated static func libraryIds(parentId: String?, itemType: BaseItemKind?, views: [BaseItemDto]) -> [String] {
        if let parentId, !parentId.isEmpty { return [parentId] }
        let wanted: CollectionType
        switch itemType {
        case .movie: wanted = .movies
        case .series: wanted = .tvshows
        default: return []
        }
        return views.compactMap { view in
            guard view.collectionType == wanted, let id = view.id, !id.isEmpty else { return nil }
            return id
        }
    }
}
