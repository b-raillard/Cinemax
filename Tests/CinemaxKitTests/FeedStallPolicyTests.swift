import Testing
import Foundation
@testable import Cinemax

/// Verrouille `FeedStallPolicy`, le garde-fou qui surveille l'ALIMENTATION du
/// lecteur — les octets qui arrivent — et non l'image.
///
/// Mesuré sur Apple TV le 2026-09-20 sur « Just Play Dead », un MKV de 6,6 Go
/// lu en direct à travers le serveur derrière son tunnel : le serveur d'en face
/// a annulé le flux HTTP/2 en plein film (`peer stream 27 error: Cancellation
/// (0x8)` à 17 h 41 min 47, puis `peer stream 25` à 17 h 48 min 55), et libVLC
/// n'a aucune reconnexion en direct. L'image a continué sur le tampon — 18 s la
/// seconde fois — donc tous les gardes qui regardent l'image voyaient une
/// lecture saine ; le gel n'a été vu qu'une fois le tampon vide. Ce garde-fou
/// voit la coupure pendant que l'image tourne encore. Le remède dépend de la
/// voie : sur la voie DIRECTE, la bascule immédiate au relais (mesuré les 08/10
/// et 21/10 : le réancrage n'y ramenait aucun octet) ; sur la voie RELAIS, le
/// réancrage, qui ouvre une connexion locale neuve et donc une requête neuve.
///
/// Les quatre refus sont la partie délicate : une alimentation se tait aussi
/// pour de bonnes raisons (segments HLS, fichier entièrement lu, saut en cours,
/// média pas encore ouvert), et chacun coûterait un saut inutile.
@Suite("Lecteur — garde-fou d'alimentation")
struct FeedStallPolicyTests {

    /// Un flux direct sain : les octets avancent à chaque seconde.
    private func feed(
        _ policy: inout FeedStallPolicy,
        bytes: UInt64,
        size: Int64? = 8_000_000_000,
        isPlaying: Bool = true,
        adaptive: Bool = false,
        seeking: Bool = false,
        open: Bool = true,
        endReports: Int = 0,
        viaRelay: Bool = true
    ) -> FeedStallPolicy.Outcome {
        // Même ordre que `VLCStreamPresenter.checkFeedStall`. Par défaut sur la
        // voie RELAIS, la seule où le remède reste le réancrage : les refus et
        // la temporisation sont les mêmes sur les deux voies, seul le remède
        // change (voir « La voie directe » plus bas).
        policy.noteInputEnd(reports: endReports, readBytes: bytes)
        return policy.sample(
            readBytes: bytes, sourceSizeBytes: size, isPlaying: isPlaying,
            feed: adaptive ? .adaptive : (viaRelay ? .relay : .direct),
            seekSettling: seeking, mediaConfirmedOpen: open
        )
    }

    @Test("Une alimentation qui débite ne déclenche rien")
    func healthyFeedIsSilent() {
        var policy = FeedStallPolicy()
        var bytes: UInt64 = 1_000_000
        for _ in 0..<30 {
            bytes += 1_300_000 // ~10 Mb/s
            #expect(feed(&policy, bytes: bytes) == .healthy)
        }
    }

