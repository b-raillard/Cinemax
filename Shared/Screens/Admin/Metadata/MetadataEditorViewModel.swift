#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

enum MetadataEditorTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case images
    case cast
    case identify
    case actions

    var id: String { rawValue }
}

@MainActor @Observable
final class MetadataEditorViewModel {
    /// Working copy. Every tab's bindings read/write this.
    var item: BaseItemDto
    private var original: BaseItemDto

    var selectedTab: MetadataEditorTab = .general
    var isSaving = false
    var isRefreshing = false
    var isDeleting = false
    var errorMessage: String?

    // Images
    var showAddImageSheet = false
    var pendingImageType: JellyfinAPI.ImageType = .primary
    var newImageURL: String = ""
    var pendingImageDelete: (type: JellyfinAPI.ImageType, index: Int?)?

    // Cast
    var editingPerson: BaseItemPerson?
    var pendingPersonDelete: Int?

    // Identify
    var identifyName: String = ""
    var identifyYear: String = ""
    var identifyResults: [RemoteSearchResult] = []
    var isSearchingIdentify = false
    var pendingIdentifyApply: RemoteSearchResult?
    var identifyReplaceAllImages: Bool = false

    // Actions
    var refreshMetadataMode: MetadataRefreshMode = .default
    var refreshImageMode: MetadataRefreshMode = .default
    var refreshReplaceAllMetadata: Bool = false
    var refreshReplaceAllImages: Bool = false
    var showDeleteConfirm = false

    init(item: BaseItemDto) {
        self.item = item
        self.original = item
        self.identifyName = item.name ?? ""
        if let year = item.productionYear { self.identifyYear = String(year) }
    }

    var isDirty: Bool { item != original }

    // MARK: - Save

    func save(using apiClient: any APIClientProtocol) async -> Bool {
        guard let id = item.id else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await apiClient.updateItem(id: id, item: item)
            original = item
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Images

    func addImageFromURL(using apiClient: any APIClientProtocol, userId: String) async -> Bool {
        guard let id = item.id else { return false }
        let url = newImageURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, URL(string: url) != nil else {
            errorMessage = "Invalid URL"
            return false
        }
        errorMessage = nil
        do {
            try await apiClient.downloadRemoteImage(itemId: id, type: pendingImageType, imageURL: url)
            newImageURL = ""
            await reloadItem(using: apiClient, userId: userId)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deletePendingImage(using apiClient: any APIClientProtocol, userId: String) async -> Bool {
        guard let id = item.id, let pending = pendingImageDelete else { return false }
        errorMessage = nil
        do {
            try await apiClient.deleteItemImage(id: id, type: pending.type, index: pending.index)
            pendingImageDelete = nil
            await reloadItem(using: apiClient, userId: userId)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Cast

    func upsertPerson(_ person: BaseItemPerson) {
        var people = item.people ?? []
        if let id = person.id, let idx = people.firstIndex(where: { $0.id == id }) {
            people[idx] = person
        } else {
            people.append(person)
        }
        item.people = people
    }

    func deletePerson(at index: Int) {
        guard var people = item.people, people.indices.contains(index) else { return }
        people.remove(at: index)
        item.people = people.isEmpty ? nil : people
    }

    // MARK: - Identify

    /// Dispatches to the right remote-search endpoint based on the item's
    /// kind. Only movies and series are supported in P3b — other kinds
    /// get a friendly "not supported" error so the UI can degrade cleanly.
    func runIdentifySearch(using apiClient: any APIClientProtocol) async {
        guard let id = item.id else { return }
        isSearchingIdentify = true
        errorMessage = nil
        defer { isSearchingIdentify = false }
        let year = Int(identifyYear.trimmingCharacters(in: .whitespaces))
        do {
            switch item.type {
            case .movie:
                var info = MovieInfo()
                info.name = identifyName
                info.year = year
                let query = MovieInfoRemoteSearchQuery(itemID: id, searchInfo: info)
                identifyResults = try await apiClient.searchRemoteMovies(query: query)
            case .series:
                var info = SeriesInfo()
                info.name = identifyName
                info.year = year
                let query = SeriesInfoRemoteSearchQuery(itemID: id, searchInfo: info)
                identifyResults = try await apiClient.searchRemoteSeries(query: query)
            default:
                identifyResults = []
                errorMessage = "Identify isn't supported for this item kind"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyIdentifyResult(using apiClient: any APIClientProtocol, userId: String) async -> Bool {
        guard let id = item.id, let result = pendingIdentifyApply else { return false }
        errorMessage = nil
        do {
            try await apiClient.applyRemoteSearchResult(
                itemId: id,
                result: result,
                replaceAllImages: identifyReplaceAllImages
            )
            pendingIdentifyApply = nil
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
            await reloadItem(using: apiClient, userId: userId)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Actions

    func refreshMetadata(using apiClient: any APIClientProtocol) async -> Bool {
        guard let id = item.id else { return false }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        do {
            try await apiClient.refreshItem(
                id: id,
                metadataMode: refreshMetadataMode,
                imageMode: refreshImageMode,
                replaceAllMetadata: refreshReplaceAllMetadata,
                replaceAllImages: refreshReplaceAllImages
            )
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteItem(using apiClient: any APIClientProtocol) async -> Bool {
        guard let id = item.id else { return false }
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            try await apiClient.deleteItem(id: id)
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Helpers

    /// Re-fetches the item after a server-side mutation (image download,
    /// identify apply, etc.) so the editor reflects the fresh DTO —
    /// including refreshed image tags that bust `CinemaLazyImage`'s cache.
    /// Caller threads `userId` through since the VM doesn't own AppState.
    private func reloadItem(using apiClient: any APIClientProtocol, userId: String) async {
        guard let id = item.id else { return }
        if let fresh = try? await apiClient.getItem(userId: userId, itemId: id) {
            self.item = fresh
            self.original = fresh
        }
    }
}
#endif
