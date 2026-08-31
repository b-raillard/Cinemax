#if os(iOS)
import Testing
import Foundation
@preconcurrency import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// Changing a poster must not cost the user a synopsis they were still typing.
///
/// The three image paths re-fetch the item to pick up the refreshed image tags
/// (they bust `CinemaLazyImage`'s URL-keyed cache). Taking the whole fresh DTO
/// overwrote `original` as well, so `isDirty` fell back to false and a pending
/// General/Cast edit was dropped **in silence** — no prompt, and
/// `interactiveDismissDisabled(isDirty)` no longer guarding the sheet either.
/// Pre-existing, but the artwork picker made it the ordinary path.
@MainActor
@Suite("Metadata editor — image reload preserves unsaved edits")
struct MetadataEditorEditPreservationTests {

    private func seed() -> BaseItemDto {
        var item = BaseItemDto()
        item.id = "item-1"
        item.name = "Desert Warrior"
        item.overview = "Ancienne synopsis"
        item.imageTags = ["Primary": "old-tag"]
        item.primaryImageAspectRatio = 0.666
        return item
    }

    /// What the server returns after the artwork changed: new tags, and the
    /// metadata the user has NOT saved yet still at its old value.
    private func serverAfterImageChange() -> BaseItemDto {
        var fresh = seed()
        fresh.imageTags = ["Primary": "new-tag"]
        fresh.backdropImageTags = ["new-backdrop"]
        fresh.primaryImageAspectRatio = 1.777
        return fresh
    }

    private func makeViewModel(fresh: BaseItemDto) -> (MetadataEditorViewModel, MockAPIClient) {
        let mock = MockAPIClient()
        mock.getItemHandler = { @Sendable _ in fresh }
        return (MetadataEditorViewModel(item: seed()), mock)
    }

    @Test("applying artwork keeps a pending overview edit and picks up the new tags")
    func applyRemoteImageKeepsEdits() async {
        let (viewModel, mock) = makeViewModel(fresh: serverAfterImageChange())
        viewModel.item.overview = "Ma nouvelle synopsis, pas encore enregistrée"
        #expect(viewModel.isDirty)

        let ok = await viewModel.applyRemoteImage(
            RemoteImageCandidate(url: "https://images.example.com/poster.jpg"),
            using: mock, userId: "u1", loc: LocalizationManager()
        )

        #expect(ok)
        #expect(viewModel.item.overview == "Ma nouvelle synopsis, pas encore enregistrée")
        #expect(viewModel.item.imageTags?["Primary"] == "new-tag")
        #expect(viewModel.item.backdropImageTags == ["new-backdrop"])
        #expect(viewModel.item.primaryImageAspectRatio == 1.777)
        // Still dirty — the overview edit is genuinely unsaved.
        #expect(viewModel.isDirty)
    }

    @Test("the refreshed tags are not themselves counted as unsaved changes")
    func imageTagsDoNotDirtyTheEditor() async {
        let (viewModel, mock) = makeViewModel(fresh: serverAfterImageChange())
        viewModel.item.overview = "Édition en cours"

        _ = await viewModel.applyRemoteImage(
            RemoteImageCandidate(url: "https://images.example.com/poster.jpg"),
            using: mock, userId: "u1", loc: LocalizationManager()
        )
        // The user reverts their own edit by hand. Nothing of theirs is left,
        // so the editor must stop claiming unsaved changes — it would not if
        // the new tags had been spliced into `item` alone.
        viewModel.item.overview = "Ancienne synopsis"

        #expect(!viewModel.isDirty)
    }

    @Test("a clean editor still takes the whole fresh DTO, exactly as before")
    func cleanEditorTakesEverything() async {
        var fresh = serverAfterImageChange()
        fresh.overview = "Synopsis réécrite côté serveur"
        let (viewModel, mock) = makeViewModel(fresh: fresh)
        #expect(!viewModel.isDirty)

        _ = await viewModel.applyRemoteImage(
            RemoteImageCandidate(url: "https://images.example.com/poster.jpg"),
            using: mock, userId: "u1", loc: LocalizationManager()
        )

        #expect(viewModel.item.overview == "Synopsis réécrite côté serveur")
        #expect(!viewModel.isDirty)
    }

    @Test("adding artwork by URL and deleting artwork preserve edits too")
    func otherImagePathsPreserveEdits() async {
        let (byURL, mockA) = makeViewModel(fresh: serverAfterImageChange())
        byURL.item.overview = "Édition A"
        byURL.newImageURL = "https://images.example.com/poster.jpg"
        _ = await byURL.addImageFromURL(using: mockA, userId: "u1", loc: LocalizationManager())
        #expect(byURL.item.overview == "Édition A")
        #expect(byURL.item.imageTags?["Primary"] == "new-tag")

        let (delete, mockB) = makeViewModel(fresh: serverAfterImageChange())
        delete.item.overview = "Édition B"
        delete.pendingImageDelete = (type: .primary, index: nil)
        _ = await delete.deletePendingImage(using: mockB, userId: "u1", loc: LocalizationManager())
        #expect(delete.item.overview == "Édition B")
        #expect(delete.item.imageTags?["Primary"] == "new-tag")
    }

    @Test("Identify still replaces everything — it is the user asking for exactly that")
    func identifyStillTakesTheWholeDTO() async {
        var fresh = seed()
        fresh.name = "Titre corrigé par le fournisseur"
        fresh.overview = "Synopsis du fournisseur"
        let (viewModel, mock) = makeViewModel(fresh: fresh)
        viewModel.item.overview = "Édition qui décrit l'identification abandonnée"
        viewModel.pendingIdentifyApply = RemoteSearchResult(
            name: "Desert Warrior", providerIDs: ["Tmdb": "898704"], searchProviderName: "TheMovieDb"
        )
        viewModel.identify.replaceAllImages = false

        let ok = await viewModel.applyIdentifyResult(using: mock, userId: "u1", loc: LocalizationManager())

        #expect(ok)
        #expect(viewModel.item.name == "Titre corrigé par le fournisseur")
        #expect(viewModel.item.overview == "Synopsis du fournisseur")
        #expect(!viewModel.isDirty)
    }

    @Test("the splice copies image fields and leaves everything else alone")
    func spliceIsScoped() {
        var base = seed()
        base.overview = "Conservée"
        base.people = [BaseItemPerson(name: "Anthony Mackie")]

        var fresh = BaseItemDto()
        fresh.name = "Autre titre"
        fresh.overview = "Écrasée"
        fresh.imageTags = ["Primary": "new-tag"]
        fresh.backdropImageTags = ["b1"]
        fresh.primaryImageAspectRatio = 1.5

        let out = MetadataEditorViewModel.splicingImageFields(of: fresh, into: base)

        #expect(out.overview == "Conservée")
        #expect(out.name == "Desert Warrior")
        #expect(out.people?.count == 1)
        #expect(out.imageTags?["Primary"] == "new-tag")
        #expect(out.backdropImageTags == ["b1"])
        #expect(out.primaryImageAspectRatio == 1.5)
    }
}
#endif
