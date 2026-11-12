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
        WhatsNewPage(id: id, illustration: .playOn)
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

    /// Une offre nomme une saison du catalogue : une faute de frappe rendrait
    /// le bouton « Activer » muet.
    @Test("Chaque offre du catalogue livré nomme une saison qui existe")
    func shippedOffersNameRealSeasons() {
        let offers = WhatsNewCatalogue.releases.flatMap(\.pages).compactMap(\.offer)
        #expect(!offers.isEmpty)
        for case .seasonalTheme(let id) in offers {
            #expect(SeasonalThemeCatalogue.theme(id: id) != nil)
        }
    }
}

@Suite("Offre « Activer » d'une saison")
struct SeasonalOfferTests {
    private var paris: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test("Avant la saison, l'activation annonce sa date de début")
    func beforeSeasonAnnouncesStart() {
        let start = SeasonalOffer.startsLater(SeasonalThemeCatalogue.halloween, on: date("2026-09-29T10:00:00Z"), calendar: paris)
        #expect(start == MonthDay(month: 10, day: 1))
    }

    @Test("En saison, rien à annoncer : l'app change sous les yeux")
    func inSeasonNothingToAnnounce() {
        #expect(SeasonalOffer.startsLater(SeasonalThemeCatalogue.halloween, on: date("2026-10-20T10:00:00Z"), calendar: paris) == nil)
    }

    @Test("Après la saison, l'activation vaut pour la prochaine")
    func afterSeasonAnnouncesNextStart() {
        let start = SeasonalOffer.startsLater(SeasonalThemeCatalogue.halloween, on: date("2026-12-10T10:00:00Z"), calendar: paris)
        #expect(start == MonthDay(month: 10, day: 1))
    }
}

/// La page « langue » de la 2.3.1 : proposée seulement à qui a quelque chose à
/// y gagner, et jamais vide.
@Suite("Offre de langue dans « Quoi de neuf »")
struct WhatsNewLanguageOfferTests {
    private let languagePage = WhatsNewPage(id: "language", illustration: .language, offer: .deviceLanguage)
    private let plainPage = WhatsNewPage(id: "other", illustration: .playlists)

    @Test("Appareil en allemand, app en français : la page propose l'allemand")
    func offersDeviceLanguage() {
        let pages = WhatsNewCatalogue.resolvingOffers(
            [languagePage, plainPage], appLanguage: "fr", preferredLanguages: ["de-CH", "fr-CH"]
        )
        #expect(pages.map(\.id) == ["language", "other"])
        #expect(pages.first?.offer == .appLanguage(code: "de"))
    }

    @Test("Rien à proposer : même langue, ou langue que l'app ne parle pas", arguments: [
        (app: "fr", device: ["fr-FR"]),
        (app: "de", device: ["de-DE"]),
        (app: "fr", device: ["it-IT", "es-ES"])
    ])
    func dropsPageWhenNothingToOffer(app: String, device: [String]) {
        let pages = WhatsNewCatalogue.resolvingOffers(
            [languagePage, plainPage], appLanguage: app, preferredLanguages: device
        )
        #expect(pages.map(\.id) == ["other"])
    }

    @Test("Une version dont la seule page tombe se tamponne en silence")
    func droppedOnlyPageIsSilentStamp() {
        let catalogue = [WhatsNewRelease(version: ServerVersion(2, 3, 1), pages: [languagePage])]
        let outcome = WhatsNewPolicy.decide(
            lastSeenVersion: "2.3.0", installed: ServerVersion(2, 3, 1), isFirstRun: false, catalogue: catalogue,
            resolve: { WhatsNewCatalogue.resolvingOffers($0, appLanguage: "fr", preferredLanguages: ["fr-FR"]) }
        )
        #expect(outcome == .stampOnly)
    }

