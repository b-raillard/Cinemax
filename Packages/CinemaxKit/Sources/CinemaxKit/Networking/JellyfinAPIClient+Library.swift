import Foundation
import Get
import JellyfinAPI

extension JellyfinAPIClient {
    // MARK: - Users

    public func getPublicUsers() async throws -> [UserDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getPublicUsers)
        return response.value
    }

    public func getUsers() async throws -> [UserDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getUsers())
        return response.value
    }

    /// Returns all active sessions on the server. Used by the "Currently watching" indicator
    /// on Home to show what other users are streaming right now.
    public func getActiveSessions(activeWithinSeconds: Int = 60) async throws -> [SessionInfoDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetSessionsParameters(activeWithinSeconds: activeWithinSeconds)
        let response = try await client.send(Paths.getSessions(parameters: params))
        return response.value
    }

    // MARK: - Media Queries

    public func getResumeItems(userId: String, limit: Int = 10) async throws -> [BaseItemDto] {
        let cacheKey = "resume-\(userId)-\(limit)-\(getMaxContentAge())"
        if let cached: [BaseItemDto] = cache.get(cacheKey) { return cached }

        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            let params = Paths.GetResumeItemsParameters(
                userID: userId,
                limit: limit,
                enableUserData: true,
                enableImageTypes: [.primary, .backdrop, .thumb]
            )
            let response = try await client.send(Paths.getResumeItems(parameters: params))
            let result = applyRatingFilter(response.value.items ?? [])
            cache.set(cacheKey, value: result, ttl: 30)
            return result
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// Series that have just received episodes, most recent first.
    ///
    /// `/Items/Latest` restricted to episodes with grouping explicitly ON: the
    /// server replaces each episode by its series, so this answers "which shows
    /// got new episodes" rather than "which episodes landed" — a row of posters
    /// wants the show, not an episode still.
    ///
    /// Results are filtered to `.series` deliberately. `isGroupItems` is passed
    /// rather than left to its default so the intent is explicit, and the filter
    /// is the guard for a server that ignores it: better to contribute nothing
    /// than to drop raw episode cards into a poster row.
    public func getSeriesWithRecentEpisodes(userId: String, limit: Int = 8) async throws -> [BaseItemDto] {
        let cacheKey = "latest-episodes-\(userId)-\(limit)-\(getMaxContentAge())"
        if let cached: [BaseItemDto] = cache.get(cacheKey) { return cached }

        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            let params = Paths.GetLatestMediaParameters(
                userID: userId,
                includeItemTypes: [.episode],
                enableImages: true,
                imageTypeLimit: 1,
                enableUserData: true,
                limit: limit,
                isGroupItems: true
            )
            let response = try await client.send(Paths.getLatestMedia(parameters: params))
            let result = applyRatingFilter(response.value).filter { $0.type == .series }
            cache.set(cacheKey, value: result, ttl: 60)
            return result
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// **Home's "Recently Added" rail deliberately does NOT use this.** This
    /// endpoint scans raw items — episodes included — and groups them under
    /// their series (`groupItems` defaults to true, and no `includeItemTypes`
    /// is sent). A library that ingests one series' back catalogue therefore
    /// fills the whole scan with its episodes, which collapse into a SINGLE
    /// card: the row looks empty while faithfully reporting that the newest N
    /// items on the server all belong to one show. `HomeViewModel` combines a
    /// date-added `getItems` over `[.movie, .series]` with
    /// `getSeriesWithRecentEpisodes` instead — two sources, each with its own
    /// budget, so no single show can crowd the row out. Kept for callers that
    /// genuinely want the server's own unfiltered "latest" semantics.
    public func getLatestMedia(userId: String, parentId: String? = nil, limit: Int = 16) async throws -> [BaseItemDto] {
        let cacheKey = "latest-\(userId)-\(parentId ?? "all")-\(limit)-\(getMaxContentAge())"
        if let cached: [BaseItemDto] = cache.get(cacheKey) { return cached }

        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            let params = Paths.GetLatestMediaParameters(
                userID: userId,
                parentID: parentId,
                enableImages: true,
                imageTypeLimit: 1,
                enableUserData: true,
                limit: limit
            )
            let response = try await client.send(Paths.getLatestMedia(parameters: params))
            let result = applyRatingFilter(response.value)
            cache.set(cacheKey, value: result, ttl: 60)
            return result
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    public func getItems(
        userId: String,
        parentId: String? = nil,
        includeItemTypes: [BaseItemKind]? = nil,
        sortBy: [ItemSortBy]? = nil,
        sortOrder: [JellyfinAPI.SortOrder]? = nil,
        genres: [String]? = nil,
        years: [Int]? = nil,
        isFavorite: Bool? = nil,
        filters: [ItemFilter]? = nil,
        limit: Int? = nil,
        startIndex: Int? = nil
    ) async throws -> (items: [BaseItemDto], totalCount: Int) {
        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            let maxOfficialRating = ContentRatingClassifier.maxOfficialRatingCode(forAge: getMaxContentAge())
            var params = Paths.GetItemsParameters(
                userID: userId,
                maxOfficialRating: maxOfficialRating,
                startIndex: startIndex,
                limit: limit,
                isRecursive: true,
                sortOrder: sortOrder,
                parentID: parentId,
                includeItemTypes: includeItemTypes,
                filters: filters,
                sortBy: sortBy,
                genres: genres,
                years: years
            )
            params.isFavorite = isFavorite
            params.fields = [.overview, .genres, .childCount]
            params.enableUserData = true
            params.enableImageTypes = [.primary, .backdrop, .thumb]
            params.imageTypeLimit = 1
            let response = try await client.send(Paths.getItems(parameters: params))
            let result = response.value
            return (result.items ?? [], result.totalRecordCount ?? 0)
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// Fetches available genres for the given item types from the server.
    public func getGenres(
        userId: String,
        includeItemTypes: [BaseItemKind]? = nil
    ) async throws -> [String] {
        let itemTypes = includeItemTypes?.map(\.rawValue).sorted().joined(separator: ",") ?? ""
        let cacheKey = "genres-\(userId)-\(itemTypes)"
        if let cached: [String] = cache.get(cacheKey) { return cached }

        guard let client = getClient() else { throw JellyfinError.notConnected }

        // Prefer /Genres — it reads the genres table directly. The legacy
        // /Items/Filters scan is recursive and walks every episode under every
        // series, which is very slow and can effectively hang on large
        // libraries. Keep /Items/Filters as a fallback for servers/configs where
        // /Genres returns nothing.
        let genresParams = Paths.GetGenresParameters(
            includeItemTypes: includeItemTypes,
            userID: userId,
            enableImages: false,
            enableTotalRecordCount: false
        )
        let genresResponse = try await client.send(Paths.getGenres(parameters: genresParams))
        var result = (genresResponse.value.items ?? []).compactMap(\.name)

        if result.isEmpty {
            let filterParams = Paths.GetQueryFiltersParameters(
                userID: userId,
                includeItemTypes: includeItemTypes,
                isRecursive: true
            )
            let filterResponse = try await client.send(Paths.getQueryFilters(parameters: filterParams))
            result = filterResponse.value.genres?.compactMap(\.name) ?? []
        }

        cache.set(cacheKey, value: result, ttl: 300)
        return result
    }

    public func getUserViews(userId: String) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetUserViewsParameters(userID: userId)
        let response = try await client.send(Paths.getUserViews(parameters: params))
        return response.value.items ?? []
    }

    public func getItem(userId: String, itemId: String) async throws -> BaseItemDto {
        // Short-TTL cache: at playback start the same item is fetched ~3× in a
        // burst (the PlaybackInfo resolve, the chapter/trickplay load, the
        // now-playing metadata enrich). A 10s window collapses that burst into
        // one network round-trip. Every path that mutates this item's userData
        // invalidates the key explicitly so a stale entry is never served: the
        // play-state / favorite mutators, AND `reportPlaybackStopped` (so the
        // detail screen's immediate post-dismiss reload gets the fresh resume
        // position — tvOS reloads synchronously on dismiss).
        //
        // `coalesce` adds in-flight single-flighting so the burst's concurrent
        // callers (which all miss the TTL before the first response lands) share
        // ONE request instead of each firing their own. We coalesce at `Void`:
        // the winning task runs `fetch` (which writes the TTL entry as a side
        // effect) while the others await that same task, then everyone reads the
        // freshly-cached value back — `BaseItemDto` isn't Sendable, so it must
        // never cross the coalescing boundary itself.
        let cacheKey = "item-\(itemId)-\(userId)"
        if let cached: BaseItemDto = cache.get(cacheKey) { return cached }
        let fetch: @Sendable () async throws -> BaseItemDto = { [self] in
            guard let client = getClient() else { throw JellyfinError.notConnected }
            let response = try await client.send(Paths.getItem(itemID: itemId, userID: userId))
            cache.set(cacheKey, value: response.value, ttl: 10)
            return response.value
        }
        do {
            try await cache.coalesce(key: cacheKey) { _ = try await fetch() }
            if let cached: BaseItemDto = cache.get(cacheKey) { return cached }
            // Rare: the entry was invalidated between the winner's `set` and this
            // read (a concurrent userData mutation). Fetch directly.
            return try await fetch()
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// Lightweight per-item userData read (`GET /UserItems/{id}/UserData`).
    ///
    /// Deliberately **uncached**: its only callers want server truth right after
    /// a mutation, which is exactly the window the 10 s `item-` TTL exists to
    /// serve stale. It is also the reason this isn't just `getItem().userData` —
    /// the response is a handful of scalars instead of a full `BaseItemDto`
    /// carrying overview, genres, people, chapters and media sources.
    ///
    /// Returns `nil` — without touching the network — when the server is older
    /// than `ServerVersion.itemUserDataEndpoint` or its version hasn't been
    /// learned yet. Callers must treat `nil` as "ask for the whole item
    /// instead"; `LibraryAPI.fetchUserData` does exactly that, and is what call
    /// sites should use.
    public func getItemUserData(itemId: String, userId: String) async throws -> UserItemDataDto? {
        guard serverSupports(.itemUserDataEndpoint) else { return nil }
        guard let client = getClient() else { throw JellyfinError.notConnected }
        do {
            return try await client.send(Paths.getItemUserData(itemID: itemId, userID: userId)).value
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    public func getSimilarItems(itemId: String, userId: String, limit: Int = 12) async throws -> [BaseItemDto] {
        // "More like this" is stable per item — cache 5 min so re-opening a
        // detail screen (or bouncing in/out of the player) doesn't re-fetch it
        // every time. Cache the raw items and apply the rating filter on the way
        // out so a mid-session content-age change is always honored.
        let cacheKey = "similar-\(itemId)-\(userId)-\(limit)"
        if let cached: [BaseItemDto] = cache.get(cacheKey) {
            return applyRatingFilter(cached)
        }
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetSimilarItemsParameters(userID: userId, limit: limit)
        let response = try await client.send(Paths.getSimilarItems(itemID: itemId, parameters: params))
        let items = response.value.items ?? []
        cache.set(cacheKey, value: items, ttl: 300)
        return applyRatingFilter(items)
    }

    public func searchItems(
        userId: String,
        searchTerm: String,
        includeItemTypes: [BaseItemKind] = [.movie, .series, .episode],
        limit: Int = 20
    ) async throws -> [BaseItemDto] {
        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            let maxOfficialRating = ContentRatingClassifier.maxOfficialRatingCode(forAge: getMaxContentAge())
            let params = Paths.GetItemsParameters(
                userID: userId,
                maxOfficialRating: maxOfficialRating,
                limit: limit,
                isRecursive: true,
                searchTerm: searchTerm,
                includeItemTypes: includeItemTypes
            )
            let response = try await client.send(Paths.getItems(parameters: params))
            return response.value.items ?? []
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    public func getSeasons(seriesId: String, userId: String) async throws -> [BaseItemDto] {
        // Short-TTL cache mirroring `getEpisodes`: every series-detail open
        // fetches the season list, and re-opening the same series (or bouncing
        // in and out of the player) re-fetches it seconds later. A season's
        // userData carries its watched/progress state, so this key rides the
        // same invalidation as `episodes-` — see `markItemPlayed` /
        // `markItemUnplayed` / `reportPlaybackStopped`.
        let cacheKey = "seasons-\(seriesId)-\(userId)"
        if let cached: [BaseItemDto] = cache.get(cacheKey) { return cached }
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetSeasonsParameters(userID: userId, enableUserData: true)
        let response = try await client.send(Paths.getSeasons(seriesID: seriesId, parameters: params))
        let items = response.value.items ?? []
        cache.set(cacheKey, value: items, ttl: 10)
        return items
    }

    public func getEpisodes(seriesId: String, seasonId: String, userId: String) async throws -> [BaseItemDto] {
        // Short-TTL cache mirroring `getItem`: a season's episode list is fetched
        // in overlapping bursts (Home's prev/next nav maps for the Continue
        // Watching + Next Up rails, then the detail screen re-fetching the same
        // season). A 10s window collapses those into one round-trip. Every path
        // that mutates episode userData (played state / resume position)
        // invalidates the `episodes-` prefix so a stale watched-mark / progress
        // bar is never served — see `markItemPlayed` / `markItemUnplayed` /
        // `reportPlaybackStopped`.
        let cacheKey = "episodes-\(seasonId)-\(userId)"
        if let cached: [BaseItemDto] = cache.get(cacheKey) { return applyRatingFilter(cached) }
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetEpisodesParameters(userID: userId, fields: [.overview], seasonID: seasonId, enableUserData: true)
        let response = try await client.send(Paths.getEpisodes(seriesID: seriesId, parameters: params))
        let items = response.value.items ?? []
        cache.set(cacheKey, value: items, ttl: 10)
        return applyRatingFilter(items)
    }

    public func getNextUp(seriesId: String, userId: String) async throws -> BaseItemDto? {
        // Short-TTL cache mirroring `getEpisodes`: a series-detail open fires
        // this alongside `getItem`/`getSeasons`, and the tvOS post-playback
        // refresh re-fires it seconds later. The raw response is cached as an
        // array (not the resolved optional) so a "nothing next" answer caches as
        // an empty array rather than a double-optional, and the rating filter is
        // applied on the way out so a mid-session content-age change is always
        // honored. The payload is the next episode's userData, so this key rides
        // the same invalidation as `episodes-`. Deliberately scoped to the
        // per-series overload — the global `getNextUpEpisodes` rail stays
        // uncached.
        let cacheKey = "nextup-\(seriesId)-\(userId)"
        let items: [BaseItemDto]
        if let cached: [BaseItemDto] = cache.get(cacheKey) {
            items = cached
        } else {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            let params = Paths.GetNextUpParameters(
                userID: userId,
                limit: 1,
                seriesID: seriesId,
                enableUserData: true
            )
            let response = try await client.send(Paths.getNextUp(parameters: params))
            items = response.value.items ?? []
            cache.set(cacheKey, value: items, ttl: 10)
        }
        guard let next = items.first else { return nil }
        return ContentRatingClassifier.passes(rating: next.officialRating, maxAge: getMaxContentAge()) ? next : nil
    }

    public func getNextUpEpisodes(userId: String, limit: Int = 20) async throws -> [BaseItemDto] {
        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            // No `seriesID` ⇒ the server returns the next unwatched episode for
            // every in-progress series (the global rail).
            let params = Paths.GetNextUpParameters(
                userID: userId,
                limit: limit,
                enableUserData: true
            )
            let response = try await client.send(Paths.getNextUp(parameters: params))
            return applyRatingFilter(response.value.items ?? [])
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    // MARK: - User Item Data

    public func markItemUnplayed(itemId: String, userId: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.markUnplayedItem(itemID: itemId, userID: userId))
        // Only the resume list depends on play state — leave genres / latest /
        // serverInfo caches intact so the next navigation doesn't refetch them.
        // Also drop this item's short-TTL getItem entry so the detail screen
        // reflects the new play state immediately rather than after 10s, and every
        // userData-bearing series cache (a series-level toggle cascades to every
        // episode's watched mark, and clearing one moves the series' next-up
        // pointer; the mutator only knows the item id, so drop the lot).
        cache.invalidate(prefix: "resume-")
        cache.invalidate(prefix: "item-\(itemId)-")
        for prefix in Self.userDataCachePrefixes { cache.invalidate(prefix: prefix) }
    }

    public func markItemPlayed(itemId: String, userId: String) async throws {
        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            _ = try await client.send(Paths.markPlayedItem(itemID: itemId, userID: userId))
            // Marking watched pulls the item out of Continue Watching — drop the
            // resume list so the row catches up, plus this item's short-TTL
            // getItem entry and every userData-bearing series cache (a
            // series-level toggle cascades to every episode's watched mark, and
            // marking one played advances the series' next-up pointer). Other
            // caches stay intact.
            cache.invalidate(prefix: "resume-")
            cache.invalidate(prefix: "item-\(itemId)-")
            for prefix in Self.userDataCachePrefixes { cache.invalidate(prefix: prefix) }
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    public func setFavorite(itemId: String, userId: String, favorite: Bool) async throws {
        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            if favorite {
                _ = try await client.send(Paths.markFavoriteItem(itemID: itemId, userID: userId))
            } else {
                _ = try await client.send(Paths.unmarkFavoriteItem(itemID: itemId, userID: userId))
            }
            // The Favorites row refetches uncached; the cached surfaces carrying
            // favorite state are the resume list's userData and this item's
            // short-TTL getItem entry. Scope the invalidation to those rather
            // than nuking genres / latest / serverInfo.
            cache.invalidate(prefix: "resume-")
            cache.invalidate(prefix: "item-\(itemId)-")
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    // MARK: - Persons

    public func getPersonItems(personId: String, userId: String, limit: Int = 60) async throws -> [BaseItemDto] {
        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            let maxOfficialRating = ContentRatingClassifier.maxOfficialRatingCode(forAge: getMaxContentAge())
            var params = Paths.GetItemsParameters(
                userID: userId,
                maxOfficialRating: maxOfficialRating,
                limit: limit,
                isRecursive: true,
                sortOrder: [.descending],
                includeItemTypes: [.movie, .series],
                sortBy: [.premiereDate]
            )
            params.personIDs = [personId]
            let response = try await client.send(Paths.getItems(parameters: params))
            return applyRatingFilter(response.value.items ?? [])
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// Persons whose name matches `searchTerm`.
    ///
    /// Returns `BaseItemDto` — persons *are* Jellyfin items — so the same
    /// scoring and image-URL machinery the title results use applies without
    /// conversion. `/Search/Hints` would answer the same question with a
    /// separate `SearchHint` model, forking the search pipeline for no gain.
    ///
    /// No rating filter: a person carries no official rating, and nothing about
    /// a name or portrait reveals catalogue content. The filmography behind it
    /// goes through `getPersonItems`, which is capped.
    public func searchPersons(userId: String, searchTerm: String, limit: Int) async throws -> [BaseItemDto] {
        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            var params = Paths.GetPersonsParameters()
            params.userID = userId
            params.searchTerm = searchTerm
            params.limit = limit
            params.enableImages = true
            let response = try await client.send(Paths.getPersons(parameters: params))
            return response.value.items ?? []
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    // MARK: - Collections

    public func getCollections(containingItemId itemId: String, tmdbCollectionId: String?, userId: String) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        // Newer servers (post-10.11) have a direct reverse lookup. Hand-built
        // request — jellyfin-sdk-swift 0.6.0 predates the endpoint.
        let direct = Request<BaseItemDtoQueryResult>(
            path: "/Items/\(itemId)/Collections",
            method: "GET",
            query: [("userId", userId)]
        )
        if let response = try? await client.send(direct), let items = response.value.items {
            return applyRatingFilter(items)
        }
        // Fallback: auto-created collections carry the same TMDb collection
        // provider id as their member movies — match against the boxset list.
        guard let tmdbCollectionId, !tmdbCollectionId.isEmpty else { return [] }
        do {
            var params = Paths.GetItemsParameters(
                userID: userId,
                isRecursive: true,
                includeItemTypes: [.boxSet]
            )
            params.fields = [.providerIDs]
            let response = try await client.send(Paths.getItems(parameters: params))
            let matching = (response.value.items ?? []).filter { boxset in
                boxset.providerIDs?.contains { key, value in
                    key.caseInsensitiveCompare("TmdbCollection") == .orderedSame && value == tmdbCollectionId
                } ?? false
            }
            return applyRatingFilter(matching)
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    // MARK: - Media Segments

    public func getMediaSegments(itemId: String, includeSegmentTypes: [JellyfinAPI.MediaSegmentType]? = nil) async throws -> [MediaSegmentDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getItemSegments(itemID: itemId, includeSegmentTypes: includeSegmentTypes))
        return response.value.items ?? []
    }
}
