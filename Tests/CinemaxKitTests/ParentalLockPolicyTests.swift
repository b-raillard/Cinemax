import Testing
import Foundation
@testable import CinemaxKit
@testable import Cinemax

/// Verrouille la politique du code parental (#177).
///
/// Ce que le verrou vaut vraiment est écrit dans `ParentalLockPolicy` : il
/// referme le SEUL chemin in-app qui lève le plafond d'âge côté client (la
/// rangée d'âge de Confidentialité). Ce qui est testé ici est donc exactement
/// ce qui doit tenir pour que ce chemin reste fermé : la forme du code, le
/// fait que seul un condensé soit manipulé, et surtout la temporisation —
/// sans elle, 10 000 codes à quatre chiffres s'épuisent en une soirée.
@Suite("Code parental — politique")
struct ParentalLockPolicyTests {

    /// Coût volontairement minuscule : les tests vérifient la LOGIQUE, pas le
    /// facteur de travail. 150 000 tours par appel rendraient la suite inutile.
    private let cheapIterations = 2
    private let salt = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])

    private func credential(pin: String = "4242", biometrics: Bool = false) -> ParentalLockCredential {
        ParentalLockPolicy.makeCredential(
            pin: pin,
            biometricsEnabled: biometrics,
            salt: salt,
            iterations: cheapIterations
        )!
    }

    // MARK: - Forme du code

    @Test("De 4 à 8 chiffres ASCII, rien d'autre")
    func pinShape() {
        #expect(ParentalLockPolicy.isValidPIN("1234"))
        #expect(ParentalLockPolicy.isValidPIN("12345678"))
        #expect(ParentalLockPolicy.isValidPIN("0000"))

        #expect(ParentalLockPolicy.isValidPIN("123") == false)          // trop court
        #expect(ParentalLockPolicy.isValidPIN("123456789") == false)    // trop long
        #expect(ParentalLockPolicy.isValidPIN("") == false)
        #expect(ParentalLockPolicy.isValidPIN("12a4") == false)
        #expect(ParentalLockPolicy.isValidPIN("12 4") == false)
        // Chiffres arabes-indiens : `isNumber` répond vrai, mais le pavé ne peut
        // pas les produire — un code intypable serait un enfermement, pas un
        // verrou.
        #expect(ParentalLockPolicy.isValidPIN("١٢٣٤") == false)
    }

    @Test("Un code invalide ne produit aucune empreinte")
    func makeCredentialRefusesInvalidPIN() {
        #expect(ParentalLockPolicy.makeCredential(pin: "12", biometricsEnabled: false) == nil)
        #expect(ParentalLockPolicy.makeCredential(pin: "abcd", biometricsEnabled: false) == nil)
    }

    // MARK: - Empreinte

    @Test("L'empreinte est déterministe, et dépend du sel comme du nombre de tours")
    func hashProperties() {
        let a = ParentalLockPolicy.hash(pin: "4242", salt: salt, iterations: cheapIterations)
        let b = ParentalLockPolicy.hash(pin: "4242", salt: salt, iterations: cheapIterations)
        #expect(a == b)

        let otherSalt = ParentalLockPolicy.hash(pin: "4242", salt: Data(repeating: 9, count: 16), iterations: cheapIterations)
        #expect(a != otherSalt)

        let moreRounds = ParentalLockPolicy.hash(pin: "4242", salt: salt, iterations: cheapIterations + 1)
        #expect(a != moreRounds)

        let otherPIN = ParentalLockPolicy.hash(pin: "4243", salt: salt, iterations: cheapIterations)
        #expect(a != otherPIN)
    }

    @Test("Deux sels tirés de suite diffèrent, et font la longueur annoncée")
    func randomSaltIsRandom() {
        let first = ParentalLockPolicy.randomSalt()
        let second = ParentalLockPolicy.randomSalt()
        #expect(first.count == ParentalLockPolicy.saltLength)
        #expect(first != second)
    }

    @Test("Le credential retient le coût employé, pas la constante du jour")
    func credentialCarriesItsOwnCost() {
        let stored = credential()
        #expect(stored.iterations == cheapIterations)
        // C'est ce qui permet de relever `ParentalLockPolicy.iterations` plus
        // tard sans invalider un code déjà enrôlé.
        #expect(ParentalLockPolicy.verify(pin: "4242", against: stored) == .unlocked({
            var cleared = stored
            cleared.failedAttempts = 0
            cleared.lockedUntil = nil
            return cleared
        }()))
    }

    // MARK: - Vérification

    @Test("Le bon code ouvre et remet les compteurs à zéro")
    func correctPINUnlocksAndClearsCounters() {
        var stored = credential()
        stored.failedAttempts = 3
        stored.lockedUntil = Date().addingTimeInterval(-10)   // fenêtre expirée

        guard case .unlocked(let updated) = ParentalLockPolicy.verify(pin: "4242", against: stored) else {
            Issue.record("le bon code aurait dû ouvrir")
            return
        }
        #expect(updated.failedAttempts == 0)
        #expect(updated.lockedUntil == nil)
    }

    @Test("Un mauvais code incrémente et décompte les essais restants")
    func wrongPINCountsDown() {
        var stored = credential()
        for attempt in 1...ParentalLockPolicy.freeAttempts {
            guard case .wrong(let updated, let left) = ParentalLockPolicy.verify(pin: "0000", against: stored) else {
                Issue.record("le mauvais code aurait dû être refusé (essai \(attempt))")
                return
            }
            #expect(updated.failedAttempts == attempt)
            #expect(left == ParentalLockPolicy.freeAttempts - attempt)
            // Tant qu'il reste des essais libres, aucune fenêtre n'est ouverte.
            #expect(updated.lockedUntil == nil)
            stored = updated
        }
        // L'essai suivant ouvre la première temporisation.
        guard case .wrong(let updated, let left) = ParentalLockPolicy.verify(pin: "0000", against: stored) else {
            Issue.record("le mauvais code aurait dû être refusé")
            return
        }
        #expect(left == 0)
        #expect(updated.lockedUntil != nil)
    }

    // MARK: - Temporisation

    @Test("La temporisation escalade puis plafonne à une heure")
    func backoffSchedule() {
        for failures in 0...ParentalLockPolicy.freeAttempts {
            #expect(ParentalLockPolicy.backoff(afterFailures: failures) == nil)
        }
        #expect(ParentalLockPolicy.backoff(afterFailures: 6) == 30)
        #expect(ParentalLockPolicy.backoff(afterFailures: 7) == 60)
        #expect(ParentalLockPolicy.backoff(afterFailures: 8) == 300)
        #expect(ParentalLockPolicy.backoff(afterFailures: 9) == 900)
        #expect(ParentalLockPolicy.backoff(afterFailures: 10) == 3600)
        // Le plafond est ce qui empêche l'agacement d'un enfant de priver le
        // parent de ses propres réglages pendant une semaine.
        #expect(ParentalLockPolicy.backoff(afterFailures: 500) == 3600)
    }

    @Test("Fenêtre ouverte : même le BON code est refusé")
    func throttleRefusesEvenTheCorrectPIN() {
        var stored = credential()
        let until = Date().addingTimeInterval(120)
        stored.lockedUntil = until
        stored.failedAttempts = 6

        #expect(ParentalLockPolicy.verify(pin: "4242", against: stored) == .throttled(until: until))
    }

    @Test("Marteler le pavé pendant une fenêtre ne la prolonge pas")
    func mashingDoesNotExtendTheWindow() {
        var stored = credential()
        let until = Date().addingTimeInterval(60)
        stored.lockedUntil = until
        stored.failedAttempts = 6

        // Le refus intervient AVANT tout calcul d'empreinte, donc rien n'est
        // renvoyé à persister : les compteurs ne bougent pas et la fenêtre ne
        // se décale pas. Sans cette propriété, un enfant appuyant en rafale
        // repousserait indéfiniment l'accès du parent.
        for _ in 0..<20 {
            #expect(ParentalLockPolicy.verify(pin: "0000", against: stored) == .throttled(until: until))
        }
        #expect(stored.failedAttempts == 6)
        #expect(stored.lockedUntil == until)
    }

    @Test("Fenêtre expirée : la vérification reprend normalement")
    func expiredWindowLetsAttemptsThrough() {
        var stored = credential()
        stored.lockedUntil = Date().addingTimeInterval(-1)
        stored.failedAttempts = 6

        guard case .wrong(let updated, _) = ParentalLockPolicy.verify(pin: "0000", against: stored) else {
            Issue.record("la fenêtre étant expirée, l'essai devait être évalué")
            return
        }
        #expect(updated.failedAttempts == 7)
        // Une fenêtre expirée n'est pas reportée : la nouvelle est dérivée du
        // compte désormais plus élevé.
        #expect(updated.lockedUntil != nil)
        if let next = updated.lockedUntil {
            #expect(next > Date())
        }
    }

    // MARK: - Comparaison

    @Test("La comparaison refuse deux longueurs différentes")
    func constantTimeEqualsRejectsLengthMismatch() {
        #expect(ParentalLockPolicy.constantTimeEquals(Data([1, 2, 3]), Data([1, 2])) == false)
        #expect(ParentalLockPolicy.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(ParentalLockPolicy.constantTimeEquals(Data(), Data()))
    }
}
