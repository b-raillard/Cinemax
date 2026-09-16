import Testing
@testable import Cinemax

/// Verrouille la détection de l'image figée : décodeur vidéo planté (horloge
/// qui avance, 13/09) ou chaîne entière bloquée (horloge et son figés, 15/09).
///
/// La propriété qui porte tout : c'est l'ÉTAT du moteur qui décide, pas
/// l'horloge. Pause, mise en tampon, recherche en cours, fin de média sortent
/// toutes par un état ou une fenêtre qui leur est propre ; « en lecture et
/// aucune image » n'est jamais légitime, que l'horloge avance ou non.
@Suite("Image figée en cours de lecture")
struct PictureStallPolicyTests {

    /// Un lecteur simulé qui bat la seconde. Les compteurs vivent ICI et non
    /// dans la fonction d'aide : des compteurs locaux repartiraient de zéro à
    /// chaque appel, l'horloge n'avancerait jamais d'un appel au suivant, et
    /// les tests de budget passeraient pour une raison fausse.
    private struct Feeder {
        var policy = PictureStallPolicy()
        var pictures: UInt64 = 1000
        var position: Int32 = 5000

        mutating func tick(
            picturesMove: Bool = true,
            clockMoves: Bool = true,
            isPlaying: Bool = true,
            hasVideoTrack: Bool = true,
            seekSettling: Bool = false,
            mediaConfirmedOpen: Bool = true,
            statisticsAvailable: Bool = true
        ) -> PictureStallPolicy.Outcome {
            if picturesMove { pictures += 24 }
            if clockMoves { position += 1000 }
            return policy.sample(
                displayedPictures: statisticsAvailable ? pictures : nil,
                positionMs: position,
                isPlaying: isPlaying,
                hasVideoTrack: hasVideoTrack,
                seekSettling: seekSettling,
                mediaConfirmedOpen: mediaConfirmedOpen
            )
        }

        mutating func run(
            _ count: Int,
            picturesMove: Bool = true,
            clockMoves: Bool = true,
            isPlaying: Bool = true,
            hasVideoTrack: Bool = true,
            seekSettling: Bool = false,
            mediaConfirmedOpen: Bool = true,
            statisticsAvailable: Bool = true
        ) -> [PictureStallPolicy.Outcome] {
            (0..<count).map { _ in
                tick(picturesMove: picturesMove, clockMoves: clockMoves,
                     isPlaying: isPlaying, hasVideoTrack: hasVideoTrack,
                     seekSettling: seekSettling, mediaConfirmedOpen: mediaConfirmedOpen,
                     statisticsAvailable: statisticsAvailable)
            }
        }
    }

    // MARK: - Le cas nominal

    @Test("Des images qui sortent : jamais de reprise, quoi qu'il arrive")
    func healthyNeverRecovers() {
        var f = Feeder()
        let out = f.run(600)
        #expect(out.allSatisfy { $0 == .healthy })
        #expect(f.policy.recoveriesLeft == PictureStallPolicy.recoveryBudget)
    }

    // MARK: - La signature mesurée

    @Test("Horloge qui avance + aucune image : reprise au seuil, et pas avant")
    func stalledPictureWithMovingClockRecovers() {
        var f = Feeder()
        let out = f.run(PictureStallPolicy.stallSeconds + 1, picturesMove: false)
        // Le premier échantillon d'une fenêtre n'a rien à comparer.
        #expect(out.first == .healthy)
        let verdicts = Array(out.dropFirst())
        #expect(verdicts.last == .recover)
        // Tout ce qui précède la reprise n'est qu'un décompte.
        for (i, v) in verdicts.dropLast().enumerated() {
            #expect(v == .stalling(seconds: i + 1))
        }
        #expect(f.policy.recoveriesLeft == PictureStallPolicy.recoveryBudget - 1)
        #expect(f.policy.stallClockMoved)
    }