    @Test("Une page réservée à l'autre plateforme n'apparaît pas")
    func otherPlatformPageExcluded() {
        let catalogue = [WhatsNewRelease(version: ServerVersion(2, 4, 0), pages: [
            WhatsNewPage(id: "both", illustration: .playOn),
            WhatsNewPage(id: "tvOnly", illustration: .playOn, platforms: [.tvOS]),
            WhatsNewPage(id: "iosOnly", illustration: .playOn, platforms: [.iOS])
        ])]
        #expect(WhatsNewCatalogue.pages(since: nil, upTo: ServerVersion(2, 4, 0), in: catalogue, platform: .iOS).map(\.id)
                == ["both", "iosOnly"])
        #expect(WhatsNewCatalogue.pages(since: nil, upTo: ServerVersion(2, 4, 0), in: catalogue, platform: .tvOS).map(\.id)
                == ["both", "tvOnly"])
        #expect(WhatsNewCatalogue.allPages(in: catalogue, platform: .tvOS).map(\.id) == ["both", "tvOnly"])
    }

    @Test("Une version dont les seules pages sont pour l'autre plateforme se tamponne en silence")
    func otherPlatformOnlyIsSilentStamp() {
        let other: WhatsNewPlatform = WhatsNewPlatform.current == .iOS ? .tvOS : .iOS
        let catalogue = [WhatsNewRelease(version: ServerVersion(2, 4, 0), pages: [
            WhatsNewPage(id: "elsewhere", illustration: .playOn, platforms: [other])
        ])]
        let outcome = WhatsNewPolicy.decide(
            lastSeenVersion: "2.3.5", installed: ServerVersion(2, 4, 0), isFirstRun: false, catalogue: catalogue)
        #expect(outcome == .stampOnly)
    }

    @Test("Une page à variante Duo lit sa variante « other » hors de l'iPhone Duo")
    func duoVariantKey() {
        let page = WhatsNewPage(id: "tableMode", illustration: .playOn, hasDuoVariant: true)
        #expect(page.textKey(onDuo: true) == "tableMode")
        #expect(page.textKey(onDuo: false) == "tableMode.other")
        #expect(WhatsNewPage(id: "plain", illustration: .playOn).textKey(onDuo: false) == "plain")
    }

    @Test("La 2.4.0 : le Duo et la vitesse sur iOS, la compatibilité Duo et la vitesse sur Apple TV")
    func shipped240() {
        let since = ServerVersion(2, 3, 5), installed = ServerVersion(2, 4, 0)
        #expect(WhatsNewCatalogue.pages(since: since, upTo: installed, platform: .iOS).map(\.id)
                == ["tableMode", "everyScreen", "smoothSpeed"])
        #expect(WhatsNewCatalogue.pages(since: since, upTo: installed, platform: .tvOS).map(\.id)
                == ["duoOnTV", "smoothSpeed"])
    }

    @Test("Chaque page livrée a son titre et son texte dans chaque langue, variante Duo comprise")
    func shippedPagesLocalized() {
        let keys = WhatsNewCatalogue.releases.flatMap(\.pages).flatMap { page in
            page.hasDuoVariant ? [page.textKey(onDuo: true), page.textKey(onDuo: false)] : [page.id]
        }
        for code in AppLanguage.supported {
            let bundle = Bundle.localizedBundle(for: code)
            for key in keys {
                for part in ["title", "body"] {
                    let full = "whatsNew.\(key).\(part)"
                    #expect(bundle.localizedString(forKey: full, value: nil, table: nil) != full, "\(code) \(full)")
                }
            }
        }
    }

    @Test("La page est livrée en 2.3.1, avec son titre dans chaque langue")
    func shippedPageExists() throws {
        let page = try #require(WhatsNewCatalogue.releases.flatMap(\.pages).first { $0.id == "language" })
        #expect(page.offer == .deviceLanguage)
        for code in AppLanguage.supported {
            let title = Bundle.localizedBundle(for: code)
                .localizedString(forKey: "whatsNew.language.title", value: nil, table: nil)
            #expect(title != "whatsNew.language.title", "\(code)")
        }
    }
}

#if canImport(QuartzCore)
import QuartzCore

/// The drawn iPhone Duo of « Quoi de neuf » and the onboarding: the timings and
/// the 3-D projection are the approved mockup's (2026-10-08), so they are
/// locked here rather than trusted to a reading of the animation.
@Suite("Animation du Duo plié")
struct DuoFoldTimelineTests {
    @Test("Au départ le Duo est à plat, pupitre vide, table éteinte")
    func startsFlat() {
        let pose = DuoFoldTimeline.pose(at: 0)
        #expect(pose.upper == 0)
        #expect(pose.lower == 0)
        #expect(pose.glow == 0)
        #expect(pose.tiles.allSatisfy { $0.opacity == 0 })
        #expect(pose.play.opacity == 0)
    }

    @Test("À mi-boucle il est plié sur la table, chaque bloc en place")
    func foldedMidLoop() {
        let pose = DuoFoldTimeline.pose(at: DuoFoldTimeline.period * 0.55)
        #expect(pose.upper == -9)
        #expect(pose.lower == 62)
        #expect(pose.glow == 1)
        #expect(pose.tiles.allSatisfy { $0.opacity == 1 && $0.lift == 0 })
        #expect(pose.play.opacity == 1 && pose.play.scale == 1)
        #expect(abs(pose.progress - (0.20 + 0.32 * 0.15 / 0.44)) < 0.0001)
    }

    @Test("Sans animations : plié, tout en place, barre au repos")
    func still() {
        let pose = DuoFoldTimeline.pose(at: nil)
        #expect(pose.upper == -9 && pose.lower == 62 && pose.glow == 1)
        #expect(pose.tiles.allSatisfy { $0.opacity == 1 && $0.lift == 0 })
        #expect(pose.progress == 0.38)
    }

    @Test("Les blocs arrivent l'un après l'autre, 0,07 s d'écart")
    func staggered() {
        let pose = DuoFoldTimeline.pose(at: DuoFoldTimeline.period * 0.38)
        #expect(pose.tiles[0].opacity > pose.tiles[5].opacity)
        #expect(pose.tiles[5].opacity > pose.tiles[10].opacity)
    }

