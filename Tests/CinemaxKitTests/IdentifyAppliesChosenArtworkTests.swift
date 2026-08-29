#if os(iOS)
import Testing
import Foundation
@preconcurrency import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// « Identifier » must apply the artwork the user actually pointed at.
///
/// Jellyfin's own `ApplySearchCriteria` does not: it sets the provider ids,
/// re-runs a full refresh, and the metadata providers then re-pick artwork by
/// THEIR ranking. Measured on device 2026-08-29 — the `primaryImageTag` moves
/// on every apply (the image really is re-downloaded) yet TMDb re-picks the
/// same poster each time, so choosing a different result in the list changed
/// nothing on screen. These tests lock the app-level behaviour that closes
/// that gap.
@MainActor
@Suite("Identify applies the chosen artwork")
struct IdentifyAppliesChosenArtworkTests {

    private let posterURL = "https://images.example.com/chosen-poster.jpg"

    private func makeItem() -> BaseItemDto {
        var item = BaseItemDto()
        item.id = "item-1"
        item.name = "Desert Warrior"
        item.type = .movie
        return item
    }

    private func makeResult(imageURL: String?) -> RemoteSearchResult {
        RemoteSearchResult(
            imageURL: imageURL,
            name: "Desert Warrior",
            productionYear: 2026,
            providerIDs: ["Tmdb": "898704"],
            searchProviderName: "TheMovieDb"
        )
    }

    @Test("the picked result's poster is applied as Primary")
    func chosenPosterIsPinned() async {
        let mock = MockAPIClient()
        let model = IdentifyFlowModel(item: makeItem())
        model.replaceAllImages = true

        let ok = await model.apply(makeResult(imageURL: posterURL), using: mock, loc: LocalizationManager())

        #expect(ok)
        #expect(mock.downloadedImages.count == 1)
        #expect(mock.downloadedImages.first?.imageURL == posterURL)
        #expect(mock.downloadedImages.first?.type == .primary)
        #expect(mock.downloadedImages.first?.itemId == "item-1")
    }

    @Test("unticking « Remplacer les images existantes » keeps the user's artwork untouched")
    func respectsReplaceAllImagesOff() async {
        let mock = MockAPIClient()
        let model = IdentifyFlowModel(item: makeItem())
        model.replaceAllImages = false

        let ok = await model.apply(makeResult(imageURL: posterURL), using: mock, loc: LocalizationManager())

        #expect(ok)
        // Forcing our poster here would be the exact opposite of the setting.
        #expect(mock.downloadedImages.isEmpty)
    }

    @Test("a result with no artwork applies metadata only, and still succeeds")
    func missingArtworkIsNotAFailure() async {
        let mock = MockAPIClient()
        let model = IdentifyFlowModel(item: makeItem())
        model.replaceAllImages = true

        let ok = await model.apply(makeResult(imageURL: nil), using: mock, loc: LocalizationManager())

        #expect(ok)
        #expect(mock.downloadedImages.isEmpty)
        #expect(model.errorMessage == nil)
    }

    @Test("a blank artwork url is treated as absent, never sent as an empty download")
    func blankArtworkURLIgnored() async {
        let mock = MockAPIClient()
        let model = IdentifyFlowModel(item: makeItem())
        model.replaceAllImages = true

        let ok = await model.apply(makeResult(imageURL: "   "), using: mock, loc: LocalizationManager())

        #expect(ok)
        #expect(mock.downloadedImages.isEmpty)
    }

    @Test("a failed artwork download surfaces rather than reporting a silent success")
    func artworkFailureIsReported() async {
        let mock = MockAPIClient()
        mock.shouldThrow = true
        let model = IdentifyFlowModel(item: makeItem())
        model.replaceAllImages = true

        let ok = await model.apply(makeResult(imageURL: posterURL), using: mock, loc: LocalizationManager())

        // The whole point of the flow is the image; claiming success while the
        // poster silently stayed put is the defect this feature exists to fix.
        #expect(!ok)
        #expect(model.errorMessage != nil)
    }
}
#endif