    @Test("Horloge figée AUSSI (son coupé, 15/09) : même reprise, au même seuil")
    func frozenClockAndPictureRecovers() {
        var f = Feeder()
        let out = f.run(PictureStallPolicy.stallSeconds + 1, picturesMove: false, clockMoves: false)
        #expect(out.first == .healthy)
        let verdicts = Array(out.dropFirst())
        #expect(verdicts.last == .recover)
        for (i, v) in verdicts.dropLast().enumerated() {
            #expect(v == .stalling(seconds: i + 1))
        }
        #expect(f.policy.recoveriesLeft == PictureStallPolicy.recoveryBudget - 1)
        // Le document doit pouvoir dire lequel des deux cas c'était.
        #expect(f.policy.stallClockMoved == false)
    }

    @Test("La forme d'un blocage ne déteint pas sur le suivant")
    func clockShapeIsPerStall() {
        var f = Feeder()
        _ = f.run(PictureStallPolicy.stallSeconds + 1, picturesMove: false)
        #expect(f.policy.stallClockMoved)
        _ = f.run(3)                                   // des images reviennent
        _ = f.run(PictureStallPolicy.stallSeconds, picturesMove: false, clockMoves: false)
        #expect(f.policy.stallClockMoved == false)
    }

    // MARK: - Les refus

    @Test("En pause, en calage de recherche, sans piste vidéo, avant l'ouverture, sans stats : jamais, horloge figée ou non")
    func refusals() {
        let cases = ["pause", "seek", "audio", "notOpen", "noStats"].flatMap { label in
            [true, false].map { (label, $0) }
        }
        for (label, clockMoves) in cases {
            var f = Feeder()
            let out = f.run(
                60,
                picturesMove: false,
                clockMoves: clockMoves,
                isPlaying: label != "pause",
                hasVideoTrack: label != "audio",
                seekSettling: label == "seek",
                mediaConfirmedOpen: label != "notOpen",
                statisticsAvailable: label != "noStats"
            )
            #expect(out.allSatisfy { $0 == .healthy }, "\(label) (horloge \(clockMoves)) ne doit jamais déclencher")
            #expect(f.policy.recoveriesLeft == PictureStallPolicy.recoveryBudget)
        }
    }

    // MARK: - Le budget, et la boucle qu'il empêche

    @Test("Le budget s'épuise : deux reprises, puis plus rien que du décompte")
    func budgetIsSpentThenSilent() {
        var f = Feeder()
        var recoveries = 0
        for _ in 0..<200 where f.tick(picturesMove: false) == .recover { recoveries += 1 }
        #expect(recoveries == PictureStallPolicy.recoveryBudget)
        #expect(f.policy.recoveriesLeft == 0)
    }

    @Test("La reprise NE rend PAS le budget — sinon la borne n'en est pas une")
    func reopenDoesNotRestoreBudget() {
        var f = Feeder()
        var recoveries = 0
        for _ in 0..<200 {
            if f.tick(picturesMove: false) == .recover {
                recoveries += 1
                // Ce que fait le lecteur juste après : la reprise passe par
                // `beginOpenLoading`, donc par `resetWindow()`. Si cet appel
                // rendait le budget, cette boucle renégocierait contre le
                // serveur indéfiniment.
                f.policy.resetWindow()
            }
        }
        #expect(recoveries == PictureStallPolicy.recoveryBudget)
    }

    @Test("Le budget revient après une vraie preuve que la reprise a marché")
    func budgetRenewsAfterHealthyPlayback() {
        var f = Feeder()
        _ = f.run(PictureStallPolicy.stallSeconds + 1, picturesMove: false)
        #expect(f.policy.recoveriesLeft == PictureStallPolicy.recoveryBudget - 1)
        f.policy.resetWindow()
        // Le premier échantillon d'après ne compte pas (rien à comparer), donc
        // il manque encore une seconde saine au compte.
        _ = f.run(PictureStallPolicy.budgetRenewSeconds)
        #expect(f.policy.recoveriesLeft == PictureStallPolicy.recoveryBudget - 1)
        _ = f.run(1)
        #expect(f.policy.recoveriesLeft == PictureStallPolicy.recoveryBudget)
    }

    @Test("resetWindow coupe la comparaison à travers le trou")
    func resetWindowDropsTheComparison() {
        var f = Feeder()
        _ = f.run(4, picturesMove: false)
        f.policy.resetWindow()
        // Le premier échantillon d'après repart de zéro : il ne peut pas
        // compter comme la 5e seconde figée.
        #expect(f.tick(picturesMove: false) == .healthy)
    }
}
