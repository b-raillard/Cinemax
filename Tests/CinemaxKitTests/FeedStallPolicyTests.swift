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
/// voit la coupure pendant que l'image tourne encore, ce qui rend le remède bon
/// marché : un réancrage, seule chose qui fasse rouvrir une connexion neuve.
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
        open: Bool = true
    ) -> FeedStallPolicy.Outcome {
        policy.sample(
            readBytes: bytes, sourceSizeBytes: size, isPlaying: isPlaying,
            isAdaptiveStream: adaptive, seekSettling: seeking, mediaConfirmedOpen: open
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
                isAdaptiveStream: false, seekSettling: false, mediaConfirmedOpen: true
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
}
