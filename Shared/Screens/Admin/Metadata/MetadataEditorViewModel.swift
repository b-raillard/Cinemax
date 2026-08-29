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

    /// True while the initial full-DTO reload (`loadFullItemIfNeeded`) is in
    /// flight. The item this VM is seeded with may come from a narrowed
    /// `getItems` list fetch (`MetadataBrowserScreen`'s grid,
    /// `AdminItemMenu`'s poster-card entry) that omits `people`/`studios`/
    /// other ItemFields — using it directly in `save()` would silently wipe
    /// those fields server-side (`updateItem` POSTs the whole DTO). The
    /// screen gates the form on this flag (and `fullItemLoadFailed`) so no
    /// edit/save can happen against the narrow DTO.
    var isLoadingFullItem = true
    /// True when the full-DTO fetch failed. The screen keeps the form gated
    /// and shows a retry affordance instead — opening the form on the narrow
    /// seed would re-expose the server-side field-wipe edge above.
    var fullItemLoadFailed = false
    private var hasLoadedFullItem = false

    // Images
    var showAddImageSheet = false
    var pendingImageType: JellyfinAPI.ImageType = .primary
    var newImageURL: String = ""

    // Remote-artwork picker. `applyingImageURL` doubles as the in-flight guard
    // and as the per-tile spinner's identity, so a second tap while a download
    // is in flight is a no-op rather than a competing request.
    var showBrowseImagesSheet = false
    var remoteImages: [RemoteImageCandidate] = []
    var isLoadingRemoteImages = false
    var remoteImagesError: String?
    var applyingImageURL: String?

    /// Enough to scroll through without paginating. The server ranks nothing —
    /// `RemoteImageCatalog` does — so a bounded page is only ever a display
    /// choice, never a correctness one.
    private let remoteImageLimit = 60

    /// Bumped by every picker presentation and by each load/apply, and
    /// re-checked after every await — the `MediaDetailViewModel.loadGeneration`
    /// pattern. The picker is a sheet the user can swipe away mid-request, and
    /// the slot it was opened for (`pendingImageType`) changes with it, so
    /// without this a superseded response writes its artwork into the state a
    /// LATER presentation is showing: a poster list rendered under a Backdrop
    /// sheet, whose next tap sends a 2:3 poster to the backdrop slot and toasts
    /// success. Guarding on `pendingImageType` alone is not enough — reopening
    /// the same slot twice must also discard the first pass.
    private var remoteImagesGeneration = 0
    var pendingImageDelete: (type: JellyfinAPI.ImageType, index: Int?)?

    // Cast
    var editingPerson: BaseItemPerson?

    // Identify — full flow state lives on the shared `IdentifyFlowModel` so
    // the standalone `IdentifyScreen` and this tab stay feature-identical.
    // `pendingIdentifyApply` is kept here because the tab uses a bottom sheet
    // for the confirm step (instead of the wizard's step transition), which
    // is a rendering choice local to the editor context.
    var identify: IdentifyFlowModel
    var pendingIdentifyApply: RemoteSearchResult?

    // Actions
    var refreshMetadataMode: MetadataRefreshMode = .default
    var refreshImageMode: MetadataRefreshMode = .default
    var refreshReplaceAllMetadata: Bool = false
    var refreshReplaceAllImages: Bool = false
    var showDeleteConfirm = false

    init(item: BaseItemDto) {
        self.item = item
        self.original = item
        self.identify = IdentifyFlowModel(item: item)
    }

    var isDirty: Bool { item != original }

    // MARK: - Load

    /// Self-heals a narrowed seed item by re-fetching the full DTO via
    /// `getItem` once on screen appearance. Mirrors
    /// `IdentifyFlowModel.loadPathIfNeeded`'s pattern. Latches only on
    /// success: a fetch failure sets `fullItemLoadFailed` (the screen stays
    /// gated with a retry) and the next call — re-fired `.task` or the retry
    /// button — tries again.
    func loadFullItemIfNeeded(using apiClient: any APIClientProtocol, userId: String) async {
        guard !hasLoadedFullItem, let id = item.id else {
            isLoadingFullItem = false
            return
        }
        isLoadingFullItem = true
        fullItemLoadFailed = false
        defer { isLoadingFullItem = false }
        do {
            let fresh = try await apiClient.getItem(userId: userId, itemId: id)
            item = fresh
            original = fresh
            identify = IdentifyFlowModel(item: fresh)
            hasLoadedFullItem = true
        } catch {
            fullItemLoadFailed = true
        }
    }

    // MARK: - Save

    func save(using apiClient: any APIClientProtocol, loc: LocalizationManager) async -> Bool {
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
            errorMessage = loc.userFacingMessage(for: error)
            return false
        }
    }

    // MARK: - Images

    func addImageFromURL(using apiClient: any APIClientProtocol, userId: String, loc: LocalizationManager) async -> Bool {
        guard let id = item.id else { return false }
        let url = newImageURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, URL(string: url) != nil else {
            errorMessage = loc.localized("admin.metadata.images.invalidURL")
            return false
        }
        errorMessage = nil
        do {
            try await apiClient.downloadRemoteImage(itemId: id, type: pendingImageType, imageURL: url)
            newImageURL = ""
            await reloadItem(using: apiClient, userId: userId)
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
            return true
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
            return false
        }
    }

    func deletePendingImage(using apiClient: any APIClientProtocol, userId: String, loc: LocalizationManager) async -> Bool {
        guard let id = item.id, let pending = pendingImageDelete else { return false }
        errorMessage = nil
        do {
            try await apiClient.deleteItemImage(id: id, type: pending.type, index: pending.index)
            pendingImageDelete = nil
            await reloadItem(using: apiClient, userId: userId)
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
            return true
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
            return false
        }
    }

    /// Loads what the metadata providers offer for `pendingImageType`.
    ///
    /// Asks for **all languages** deliberately: the point of the picker is
    /// choice, and `RemoteImageCatalog` already floats the user's language to
    /// the top, so filtering server-side would only hide options without
    /// improving the order.
    /// Single entry point for opening the picker on a slot. Bumps the
    /// generation, so anything still in flight from a previous presentation
    /// lands on a stale token and writes nothing — including `applyingImageURL`,
    /// which otherwise stays set for the rest of the in-flight download and
    /// leaves the NEXT sheet rendered but entirely un-tappable, with no spinner
    /// and no error to explain it.
    func prepareRemoteImagePicker(for type: JellyfinAPI.ImageType) {
        remoteImagesGeneration += 1
        pendingImageType = type
        remoteImages = []
        remoteImagesError = nil
        applyingImageURL = nil
        isLoadingRemoteImages = false
    }

    func loadRemoteImages(
        using apiClient: any APIClientProtocol,
        preferredLanguage: String?,
        loc: LocalizationManager
    ) async {
        guard let id = item.id else { return }
        remoteImagesGeneration += 1
        let generation = remoteImagesGeneration
        let requestedType = pendingImageType
        isLoadingRemoteImages = true
        remoteImagesError = nil
        do {
            let images = try await apiClient.getRemoteImages(
                itemId: id,
                type: requestedType,
                includeAllLanguages: true,
                limit: remoteImageLimit,
                preferredLanguage: preferredLanguage
            )
            guard remoteImagesGeneration == generation else { return }
            remoteImages = images
            isLoadingRemoteImages = false
        } catch {
            guard remoteImagesGeneration == generation else { return }
            // A dismissal cancels the `.task`, and the cancellation surfaces as
            // `URLError.cancelled` — which `userFacingMessage` would render as a
            // generic failure over a screen the user already left. Same rule as
            // Quick Connect's poll loop.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                isLoadingRemoteImages = false
                return
            }
            remoteImages = []
            remoteImagesError = loc.userFacingMessage(for: error)
            isLoadingRemoteImages = false
        }
    }

    /// Applies one candidate. The server fetches the bytes itself
    /// (`downloadRemoteImage`), so nothing is proxied through the phone.
    func applyRemoteImage(
        _ candidate: RemoteImageCandidate,
        using apiClient: any APIClientProtocol,
        userId: String,
        loc: LocalizationManager
    ) async -> Bool {
        guard let id = item.id, applyingImageURL == nil else { return false }
        remoteImagesGeneration += 1
        let generation = remoteImagesGeneration
        // Captured, not re-read after the await: `pendingImageType` moves the
        // moment another slot's picker opens, and the download must describe the
        // slot the user actually tapped in.
        let requestedType = pendingImageType
        applyingImageURL = candidate.url
        errorMessage = nil
        defer { if remoteImagesGeneration == generation { applyingImageURL = nil } }
        do {
            try await apiClient.downloadRemoteImage(itemId: id, type: requestedType, imageURL: candidate.url)
            // A superseded apply returns `false` WITHOUT setting `errorMessage`,
            // so the picker neither toasts nor dismisses a sheet it no longer owns.
            guard remoteImagesGeneration == generation else { return false }
            await reloadItem(using: apiClient, userId: userId)
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
            return true
        } catch {
            guard remoteImagesGeneration == generation else { return false }
            errorMessage = loc.userFacingMessage(for: error)
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

    /// Delegates to the shared `IdentifyFlowModel`. Kept as a pass-through
    /// so existing tab callers don't have to know about the nested model.
    func runIdentifySearch(using apiClient: any APIClientProtocol, loc: LocalizationManager) async {
        await identify.runSearch(using: apiClient, loc: loc)
        // Mirror the flow model's error into the editor so it surfaces in
        // the same "error band" the other tabs use.
        errorMessage = identify.errorMessage
    }

    func applyIdentifyResult(using apiClient: any APIClientProtocol, userId: String, loc: LocalizationManager) async -> Bool {
        guard let result = pendingIdentifyApply else { return false }
        let ok = await identify.apply(result, using: apiClient, loc: loc)
        if ok {
            pendingIdentifyApply = nil
            await reloadItem(using: apiClient, userId: userId)
        } else {
            errorMessage = identify.errorMessage
        }
        return ok
    }

    // MARK: - Actions

    func refreshMetadata(using apiClient: any APIClientProtocol, loc: LocalizationManager) async -> Bool {
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
            errorMessage = loc.userFacingMessage(for: error)
            return false
        }
    }

    func deleteItem(using apiClient: any APIClientProtocol, loc: LocalizationManager) async -> Bool {
        guard let id = item.id else { return false }
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            try await apiClient.deleteItem(id: id)
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
            return true
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
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
