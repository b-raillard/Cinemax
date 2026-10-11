import Foundation
import JellyfinAPI

// MARK: - Playlists (write)
//
// Playlists were read-only until now: `LibraryFolderBrowseScreen` lists them and
// `MediaLibraryScreen(parentId:)` shows their contents, but nothing could create
// one or put anything in it. These are the mutating endpoints.
//
// The conformance is declared here, not in the aggregate list in
// `APIClientProtocol.swift` — same RULE as `+SyncPlay.swift` / `+RemoteControl.swift`:
// a slice implemented in one file declares its conformance in that file, so
// adding it to the `APIClientProtocol` typealias can't leave the real client
// silently non-conforming (a failure that otherwise surfaces far from the code,
// at the first `any APIClientProtocol` call site).

extension JellyfinAPIClient: PlaylistAPI {
    /// Every playlist visible to the user.
    ///
    /// There is no "list playlists" endpoint — playlists are ordinary items, so
    /// this is a recursive `/Items` query filtered to `Playlist`. Sorted by name
    /// server-side so the picker order is stable between openings.
    ///
    /// Uncached on purpose: its callers (the "add to playlist" picker, Home's
    /// rail, « Vos playlists ») are opened right after the user may have
    /// created, renamed or deleted a playlist.
    ///
    /// `canDelete` is what decides whether a card offers « Renommer » /
    /// « Supprimer » (the server computes it per user: owner or administrator);
    /// `childCount` is the count a card shows until its preview
    /// (`getPlaylistPreview`) brings the authoritative total. No images: a card
    /// draws its own cover from its first entries' posters, never the server's
    /// 2×2 mosaic (which repeats a poster when the playlist holds one or two).
    public func getPlaylists(userId: String) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        var params = Paths.GetItemsParameters(
            userID: userId,
            isRecursive: true,
            sortOrder: [.ascending],
            includeItemTypes: [.playlist],
            sortBy: [.sortName]
        )
        params.fields = [.canDelete, .childCount]
        params.enableImages = false
        params.enableUserData = false
        do {
            let response = try await client.send(Paths.getItems(parameters: params))
            // No `applyRatingFilter`: a playlist is a container with no
            // `officialRating` of its own, so the classifier would judge it on a
            // nil rating. Its *contents* stay filtered by every read path.
            return response.value.items ?? []
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// Creates a playlist seeded with `itemIds` and returns the new playlist id.
    ///
    /// `mediaType: .video` matches what this app can play; without it Jellyfin
    /// infers the type from the seed items, and an EMPTY seed silently becomes
    /// an **Audio** playlist (10.9 → 12.x `PlaylistManager.CreatePlaylist`).
    public func createPlaylist(name: String, itemIds: [String], userId: String) async throws -> String {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let body = CreatePlaylistDto(
            ids: itemIds,
            isPublic: false,
            mediaType: .video,
            name: name,
            userID: userId
        )
        do {
            let response = try await client.send(Paths.createPlaylist(body))
            guard let id = response.value.id, !id.isEmpty else {
                throw JellyfinError.playbackFailed("Playlist creation returned no id")
            }
            return id
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    public func addToPlaylist(playlistId: String, itemIds: [String], userId: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        do {
            var params = Paths.AddItemToPlaylistParameters()
            params.ids = itemIds
            params.userID = userId
            _ = try await client.send(Paths.addItemToPlaylist(playlistID: playlistId, parameters: params))
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// Removes entries by their **playlist entry id** (`BaseItemDto.playlistItemID`),
    /// NOT the item id — the same film can sit in a playlist twice, and Jellyfin
    /// addresses each occurrence separately. `playlistItemID` is populated by
    /// `getPlaylistItems`; a plain `/Items?parentId=` read leaves it nil, so
    /// callers must fetch through this slice before they can remove anything.
    public func removeFromPlaylist(playlistId: String, entryIds: [String]) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        do {
            _ = try await client.send(Paths.removeItemFromPlaylist(playlistID: playlistId, entryIDs: entryIds))
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// Moves an entry to `newIndex` (0-based). Takes an entry id for the same
    /// reason as `removeFromPlaylist`.
    public func movePlaylistItem(playlistId: String, entryId: String, newIndex: Int) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        do {
            _ = try await client.send(Paths.moveItem(playlistID: playlistId, itemID: entryId, newIndex: newIndex))
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// A playlist's contents **in playlist order**, each carrying its
    /// `playlistItemID`. Distinct from `getItems(parentId:)`, which returns the
    /// same items sorted by the caller's criteria and without entry ids.
    public func getPlaylistItems(playlistId: String, userId: String) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        var params = Paths.GetPlaylistItemsParameters(userID: userId)
        params.enableUserData = true
        params.enableImageTypes = [.primary, .backdrop, .thumb]
        params.imageTypeLimit = 1
        do {
            let response = try await client.send(Paths.getPlaylistItems(playlistID: playlistId, parameters: params))
            return applyRatingFilter(response.value.items ?? [])
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// The first `limit` entries and the playlist's total, for a card's cover
    /// and count. As light as the route allows: no userData, the primary image
    /// tag only. An episode's `seriesID` / `seriesPrimaryImageTag` come back
    /// without asking (the server always fills them), which is what lets the
    /// cover show the SERIES poster instead of a 16:9 still squeezed into 2:3.
    ///
    /// `totalRecordCount` is the playlist's full length — the server counts
    /// before it applies `limit`. Uncached, like every read of this slice: the
    /// preview is held by the app's own store, which invalidates it on
    /// `.cinemaxPlaylistsChanged`.
    public func getPlaylistPreview(playlistId: String, userId: String, limit: Int) async throws -> PlaylistPreviewPage {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        var params = Paths.GetPlaylistItemsParameters(userID: userId)
        params.limit = limit
        params.enableUserData = false
        params.enableImageTypes = [.primary]
        params.imageTypeLimit = 1
        do {
            let response = try await client.send(Paths.getPlaylistItems(playlistID: playlistId, parameters: params))
            let items = applyRatingFilter(response.value.items ?? [])
            return PlaylistPreviewPage(items: items, totalCount: response.value.totalRecordCount ?? items.count)
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// Deletes the playlist (`DELETE /Items/{id}`) — the playlist only, its
    /// films and series stay in the library.
    ///
    /// RULE — NO `notifyIfUnauthorized` here. Jellyfin answers a refused delete
    /// with **401 Unauthorized** (`LibraryController.DeleteItem`: `if
    /// (!item.CanDelete(user)) return Unauthorized(…)`, and a playlist's
    /// `CanDelete` is "administrator or owner"). That 401 means "not your
    /// playlist", NOT "your session expired": routed into the session-expiry
    /// coordinator it would re-validate the token for nothing at best, and it
    /// is precisely the shape of request that coordinator exists to never sign
    /// a user out over. The caller shows a dedicated « Impossible de supprimer
    /// cette playlist » rather than `userFacingMessage`, which reads any 401
    /// as « session expirée ».
    public func deletePlaylist(playlistId: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.deleteItem(itemID: playlistId))
        // Every cached read that could still list it (same as the admin
        // `deleteItem`).
        cache.clear()
    }

    /// Renames the playlist (`POST /Playlists/{id}`, Jellyfin 10.9+ — the
    /// project's floor). Only `name` is set: the DTO encodes its nil fields
    /// not at all, so the entries and the shares are left exactly as they
    /// are. The server answers 403 to a user who neither owns the playlist nor
    /// holds an editing share — a refusal, not a session problem, but a 401
    /// here would be a genuine authentication failure, hence the usual hook.
    ///
    /// Only the playlist's own `item-` entry is dropped: no cached read lists
    /// playlists by name (`getPlaylists` and `getPlaylistItems` are uncached),
    /// and a full `clear()` would refetch every rail of the app for a rename.
    public func renamePlaylist(playlistId: String, name: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        do {
            _ = try await client.send(Paths.updatePlaylist(playlistID: playlistId, UpdatePlaylistDto(name: name)))
            cache.invalidate(prefix: "item-\(playlistId)-")
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }
}
