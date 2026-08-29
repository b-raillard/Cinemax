#if os(iOS)
import Testing
import Foundation
@preconcurrency import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// The remote-artwork picker is a sheet the user can swipe away mid-request,
/// and the slot it was opened for (`pendingImageType`) moves with it. Every
/// test here holds that window open with an explicit barrier: it is a network
/// round-trip wide, so it is not reachable by gesture automation — the same
/// reason `PaginatedLoaderInterlockTests` exists.
///
/// What makes a stale write dangerous rather than merely untidy: the tap that
/// follows sends `pendingImageType` to `downloadRemoteImage`, so a poster list
/// left rendered under a Backdrop sheet puts a 2:3 poster in the backdrop slot
/// — stretched across every hero in the app — and toasts success.
@MainActor
@Suite("Remote image picker — generation guard")
struct MetadataRemoteImagePickerTests {

    /// Holds one `getRemoteImages` suspended so the race window is kept open
    /// rather than guessed at.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func makeItem() -> BaseItemDto {
        var item = BaseItemDto()
        item.id = "item-1"
        item.name = "Desert Warrior"
        return item
    }

    private func candidate(_ url: String) -> RemoteImageCandidate {
        RemoteImageCandidate(url: url)
    }

    @Test("a load superseded by reopening on another slot writes nothing")
    func supersededLoadIsDiscarded() async {
        let mock = MockAPIClient()
        let gate = Gate()
        mock.remoteImagesGate = { @Sendable in await gate.wait() }
        mock.stubbedRemoteImages = [candidate("poster")]

        let viewModel = MetadataEditorViewModel(item: makeItem())
        viewModel.prepareRemoteImagePicker(for: .primary)

        let inFlight = Task {
            await viewModel.loadRemoteImages(using: mock, preferredLanguage: "fr", loc: LocalizationManager())
        }
        // Let the load reach the barrier before superseding it.
        await Task.yield()

        // The user swiped the sheet away and opened the Backdrop slot.
        viewModel.prepareRemoteImagePicker(for: .backdrop)
        gate.open()
        await inFlight.value

        #expect(viewModel.remoteImages.isEmpty)
        #expect(viewModel.pendingImageType == .backdrop)
        #expect(!viewModel.isLoadingRemoteImages)
    }

    @Test("a superseded FAILURE leaves no error over the new presentation")
    func supersededFailureIsSilent() async {
        let mock = MockAPIClient()
        let gate = Gate()
        mock.remoteImagesGate = { @Sendable in await gate.wait() }
        mock.shouldThrow = true

        let viewModel = MetadataEditorViewModel(item: makeItem())
        viewModel.prepareRemoteImagePicker(for: .primary)

        let inFlight = Task {
            await viewModel.loadRemoteImages(using: mock, preferredLanguage: "fr", loc: LocalizationManager())
        }
        await Task.yield()

        viewModel.prepareRemoteImagePicker(for: .backdrop)
        gate.open()
        await inFlight.value

        #expect(viewModel.remoteImagesError == nil)
    }

    @Test("an un-superseded failure still surfaces — the guard must not swallow real errors")
    func liveFailureStillSurfaces() async {
        let mock = MockAPIClient()
        mock.shouldThrow = true

        let viewModel = MetadataEditorViewModel(item: makeItem())
        viewModel.prepareRemoteImagePicker(for: .primary)
        await viewModel.loadRemoteImages(using: mock, preferredLanguage: "fr", loc: LocalizationManager())

        #expect(viewModel.remoteImagesError != nil)
        #expect(viewModel.remoteImages.isEmpty)
        #expect(!viewModel.isLoadingRemoteImages)
    }

    @Test("a live load populates and ranks")
    func liveLoadPopulates() async {
        let mock = MockAPIClient()
        mock.stubbedRemoteImages = [candidate("a"), candidate("b")]

        let viewModel = MetadataEditorViewModel(item: makeItem())
        viewModel.prepareRemoteImagePicker(for: .primary)
        await viewModel.loadRemoteImages(using: mock, preferredLanguage: "fr", loc: LocalizationManager())

        #expect(viewModel.remoteImages.count == 2)
        #expect(!viewModel.isLoadingRemoteImages)
    }

    @Test("reopening the picker clears an in-flight apply's lock")
    func prepareClearsApplyingLock() {
        let viewModel = MetadataEditorViewModel(item: makeItem())
        viewModel.applyingImageURL = "https://example.com/in-flight.jpg"
        viewModel.remoteImages = [candidate("stale")]
        viewModel.remoteImagesError = "boom"

        viewModel.prepareRemoteImagePicker(for: .backdrop)

        // Left set, every tile of the NEXT sheet renders `.disabled` with no
        // spinner and no error — a fully populated grid that ignores taps.
        #expect(viewModel.applyingImageURL == nil)
        #expect(viewModel.remoteImages.isEmpty)
        #expect(viewModel.remoteImagesError == nil)
    }
}
#endif