    @Test("Cinq secondes sans un octet demandent un réancrage")
    func silentFeedReanchors() {
        var policy = FeedStallPolicy()
        _ = feed(&policy, bytes: 1_000_000) // première mesure : la référence
        var outcomes: [FeedStallPolicy.Outcome] = []
        for _ in 0..<5 { outcomes.append(feed(&policy, bytes: 1_000_000)) }
        #expect(outcomes == [
            .stalling(seconds: 1), .stalling(seconds: 2), .stalling(seconds: 3),
            .stalling(seconds: 4), .reanchor
        ])
    }

    @Test("Un octet qui repart remet le compteur à zéro")
    func anyProgressClearsTheRun() {
        var policy = FeedStallPolicy()
        _ = feed(&policy, bytes: 1_000_000)
        for _ in 0..<4 { _ = feed(&policy, bytes: 1_000_000) }
        #expect(feed(&policy, bytes: 1_000_001) == .healthy)
        for _ in 0..<4 { #expect(feed(&policy, bytes: 1_000_001) != .reanchor) }
    }

    @Test("Le budget borne les réancrages d'une même lecture")
    func budgetBoundsOnePlayback() {
        var policy = FeedStallPolicy()
        var reanchors = 0
        _ = feed(&policy, bytes: 500)
        for _ in 0..<60 where feed(&policy, bytes: 500) == .reanchor { reanchors += 1 }
        #expect(reanchors == FeedStallPolicy.reanchorBudget)
        #expect(policy.reanchorsLeft == 0)
    }

    @Test("Une minute d'alimentation saine recrédite le budget")
    func healthyFeedRenewsTheBudget() {
        var policy = FeedStallPolicy()
        var bytes: UInt64 = 0
        _ = feed(&policy, bytes: bytes)
        for _ in 0..<10 { _ = feed(&policy, bytes: bytes) } // épuise une reprise
        #expect(policy.reanchorsLeft < FeedStallPolicy.reanchorBudget)
        for _ in 0..<FeedStallPolicy.budgetRenewSeconds {
            bytes += 1_300_000
            _ = feed(&policy, bytes: bytes)
        }
        #expect(policy.reanchorsLeft == FeedStallPolicy.reanchorBudget)
    }

    @Test("Une réouverture efface la fenêtre mais garde le budget")
    func reopenKeepsTheBudget() {
        var policy = FeedStallPolicy()
        _ = feed(&policy, bytes: 500)
        for _ in 0..<5 { _ = feed(&policy, bytes: 500) }
        let left = policy.reanchorsLeft
        policy.resetWindow()
        #expect(policy.reanchorsLeft == left)
        // La fenêtre repart de zéro : quatre mesures silencieuses ne suffisent
        // plus, il faut de nouveau une référence puis cinq.
        _ = feed(&policy, bytes: 500)
        for _ in 0..<4 { #expect(feed(&policy, bytes: 500) != .reanchor) }
    }

    // MARK: - Les quatre refus

    @Test("Un flux HLS se tait entre deux segments : jamais de réancrage")
    func adaptiveStreamIsExempt() {
        var policy = FeedStallPolicy()
        _ = feed(&policy, bytes: 500, adaptive: true)
        for _ in 0..<20 { #expect(feed(&policy, bytes: 500, adaptive: true) == .healthy) }
    }

    @Test("Un fichier entièrement lu n'a plus rien à chercher")
    func fullyReadSourceIsExempt() {
        var policy = FeedStallPolicy()
        // Une bande-annonce de 40 Mo, lue en entier puis jouée sur le tampon.
        let size: Int64 = 40_000_000
        _ = feed(&policy, bytes: 40_000_000, size: size)
        for _ in 0..<20 {
            #expect(feed(&policy, bytes: 40_000_000, size: size) == .healthy)
        }
        #expect(FeedStallPolicy.isFullyRead(40_000_000, size))
        // La marge couvre l'écart entre la taille annoncée et ce que libVLC
        // compte, sans avaler un vrai silence en plein film.
        #expect(FeedStallPolicy.isFullyRead(38_000_000, size))
        #expect(!FeedStallPolicy.isFullyRead(1_000_000, size))
        #expect(!FeedStallPolicy.isFullyRead(1_000_000, nil))
    }

    @Test("Pause, saut en cours, média pas encore ouvert : rien")
    func otherRefusals() {
        for (playing, seeking, open) in [(false, false, true), (true, true, true), (true, false, false)] {
            var policy = FeedStallPolicy()
            _ = feed(&policy, bytes: 500, isPlaying: playing, seeking: seeking, open: open)
            for _ in 0..<20 {
                #expect(feed(&policy, bytes: 500, isPlaying: playing, seeking: seeking, open: open) == .healthy)
            }
        }
    }

    @Test("Sans statistiques, on ne conclut rien")
    func absentStatisticsAreNeverAStall() {
        var policy = FeedStallPolicy()
        for _ in 0..<20 {
            #expect(policy.sample(
                readBytes: nil, sourceSizeBytes: 8_000_000_000, isPlaying: true,
                feed: .direct, seekSettling: false, mediaConfirmedOpen: true
            ) == .healthy)
        }
    }

    @Test("Le scénario mesuré : la coupure est vue pendant que l'image tourne")
    func measuredCutIsSeenWhileThePictureStillPlays() {
        // 17 h 48 min 55 : le pair annule le flux. L'image a tenu 18 s sur le
        // tampon avant que le garde-fou d'image ne voie quoi que ce soit.
        var policy = FeedStallPolicy()
        var bytes: UInt64 = 2_000_000_000
        for _ in 0..<5 { bytes += 1_300_000; _ = feed(&policy, bytes: bytes) }
        var secondsUntilReanchor: Int?
        for second in 1...20 where secondsUntilReanchor == nil {
            if feed(&policy, bytes: bytes) == .reanchor { secondsUntilReanchor = second }
        }
        #expect(secondsUntilReanchor == FeedStallPolicy.stallSeconds)
        // Soit bien avant les 18 s de tampon : le réancrage se fait sur une
        // image qui tourne encore, pas sur un écran figé.
        #expect(FeedStallPolicy.stallSeconds < 18)
    }

    // MARK: - La fin de fichier signalée par libVLC

    // Mesuré le 2026-10-05 sur les trois rapports `feed-stall` remontés au
    // serveur : TOUS étaient des faux positifs de fin de fichier. Le filtre
    // `prefetch` de libVLC lit 16 Mio d'avance ; près de la fin il a tout lu
    // et se tait — et le refus « fichier entièrement lu » compare un compteur
    // CUMULÉ à la taille, ce qui ne tient que pour une lecture partie de
    // l'octet 0. Arrow S02E11 (816 Mo) repris vers 19 min sur iPad : réancré à
    // 2459 s, exactement là où ffprobe place la fin de lecture d'avance ;
    // Avatar 3 (24 Go) : réancré à 11816 s deux nuits de suite.

    @Test("Le scénario mesuré : une reprise lue jusqu'au bout ne réancre plus")
    func resumedPlaybackReachingTheEndIsExempt() {
        // Les chiffres du rapport de l'iPad : 424 Mo lus d'un fichier de
        // 816 Mo, parce que la lecture avait repris à mi-parcours.
        let size: Int64 = 816_316_027
        let bytes: UInt64 = 424_149_669
        #expect(!FeedStallPolicy.isFullyRead(bytes, size)) // l'ancien refus ne tient pas
        var policy = FeedStallPolicy()
        _ = feed(&policy, bytes: bytes - 1_000_000, size: size)
        // libVLC annonce sa fin de flux, puis plus un octet jusqu'au générique.
        for _ in 0..<30 {
            #expect(feed(&policy, bytes: bytes, size: size, endReports: 1) == .healthy)
        }
        #expect(policy.reanchorsLeft == FeedStallPolicy.reanchorBudget)
    }

    @Test("Sans fin annoncée, le même silence reste une coupure")
    func sameSilenceWithoutEndIsStillACut() {
        let size: Int64 = 816_316_027
        var policy = FeedStallPolicy()
        _ = feed(&policy, bytes: 424_149_669, size: size)
        var outcomes: [FeedStallPolicy.Outcome] = []
        for _ in 0..<5 { outcomes.append(feed(&policy, bytes: 424_149_669, size: size)) }
        #expect(outcomes.last == .reanchor)
    }

    @Test("Des octets qui repartent après la fin rendent la main au garde-fou")
    func bytesAfterTheEndReArmTheWatchdog() {
        // Un saut en arrière rouvre l'entrée : la fin annoncée ne vaut plus,
        // et une coupure sur cette nouvelle connexion doit être vue.
        var policy = FeedStallPolicy()
        _ = feed(&policy, bytes: 1_000, endReports: 1)
        for _ in 0..<10 { #expect(feed(&policy, bytes: 1_000, endReports: 1) == .healthy) }
        _ = feed(&policy, bytes: 2_000, endReports: 1)
        var outcomes: [FeedStallPolicy.Outcome] = []
        for _ in 0..<5 { outcomes.append(feed(&policy, bytes: 2_000, endReports: 1)) }
        #expect(outcomes.last == .reanchor)
    }

    @Test("Une nouvelle fin annoncée vaut de nouveau exemption")
    func aLaterEndReportExemptsAgain() {
        var policy = FeedStallPolicy()
        _ = feed(&policy, bytes: 1_000, endReports: 1)
        _ = feed(&policy, bytes: 1_000, endReports: 1)   // plate : la fin tient
        _ = feed(&policy, bytes: 2_000, endReports: 1)   // relue : plus exemptée
        // Elle atteint de nouveau la fin dans la même seconde où elle relit.
        for _ in 0..<20 { #expect(feed(&policy, bytes: 3_000, endReports: 2) == .healthy) }
    }

    // Recette 2026-10-08 (M6-03) : `readBytes` vient de `libvlc_media_get_stats`,
    // 40 à 174 ms en retard sur l'annonce de fin. Une annonce tombée juste avant
    // un battement fige un compte trop bas, et le battement suivant voit les
    // derniers octets arriver : ce rattrapage levait l'exemption, d'où un
    // réancrage en plein générique (≈ 1 reprise lue jusqu'au bout sur 7).

    @Test("Annonce, rattrapage d'un battement, puis plat : toujours exempté")
    func catchUpRightAfterTheReportKeepsTheExemption() {
        var policy = FeedStallPolicy()
        _ = feed(&policy, bytes: 500_000_000)
        #expect(feed(&policy, bytes: 500_000_000, endReports: 1) == .healthy) // annonce, compte en retard
        #expect(feed(&policy, bytes: 500_400_000, endReports: 1) == .healthy) // rattrapage
        for _ in 0..<20 { #expect(feed(&policy, bytes: 500_400_000, endReports: 1) == .healthy) }
        #expect(policy.reanchorsLeft == FeedStallPolicy.reanchorBudget)
    }

    @Test("Annonce, plat, puis des octets : relecture, l'exemption tombe")
    func growthAfterAFlatBeatIsARead() {
        var policy = FeedStallPolicy()
        _ = feed(&policy, bytes: 500_000_000, endReports: 1)
        _ = feed(&policy, bytes: 500_000_000, endReports: 1)
        _ = feed(&policy, bytes: 501_000_000, endReports: 1)
        var outcomes: [FeedStallPolicy.Outcome] = []
        for _ in 0..<5 { outcomes.append(feed(&policy, bytes: 501_000_000, endReports: 1)) }
        #expect(outcomes.last == .reanchor)
    }

    @Test("Annonce puis deux battements qui lisent : relecture, l'exemption tombe")
    func twoGrowingBeatsAfterTheReportAreARead() {
        var policy = FeedStallPolicy()
        _ = feed(&policy, bytes: 500_000_000, endReports: 1)
        _ = feed(&policy, bytes: 500_400_000, endReports: 1) // rattrapage
        _ = feed(&policy, bytes: 501_400_000, endReports: 1) // relecture
        var outcomes: [FeedStallPolicy.Outcome] = []
        for _ in 0..<5 { outcomes.append(feed(&policy, bytes: 501_400_000, endReports: 1)) }
        #expect(outcomes.last == .reanchor)
    }

    @Test("Une réouverture oublie la fin de l'ancien flux")
    func reopenForgetsThePreviousEnd() {
        // Le compteur d'octets repart de zéro avec la nouvelle entrée : une fin
        // mémorisée à 800 Mo ne doit pas couvrir le silence d'un flux neuf.
        var policy = FeedStallPolicy()
        _ = feed(&policy, bytes: 800_000_000, endReports: 1)
        policy.resetWindow()
        _ = feed(&policy, bytes: 5_000, endReports: 1)
        var outcomes: [FeedStallPolicy.Outcome] = []
        for _ in 0..<5 { outcomes.append(feed(&policy, bytes: 5_000, endReports: 1)) }
        #expect(outcomes.last == .reanchor)
    }

    // MARK: - La voie directe : bascule au relais

    // Mesuré sur Apple TV le 2026-10-08 puis le 2026-10-21 (MKV en DirectStream
    // derrière Cloudflare, `peer stream N error: Cancellation (0x8)`) : sur la
    // voie DIRECTE, le réancrage par saut n'a ramené AUCUN octet — `read=` figé
    // d'un saut à l'autre (830 942 804 avant comme après, le 21/10) — et seule
    // la reconstruction a rendu l'alimentation. Les deux réancrages coûtaient
    // ~16 s de gel avant elle, puis la reconstruction rouvrait EN DIRECT et
    // retombait sur la même coupure. Le remède sur la voie directe est donc la
    // reconstruction immédiate par le relais, dont la reconnexion en cours de
    // flux rend les coupures suivantes invisibles.

    @Test("Voie directe : cinq secondes sans un octet basculent au relais, sans réancrage")
    func directCutFailsOverToTheRelay() {
        var policy = FeedStallPolicy()
        _ = feed(&policy, bytes: 830_942_804, viaRelay: false)
        var outcomes: [FeedStallPolicy.Outcome] = []
        for _ in 0..<5 { outcomes.append(feed(&policy, bytes: 830_942_804, viaRelay: false)) }
        #expect(outcomes == [
            .stalling(seconds: 1), .stalling(seconds: 2), .stalling(seconds: 3),
            .stalling(seconds: 4), .failoverToRelay
        ])
    }

    @Test("Voie relais : le réancrage garde son rôle")
    func relayCutStillReanchors() {
        var policy = FeedStallPolicy()
        _ = feed(&policy, bytes: 500, viaRelay: true)
        var outcomes: [FeedStallPolicy.Outcome] = []
        for _ in 0..<5 { outcomes.append(feed(&policy, bytes: 500, viaRelay: true)) }
        #expect(outcomes.last == .reanchor)
    }

    @Test("Voie directe : les mêmes refus tiennent (HLS, fin de flux, saut, ouverture)")
    func directRouteKeepsEveryRefusal() {
        for (adaptive, seeking, open, endReports) in [
            (true, false, true, 0), (false, true, true, 0), (false, false, false, 0), (false, false, true, 1),
        ] {
            var policy = FeedStallPolicy()
            _ = feed(&policy, bytes: 500, adaptive: adaptive, seeking: seeking, open: open,
                     endReports: endReports, viaRelay: false)
            for _ in 0..<20 {
                #expect(feed(&policy, bytes: 500, adaptive: adaptive, seeking: seeking, open: open,
                             endReports: endReports, viaRelay: false) == .healthy)
            }
        }
    }

    @Test("La bascule dépense le même budget : jamais une boucle de reconstructions")
    func failoverSpendsTheSameBudget() {
        // Une reconstruction refusée (plus de budget côté image, ou une autre
        // déjà en cours) laisse la voie directe : le garde-fou ne doit pas
        // redemander une bascule toutes les cinq secondes pour le reste du film.
        var policy = FeedStallPolicy()
        var failovers = 0
        _ = feed(&policy, bytes: 500, viaRelay: false)
        for _ in 0..<60 where feed(&policy, bytes: 500, viaRelay: false) == .failoverToRelay { failovers += 1 }
        #expect(failovers == FeedStallPolicy.reanchorBudget)
        #expect(policy.reanchorsLeft == 0)
    }

    @Test("Le scénario du 21/10 : une seule action, la bascule, dès la 5e seconde")
    func measuredCloudflareCutFailsOverOnce() {
        // 19:34:45.566 coupure ; 19:34:51.559 premier réancrage ; 19:34:59.618
        // reconstruction (directe). Désormais : bascule à la 5e seconde de
        // silence, et plus rien tant que la reconstruction négocie — l'appelant
        // passe `seekSettling` à vrai pendant la négociation, comme pour le
        // garde-fou d'image (`reResolve.isNegotiating`).
        var policy = FeedStallPolicy()
        var bytes: UInt64 = 830_000_000
        for _ in 0..<5 { bytes += 600_000; _ = feed(&policy, bytes: bytes, viaRelay: false) }
        var actions: [Int: FeedStallPolicy.Outcome] = [:]
        for second in 1...5 {
            let outcome = feed(&policy, bytes: bytes, viaRelay: false)
            if outcome == .failoverToRelay || outcome == .reanchor { actions[second] = outcome }
        }
        #expect(actions == [FeedStallPolicy.stallSeconds: .failoverToRelay])
        // La reconstruction négocie (21 s le 21/10) : aucun second remède.
        for _ in 0..<21 { #expect(feed(&policy, bytes: bytes, seeking: true, viaRelay: false) == .healthy) }
    }
}
