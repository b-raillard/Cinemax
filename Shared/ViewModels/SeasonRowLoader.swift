import Foundation
import CinemaxKit
import JellyfinAPI

/// The season's titles: the Home row (`rowLimit`) and its « Tout voir » grid
/// (`fullLimit`) read the same two queries, so the grid opens on the row's
/// first cards.
enum SeasonRowLoader {
    static let rowLimit = 16
    /// Per query, no pagination: two queries merged cannot share an offset.
    static let fullLimit = 500

    /// Genre and keywords are two queries: `genres` and `tags` AND on the
    /// server, and the genre alone misses the series (see `SeasonRow`). Each
    /// fails on its own; empty when both do.
    static func items(for row: SeasonRow, limit: Int, userId: String, appState: AppState) async -> [BaseItemDto] {
        async let tagged = taggedItems(tags: row.tagCandidates, limit: limit, userId: userId, appState: appState)
        async let byGenre = genreItems(candidates: row.genreCandidates, limit: limit, userId: userId, appState: appState)
        return SeasonRowMix.merge(tagged: await tagged, genre: await byGenre, limit: limit)
    }

    private static func genreItems(
        candidates: [String], limit: Int, userId: String, appState: AppState
    ) async -> [BaseItemDto] {
        guard let genres = try? await appState.apiClient.getGenres(userId: userId, includeItemTypes: [.movie, .series]),
              let genre = SeasonRowMatcher.match(candidates: candidates, in: genres),
              let response = try? await appState.apiClient.getItems(
                  userId: userId,
                  includeItemTypes: [.movie, .series],
                  sortBy: [.dateCreated],
                  sortOrder: [.descending],
                  genres: [genre],
                  limit: limit,
                  enableTotalRecordCount: false,
                  fieldSet: .card
              )
        else { return [] }
        return response.items
    }

    private static func taggedItems(
        tags: [String], limit: Int, userId: String, appState: AppState
    ) async -> [BaseItemDto] {
        guard !tags.isEmpty else { return [] }
        return (try? await appState.apiClient.getTaggedItems(
            userId: userId, tags: tags, includeItemTypes: [.movie, .series], limit: limit
        )) ?? []
    }
}
