import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Presentation state for a single genre row on Home. `.failed` surfaces a
/// retry chip instead of silently skipping the row, so transient server
/// errors don't just make content disappear.
enum GenreRowState: Equatable {
    case items([BaseItemDto])
    case failed
}

struct GenreRow: Identifiable, Equatable {
    let genre: String
    var state: GenreRowState
    var id: String { genre }
}

@MainActor @Observable
final class HomeViewModel {
    var heroItem: BaseItemDto?
    var resumeItems: [BaseItemDto] = []
    var latestItems: [BaseItemDto] = []
    /// Ordered genre rows. `.failed` rows render a retry chip; rows that
    /// succeed but return zero items are dropped.
    var genreRows: [GenreRow] = []
    /// Episode navigation keyed by episode item ID. Populated after resumeItems loads.
    var resumeNavigation: [String: (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)] = [:]
    /// Other users currently watching something on this server. Excludes the logged-in user.
    var activeSessions: [SessionInfoDto] = []
    var isLoading = true
    var errorMessage: String?

    /// Re-runs the full home load (equivalent to calling `load` again). Exposed for pull-to-refresh.
    func reload(using appState: AppState) async {
        activeSessions = []
        await load(using: appState)
    }

    func load(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        isLoading = true
        errorMessage = nil

        enum Section { case resume([BaseItemDto]); case latest([BaseItemDto]) }

        await withTaskGroup(of: Section?.self) { group in
            group.addTask {
                (try? await appState.apiClient.getResumeItems(userId: userId, limit: 20))
                    .map { .resume($0) }
            }
            group.addTask {
                (try? await appState.apiClient.getLatestMedia(userId: userId, limit: 20))
                    .map { .latest($0) }
            }
            for await result in group {
                switch result {
                case .resume(let items): resumeItems = items
                case .latest(let items): latestItems = items
                case nil: break
                }
            }
        }

        heroItem = resumeItems.first ?? latestItems.first

        // For each unique season referenced by resume episodes, fetch the episode list once
        // so we can compute prev/next refs and build a navigator for the player.
        let episodeItems = resumeItems.filter { $0.type == .episode }
        if !episodeItems.isEmpty {
            var seasonEpisodes: [String: [BaseItemDto]] = [:]
            await withTaskGroup(of: (String, [BaseItemDto])?.self) { group in
                var seen = Set<String>()
                for item in episodeItems {
                    guard let seasonId = item.seasonID,
                          let seriesId = item.seriesID,
                          !seen.contains(seasonId) else { continue }
                    seen.insert(seasonId)
                    group.addTask {
                        guard let eps = try? await appState.apiClient.getEpisodes(
                            seriesId: seriesId, seasonId: seasonId, userId: userId
                        ) else { return nil }
                        return (seasonId, eps)
                    }
                }
                for await result in group {
                    if let (seasonId, eps) = result { seasonEpisodes[seasonId] = eps }
                }
            }

            // Precompute refs + id→index per season once so each episode's
            // prev/next lookup is O(1) rather than O(n) inside the helper.
            var precomputed: [String: (refs: [EpisodeRef], indexByID: [String: Int])] = [:]
            precomputed.reserveCapacity(seasonEpisodes.count)
            for (seasonId, eps) in seasonEpisodes {
                precomputed[seasonId] = precomputeEpisodeRefs(eps)
            }

            resumeNavigation.removeAll()
            for item in episodeItems {
                guard let id = item.id,
                      let seasonId = item.seasonID,
                      let pre = precomputed[seasonId] else { continue }
                resumeNavigation[id] = buildEpisodeNavigation(
                    for: id, refs: pre.refs, indexByID: pre.indexByID,
                    apiClient: appState.apiClient, userId: userId
                )
            }
        } else {
            resumeNavigation.removeAll()
        }

        // Genre rows: pick up to 4 random genres from the server and fetch 10 random
        // items per genre in parallel. Genres with no items are skipped.
        await loadGenreRows(userId: userId, appState: appState)

        // Active sessions ("Watching Now" row). Non-blocking — quietly drops on error.
        await loadActiveSessions(userId: userId, appState: appState)

        isLoading = false
    }

    /// Fetches active sessions and filters down to ones with a currently-playing item,
    /// excluding the logged-in user (their own "resume" already covers that).
    private func loadActiveSessions(userId: String, appState: AppState) async {
        do {
            let all = try await appState.apiClient.getActiveSessions(activeWithinSeconds: 60)
            activeSessions = all.filter { session in
                session.nowPlayingItem != nil
                    && (session.userID ?? "") != userId
            }
        } catch {
            activeSessions = []
        }
    }

    private func loadGenreRows(userId: String, appState: AppState) async {
        let allGenres: [String]
        do {
            allGenres = try await appState.apiClient.getGenres(
                userId: userId, includeItemTypes: [.movie, .series]
            )
        } catch {
            genreRows = []
            return
        }

        guard !allGenres.isEmpty else {
            genreRows = []
            return
        }

        let picked = Array(allGenres.shuffled().prefix(4))

        // Fetch items for each picked genre in parallel. Preserve the order of `picked`.
        // Distinguish failure (→ retry chip) from empty success (→ drop the row).
        enum FetchResult { case success([BaseItemDto]); case failure }
        var results: [String: FetchResult] = [:]
        await withTaskGroup(of: (String, FetchResult).self) { group in
            for genre in picked {
                group.addTask {
                    do {
                        let items = try await Self.fetchGenreItems(
                            genre: genre, userId: userId, appState: appState
                        )
                        return (genre, .success(items))
                    } catch {
                        return (genre, .failure)
                    }
                }
            }
            for await (genre, result) in group {
                results[genre] = result
            }
        }

        genreRows = picked.compactMap { genre in
            switch results[genre] {
            case .success(let items) where !items.isEmpty:
                return GenreRow(genre: genre, state: .items(items))
            case .failure:
                return GenreRow(genre: genre, state: .failed)
            default:
                return nil
            }
        }
    }

    /// Re-fetches a single genre after the user taps its retry chip.
    /// Updates `genreRows` in place so only the affected row re-renders.
    func retryGenre(_ genre: String, using appState: AppState) async {
        guard let userId = appState.currentUserId,
              let index = genreRows.firstIndex(where: { $0.genre == genre }) else { return }
        do {
            let items = try await Self.fetchGenreItems(genre: genre, userId: userId, appState: appState)
            if items.isEmpty {
                genreRows.remove(at: index)
            } else {
                genreRows[index].state = .items(items)
            }
        } catch {
            genreRows[index].state = .failed
        }
    }

    nonisolated private static func fetchGenreItems(
        genre: String, userId: String, appState: AppState
    ) async throws -> [BaseItemDto] {
        let response = try await appState.apiClient.getItems(
            userId: userId,
            parentId: nil,
            includeItemTypes: [.movie, .series],
            sortBy: [.random],
            sortOrder: nil,
            genres: [genre],
            years: nil,
            isFavorite: nil,
            filters: nil,
            limit: 10,
            startIndex: nil
        )
        return response.items
    }
}
