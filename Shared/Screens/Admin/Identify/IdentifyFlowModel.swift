#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Shared state + network logic for the Identify flow. Hosted both by the
/// standalone `IdentifyScreen` (pushed from the admin 3-dot menu on detail
/// screens and library poster cards) and by `MetadataIdentifyTab` inside the
/// broader `MetadataEditorScreen`, so the two surfaces stay feature-identical.
///
/// The Jellyfin server accepts provider IDs alongside the name/year hints —
/// pasting a TMDb or IMDb id short-circuits the fuzzy search. We expose one
/// field per provider so the user can mix and match (name + year, or bare
/// provider id, or any combination).
@MainActor @Observable
final class IdentifyFlowModel {
    let itemId: String
    let itemKind: BaseItemKind
    let initialItemName: String?

    /// Server-side file path displayed in the "Chemin" row of the form. Loaded
    /// on first appear via `getItem` — avoids a second round-trip on screens
    /// that already have the DTO by rendering whatever it carried in.
    var itemPath: String?

    // Form fields
    var name: String
    var year: String
    var imdbId: String = ""
    var tmdbId: String = ""
    var tmdbCollectionId: String = ""
    var tvdbId: String = ""

    // Search state
    var results: [RemoteSearchResult] = []
    var isSearching = false
    var errorMessage: String?

    // Apply state
    var replaceAllImages: Bool = true
    var isApplying = false

    init(item: BaseItemDto) {
        self.itemId = item.id ?? ""
        self.itemKind = item.type ?? .movie
        self.initialItemName = item.name
        self.itemPath = item.path
        self.name = item.name ?? ""
        self.year = item.productionYear.map(String.init) ?? ""
    }

    var isSupportedKind: Bool {
        switch itemKind {
        case .movie, .series: true
        default: false
        }
    }

    /// Returns true if the user has entered at least one usable criterion
    /// (name or any provider ID). Year alone isn't enough to disambiguate.
    var canSearch: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasProvider = !imdbId.trimmingCharacters(in: .whitespaces).isEmpty
            || !tmdbId.trimmingCharacters(in: .whitespaces).isEmpty
            || !tmdbCollectionId.trimmingCharacters(in: .whitespaces).isEmpty
            || !tvdbId.trimmingCharacters(in: .whitespaces).isEmpty
        return hasName || hasProvider
    }

    // MARK: - Network

    /// Lazy fetch of the item path. Called once from the form on first
    /// appearance; if the caller already passed a `BaseItemDto` with `path`
    /// set, this is a no-op.
    func loadPathIfNeeded(using apiClient: any APIClientProtocol, userId: String) async {
        guard itemPath == nil, !itemId.isEmpty, !userId.isEmpty else { return }
        if let item = try? await apiClient.getItem(userId: userId, itemId: itemId) {
            self.itemPath = item.path
        }
    }

    /// Dispatches to the right remote-search endpoint based on the item's
    /// kind. Only movies and series are supported.
    func runSearch(using apiClient: any APIClientProtocol) async {
        guard !itemId.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        let trimmedYear = Int(year.trimmingCharacters(in: .whitespaces))
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let providerIDs = collectedProviderIDs()

        do {
            switch itemKind {
            case .movie:
                var info = MovieInfo()
                info.name = trimmedName.isEmpty ? nil : trimmedName
                info.year = trimmedYear
                if !providerIDs.isEmpty { info.providerIDs = providerIDs }
                let query = MovieInfoRemoteSearchQuery(itemID: itemId, searchInfo: info)
                results = try await apiClient.searchRemoteMovies(query: query)
            case .series:
                var info = SeriesInfo()
                info.name = trimmedName.isEmpty ? nil : trimmedName
                info.year = trimmedYear
                if !providerIDs.isEmpty { info.providerIDs = providerIDs }
                let query = SeriesInfoRemoteSearchQuery(itemID: itemId, searchInfo: info)
                results = try await apiClient.searchRemoteSeries(query: query)
            default:
                results = []
                errorMessage = "Identify isn't supported for this item kind"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Applies a chosen result. Returns `true` on success so the hosting
    /// screen can toast + dismiss/pop. Posts `.cinemaxShouldRefreshCatalogue`
    /// on success so Home and Library re-fetch with the new artwork.
    func apply(_ result: RemoteSearchResult, using apiClient: any APIClientProtocol) async -> Bool {
        guard !itemId.isEmpty else { return false }
        isApplying = true
        errorMessage = nil
        defer { isApplying = false }
        do {
            try await apiClient.applyRemoteSearchResult(
                itemId: itemId,
                result: result,
                replaceAllImages: replaceAllImages
            )
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Helpers

    private func collectedProviderIDs() -> [String: String] {
        var dict: [String: String] = [:]
        let imdb = imdbId.trimmingCharacters(in: .whitespaces)
        let tmdb = tmdbId.trimmingCharacters(in: .whitespaces)
        let tvdb = tvdbId.trimmingCharacters(in: .whitespaces)
        let tmdbCollection = tmdbCollectionId.trimmingCharacters(in: .whitespaces)
        if !imdb.isEmpty { dict["Imdb"] = imdb }
        if !tmdb.isEmpty { dict["Tmdb"] = tmdb }
        if !tvdb.isEmpty { dict["Tvdb"] = tvdb }
        if !tmdbCollection.isEmpty { dict["TmdbCollection"] = tmdbCollection }
        return dict
    }
}
#endif
