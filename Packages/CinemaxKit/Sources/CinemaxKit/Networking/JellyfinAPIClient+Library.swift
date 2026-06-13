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

    public func getLatestMedia(userId: String, parentId: String? = nil, limit: Int = 16) async throws -> [BaseItemDto] {
        let cacheKey = "latest-\(userId)-\(limit)-\(getMaxContentAge())"
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
        let params = Paths.GetQueryFiltersParameters(
            userID: userId,
            includeItemTypes: includeItemTypes,
            isRecursive: true
        )
        let response = try await client.send(Paths.getQueryFilters(parameters: params))
        let result = response.value.genres?.compactMap(\.name) ?? []
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
        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            let response = try await client.send(Paths.getItem(itemID: itemId, userID: userId))
            return response.value
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    public func getSimilarItems(itemId: String, userId: String, limit: Int = 12) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetSimilarItemsParameters(userID: userId, limit: limit)
        let response = try await client.send(Paths.getSimilarItems(itemID: itemId, parameters: params))
        return applyRatingFilter(response.value.items ?? [])
    }

    public func searchItems(userId: String, searchTerm: String, limit: Int = 20) async throws -> [BaseItemDto] {
        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            let maxOfficialRating = ContentRatingClassifier.maxOfficialRatingCode(forAge: getMaxContentAge())
            let params = Paths.GetItemsParameters(
                userID: userId,
                maxOfficialRating: maxOfficialRating,
                limit: limit,
                isRecursive: true,
                searchTerm: searchTerm,
                includeItemTypes: [.movie, .series, .episode]
            )
            let response = try await client.send(Paths.getItems(parameters: params))
            return response.value.items ?? []
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    public func getSeasons(seriesId: String, userId: String) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetSeasonsParameters(userID: userId, enableUserData: true)
        let response = try await client.send(Paths.getSeasons(seriesID: seriesId, parameters: params))
        return response.value.items ?? []
    }

    public func getEpisodes(seriesId: String, seasonId: String, userId: String) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetEpisodesParameters(userID: userId, fields: [.overview], seasonID: seasonId, enableUserData: true)
        let response = try await client.send(Paths.getEpisodes(seriesID: seriesId, parameters: params))
        return applyRatingFilter(response.value.items ?? [])
    }

    public func getNextUp(seriesId: String, userId: String) async throws -> BaseItemDto? {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetNextUpParameters(
            userID: userId,
            limit: 1,
            seriesID: seriesId,
            enableUserData: true
        )
        let response = try await client.send(Paths.getNextUp(parameters: params))
        guard let next = response.value.items?.first else { return nil }
        return ContentRatingClassifier.passes(rating: next.officialRating, maxAge: getMaxContentAge()) ? next : nil
    }

    // MARK: - User Item Data

    public func markItemUnplayed(itemId: String, userId: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.markUnplayedItem(itemID: itemId, userID: userId))
        // Only the resume list depends on play state — leave genres / latest /
        // serverInfo caches intact so the next navigation doesn't refetch them.
        cache.invalidate(prefix: "resume-")
    }

    public func markItemPlayed(itemId: String, userId: String) async throws {
        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            _ = try await client.send(Paths.markPlayedItem(itemID: itemId, userID: userId))
            // Marking watched pulls the item out of Continue Watching — drop the
            // resume list so the row catches up. Other caches stay intact.
            cache.invalidate(prefix: "resume-")
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
            // The Favorites row refetches uncached; the only cached surface
            // carrying favorite state is the resume list's userData. Scope the
            // invalidation to it rather than nuking genres / latest / serverInfo.
            cache.invalidate(prefix: "resume-")
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
