import Foundation
@preconcurrency import JellyfinAPI

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
    /// Uncached on purpose: its only caller is the "add to playlist" picker,
    /// which is opened right after the user may have created a playlist from
    /// that same sheet.
    public func getPlaylists(userId: String) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        var params = Paths.GetItemsParameters(
            userID: userId,
            isRecursive: true,
            sortOrder: [.ascending],
            includeItemTypes: [.playlist],
            sortBy: [.sortName]
        )
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
    /// infers the type from the seed items, which fails for an empty seed.
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
            _ = try await client.send(Paths.addItemToPlaylist(playlistID: playlistId, ids: itemIds, userID: userId))
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
}