    @Test("La charnière ne se disjoint jamais : les deux moitiés s'y rejoignent", arguments: [0.0, 0.2, 0.3, 0.5, 0.9])
    func hingeStaysJoined(_ fraction: Double) {
        let pose = DuoFoldTimeline.pose(at: DuoFoldTimeline.period * fraction)
        let w: CGFloat = 100, h = w * DuoFoldProjection.halfRatio
        for x in [CGFloat(0), w / 2, w] {
            let top = DuoFoldProjection.project(CGPoint(x: x, y: h), half: .upper, angle: pose.upper, width: w)
            let bottom = DuoFoldProjection.project(CGPoint(x: x, y: 0), half: .lower, angle: pose.lower, width: w)
            #expect(abs(top.x - bottom.x) < 0.01 && abs(top.y - (bottom.y + h)) < 0.01, "x=\(x)")
        }
    }

    @Test("Plié, la moitié basse se couche : plus courte, plus large au bord proche")
    func lowerHalfLiesDown() {
        let w: CGFloat = 100, h = w * DuoFoldProjection.halfRatio
        let nearLeft = DuoFoldProjection.project(CGPoint(x: 0, y: h), half: .lower, angle: 62, width: w)
        let nearRight = DuoFoldProjection.project(CGPoint(x: w, y: h), half: .lower, angle: 62, width: w)
        let farLeft = DuoFoldProjection.project(CGPoint(x: 0, y: 0), half: .lower, angle: 62, width: w)
        let farRight = DuoFoldProjection.project(CGPoint(x: w, y: 0), half: .lower, angle: 62, width: w)
        #expect(nearLeft.y - farLeft.y < h * 0.9)
        #expect(nearRight.x - nearLeft.x > farRight.x - farLeft.x)
    }
}
#endif

/// The 2.6.0 reel and its four animated motifs: the order is the owner's
/// (2026-11-12), the timings the approved mockup's.
@Suite("Nouveautés 2.6.0")
struct WhatsNew260Tests {
    @Test("La 2.6.0 : adresse locale, qualité, demandes, épisodes manquants, sur les deux apps", arguments: [WhatsNewPlatform.iOS, .tvOS])
    func shipped260(platform: WhatsNewPlatform) {
        let pages = WhatsNewCatalogue.pages(since: ServerVersion(2, 5, 0), upTo: ServerVersion(2, 6, 0), platform: platform)
        #expect(pages.map(\.id) == ["localAddress", "episodeQuality", "seerrRequests", "missingEpisodes"])
    }

    @Test("Sans animations, chaque dessin est le dessin fixe")
    func restIsStaticDrawing() {
        #expect(MotifMotion.request(at: nil) == MotifMotion.Request())
        #expect(MotifMotion.missing(at: nil) == MotifMotion.Missing())
        #expect(MotifMotion.home(at: nil) == MotifMotion.Home())
        #expect(MotifMotion.tags(at: nil).allSatisfy { $0 == MotifMotion.Layer() })
        let rest = MotifMotion.request(at: nil)
        #expect(rest.typed == 1 && rest.poster.opacity == 1 && rest.pill.opacity == 1 && rest.ping.opacity == 1)
    }

    @Test("Au départ, la recherche est vide et rien n'est encore trouvé")
    func requestStartsEmpty() {
        let start = MotifMotion.request(at: 0)
        #expect(start.typed == 0)
        #expect(start.poster.opacity == 0)
        #expect(start.pill.opacity == 0)
        #expect(start.ping.opacity == 0)
        let end = MotifMotion.request(at: MotifMotion.requestPeriod * 0.95)
        #expect(end.typed == 1 && end.poster.opacity == 1 && end.pill.opacity == 1 && end.ping.opacity == 1)
    }

    @Test("La pastille « Demander » s'enfonce après être apparue")
    func requestPillIsPressed() {
        let pressed = MotifMotion.request(at: MotifMotion.requestPeriod * 0.68)
        #expect(abs(pressed.pill.scale - 0.92) < 0.001)
    }

    @Test("L'épisode manquant apparaît avant la pastille, qui arrive de la droite")
    func missingOrder() {
        let mid = MotifMotion.missing(at: MotifMotion.missingPeriod * 0.31)
        #expect(mid.row == 1)
        #expect(mid.pill.opacity == 0)
        #expect(mid.pill.dx == 11.4)
        let placed = MotifMotion.missing(at: MotifMotion.missingPeriod * 0.5)
        #expect(placed.pill.dx == 0 && placed.pill.opacity == 1)
    }

    @Test("Les pastilles de qualité arrivent l'une après l'autre")
    func tagsStagger() {
        let tags = MotifMotion.tags(at: 0.2 * MotifMotion.tagPeriod)
        #expect(tags[0].opacity > tags[1].opacity)
        #expect(tags[1].opacity > tags[2].opacity)
        #expect(MotifMotion.tags(at: 0.1).allSatisfy { $0.opacity == 0 })
    }

    @Test("Avant son départ, un point retardé reste sur sa première image")
    func delayedDotWaits() {
        let home = MotifMotion.home(at: 0.1)
        #expect(home.hops[1].opacity == 0.25)
        #expect(home.hops[0].opacity > 0.25)
        #expect(home.led == 1)
    }
}
