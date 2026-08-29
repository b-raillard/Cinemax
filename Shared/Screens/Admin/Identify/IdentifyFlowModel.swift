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
    func runSearch(using apiClient: any APIClientProtocol, loc: LocalizationManager) async {
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
                // Defensive only — the UI gates search behind `isSupportedKind`,
                // so this branch isn't reachable in practice. Avoid surfacing a
                // hardcoded (unlocalized) string; just clear results.
                results = []
            }
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
        }
    }

    /// Applies a chosen result. Returns `true` on success so the hosting
    /// screen can toast + dismiss/pop. Posts `.cinemaxShouldRefreshCatalogue`
    /// on success so Home and Library re-fetch with the new artwork.
    func apply(_ result: RemoteSearchResult, using apiClient: any APIClientProtocol, loc: LocalizationManager) async -> Bool {
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

            // Pin the artwork the user actually chose.
            //
            // `ApplySearchCriteria` does NOT apply the poster shown next to the
            // result: it sets the provider ids, re-runs a full refresh, and the
            // metadata providers then re-pick artwork by THEIR own ranking
            // (language + provider order). Measured on device 2026-08-29 — the
            // `primaryImageTag` moves on every apply, so the image really is
            // re-downloaded, but TMDb re-picks the same poster every time.
            // Re-identifying an already-correct film was therefore a
            // no-visible-op, and picking the elephants poster over the Anthony
            // Mackie one changed nothing, because neither was ever a candidate.
            //
            // Picking a result is the user stating which artwork they want, so
            // we apply it explicitly, AFTER the refresh — the server's own
            // download lands during `applySearchCriteria`, so doing this first
            // would simply be overwritten.
            //
            // Gated on `replaceAllImages`: unticked means "keep my images", and
            // forcing ours would be precisely the setting's opposite.
            if replaceAllImages,
               let chosenArtwork = result.imageURL?.trimmingCharacters(in: .whitespaces),
               !chosenArtwork.isEmpty {
                try await apiClient.downloadRemoteImage(
                    itemId: itemId,
                    type: .primary,
                    imageURL: chosenArtwork
                )
            }

            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
            return true
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
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
