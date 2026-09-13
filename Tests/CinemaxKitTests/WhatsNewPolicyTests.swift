import Foundation
import Testing
@testable import Cinemax
@testable import CinemaxKit

/// Qui voit « Quoi de neuf », et surtout qui ne le voit PAS. Les deux erreurs
/// coûtent : montrer à un nouvel arrivant les nouveautés d'une version qu'il
/// n'a jamais connue, ou ne jamais rien montrer à celui qui vient de mettre à
/// jour — la seule personne pour qui l'écran existe.
@Suite("Parcours « Quoi de neuf »")
struct WhatsNewPolicyTests {

    private func page(_ id: String) -> WhatsNewPage {
        WhatsNewPage(id: id, illustration: .playlists)
    }

    private func release(_ major: Int, _ minor: Int, _ ids: [String]) -> WhatsNewRelease {
        WhatsNewRelease(version: ServerVersion(major, minor, 0), pages: ids.map(page))
    }

    private var catalogue: [WhatsNewRelease] {
        [release(2, 0, ["a", "b"]), release(2, 1, ["c"])]
    }

    // MARK: - Silence

    @Test("Sans version installée lisible, on ne fait rien")
    func nothingWithoutInstalledVersion() {
        let outcome = WhatsNewPolicy.decide(
            lastSeenVersion: "1.0.0", installed: nil, isFirstRun: false, catalogue: catalogue
        )
        #expect(outcome == .nothing)
    }

    @Test("Déjà à jour : on ne fait rien")
    func nothingWhenAlreadySeen() {
        let outcome = WhatsNewPolicy.decide(
            lastSeenVersion: "2.1.0", installed: ServerVersion("2.1.0"),
            isFirstRun: false, catalogue: catalogue
        )
        #expect(outcome == .nothing)
    }

    /// Une rétrogradation ne doit rien rejouer.
    @Test("Une version vue plus récente que l'installée ne rejoue rien")
    func nothingOnDowngrade() {
        let outcome = WhatsNewPolicy.decide(
            lastSeenVersion: "2.5.0", installed: ServerVersion("2.1.0"),
            isFirstRun: false, catalogue: catalogue
        )
        #expect(outcome == .nothing)
    }

    // MARK: - Le tampon sans rien montrer

    /// La moitié facile à oublier : sans ce tampon, le lancement de la version
    /// SUIVANTE servirait au nouvel arrivant les annonces d'une version sur
    /// laquelle il a commencé.
    @Test("Un vrai premier lancement tamponne sans rien montrer")
    func firstRunStampsSilently() {
        let outcome = WhatsNewPolicy.decide(
            lastSeenVersion: nil, installed: ServerVersion("2.1.0"),
            isFirstRun: true, catalogue: catalogue
        )
        #expect(outcome == .stampOnly)
    }

    @Test("Une version sans page tamponne sans rien montrer")
    func releaseWithoutPagesStampsSilently() {
        let outcome = WhatsNewPolicy.decide(
            lastSeenVersion: "2.1.0", installed: ServerVersion("2.2.0"),
            isFirstRun: false, catalogue: catalogue
        )
        #expect(outcome == .stampOnly)
    }

    // MARK: - Montrer

    /// Une mise à jour depuis une version qui ignorait la pellicule :
    /// `lastSeenVersion` est absent, et c'est précisément le cas visé.
    @Test("Une mise à jour depuis une version sans tampon montre tout")
    func upgradeWithoutStampShowsEverything() {
        let outcome = WhatsNewPolicy.decide(
            lastSeenVersion: nil, installed: ServerVersion("2.1.0"),
            isFirstRun: false, catalogue: catalogue
        )
        #expect(outcome == .show([page("c"), page("a"), page("b")]))
    }

    @Test("Une mise à jour ne montre que ce qui est nouveau depuis la dernière vue")
    func showsOnlyWhatIsNew() {
        let outcome = WhatsNewPolicy.decide(
            lastSeenVersion: "2.0.0", installed: ServerVersion("2.1.0"),
            isFirstRun: false, catalogue: catalogue
        )
        #expect(outcome == .show([page("c")]))
    }

    @Test("Le tampon est la version INSTALLÉE, pas la plus récente du catalogue")
    func stampIsTheInstalledVersion() {
        #expect(WhatsNewPolicy.stamp(installed: ServerVersion("2.1.0")) == "2.1.0.0")
        #expect(WhatsNewPolicy.stamp(installed: nil) == nil)
    }
}

/// Le catalogue : ce qu'il retient, dans quel ordre, et ce qu'il refuse.
@Suite("Catalogue des nouveautés")
struct WhatsNewCatalogueTests {

    private func page(_ id: String) -> WhatsNewPage {
        WhatsNewPage(id: id, illustration: .subtitles)
    }

    private func release(_ major: Int, _ minor: Int, _ ids: [String]) -> WhatsNewRelease {
        WhatsNewRelease(version: ServerVersion(major, minor, 0), pages: ids.map(page))
    }

    /// Le garde-fou qui compte : une entrée écrite en préparant la version
    /// suivante — la façon ordinaire de préparer une version — ne doit pas
    /// fuiter dans la pellicule de la version courante.
    @Test("Une version plus récente que le build est exclue")
    func excludesUnreleasedEntries() {
        let catalogue = [release(2, 0, ["a"]), release(3, 0, ["futur"])]
        let pages = WhatsNewCatalogue.pages(since: nil, upTo: ServerVersion(2, 0, 0), in: catalogue)
        #expect(pages == [page("a")])
    }

    @Test("La version la plus récente vient en premier")
    func newestReleaseFirst() {
        let catalogue = [release(2, 0, ["vieux"]), release(2, 2, ["neuf"])]
        let pages = WhatsNewCatalogue.pages(since: nil, upTo: ServerVersion(2, 2, 0), in: catalogue)
        #expect(pages == [page("neuf"), page("vieux")])
    }

    /// Le plafond tombe donc sur les pages les PLUS ANCIENNES : qui a sauté
    /// trois versions veut les dernières, pas une leçon d'histoire.
    @Test("Le plafond garde les pages les plus récentes")
    func capKeepsNewestPages() {
        let catalogue = [
            release(2, 0, ["a1", "a2", "a3", "a4"]),
            release(2, 1, ["b1", "b2", "b3", "b4"])
        ]
        let pages = WhatsNewCatalogue.pages(since: nil, upTo: ServerVersion(2, 1, 0), in: catalogue)
        #expect(pages.count == WhatsNewCatalogue.maxPages)
        #expect(pages.first == page("b1"))
        #expect(!pages.contains(page("a4")))
    }

    @Test("Une borne basse exclut la version déjà vue elle-même")
    func lowerBoundIsExclusive() {
        let catalogue = [release(2, 0, ["a"]), release(2, 1, ["b"])]
        let pages = WhatsNewCatalogue.pages(
            since: ServerVersion(2, 0, 0), upTo: ServerVersion(2, 1, 0), in: catalogue
        )
        #expect(pages == [page("b")])
    }

    /// Le catalogue livré doit rester cohérent : chaque page porte un
    /// identifiant unique, puisque c'est aussi sa clé de localisation.
    @Test("Le catalogue livré n'a aucun identifiant en double")
    func shippedCatalogueHasUniqueIDs() {
        let ids = WhatsNewCatalogue.releases.flatMap(\.pages).map(\.id)
        #expect(ids.count == Set(ids).count)
        #expect(!ids.isEmpty)
    }
}
