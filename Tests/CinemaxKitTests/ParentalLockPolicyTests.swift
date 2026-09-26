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

    private func credential(pin: String = "424242", biometrics: Bool = false) -> ParentalLockCredential {
        ParentalLockPolicy.makeCredential(
            pin: pin,
            biometricsEnabled: biometrics,
            salt: salt,
            iterations: cheapIterations
        )!
    }

    // MARK: - Forme du code

    /// Audit lot 6 (2026-09-25, S9) : le minimum d'un code CHOISI passe de 4 à
    /// 6 chiffres ; un code plus court déjà enrôlé reste accepté au déverrouillage.
    @Test("Choisir : de 6 à 8 chiffres ASCII, rien d'autre")
    func pinShape() {
        #expect(ParentalLockPolicy.isValidPIN("123456"))
        #expect(ParentalLockPolicy.isValidPIN("12345678"))
        #expect(ParentalLockPolicy.isValidPIN("000000"))

        #expect(ParentalLockPolicy.isValidPIN("1234") == false)         // ancien minimum
        #expect(ParentalLockPolicy.isValidPIN("12345") == false)
        #expect(ParentalLockPolicy.isValidPIN("123456789") == false)    // trop long
        #expect(ParentalLockPolicy.isValidPIN("") == false)
        #expect(ParentalLockPolicy.isValidPIN("12a456") == false)
        #expect(ParentalLockPolicy.isValidPIN("12 456") == false)
        // Chiffres arabes-indiens : `isNumber` répond vrai, mais le pavé ne peut
        // pas les produire — un code intypable serait un enfermement, pas un
        // verrou.
        #expect(ParentalLockPolicy.isValidPIN("١٢٣٤٥٦") == false)
    }

    @Test("Déverrouiller : un ancien code de 4 ou 5 chiffres reste saisissable")
    func unlockCandidateShape() {
        #expect(ParentalLockPolicy.isUnlockCandidate("1234"))
        #expect(ParentalLockPolicy.isUnlockCandidate("12345"))
        #expect(ParentalLockPolicy.isUnlockCandidate("12345678"))
        #expect(ParentalLockPolicy.isUnlockCandidate("123") == false)
        #expect(ParentalLockPolicy.isUnlockCandidate("123456789") == false)
        #expect(ParentalLockPolicy.isUnlockCandidate("12a4") == false)
    }

    @Test("Un code invalide ne produit aucune empreinte")
    func makeCredentialRefusesInvalidPIN() {
        #expect(ParentalLockPolicy.makeCredential(pin: "12", biometricsEnabled: false) == nil)
        #expect(ParentalLockPolicy.makeCredential(pin: "1234", biometricsEnabled: false) == nil)
        #expect(ParentalLockPolicy.makeCredential(pin: "abcd", biometricsEnabled: false) == nil)
    }

    // MARK: - Empreinte

    @Test("L'empreinte est déterministe, et dépend du sel comme du nombre de tours")
    func hashProperties() {
        let a = ParentalLockPolicy.hash(pin: "424242", salt: salt, iterations: cheapIterations)
        let b = ParentalLockPolicy.hash(pin: "424242", salt: salt, iterations: cheapIterations)
        #expect(a == b)

        let otherSalt = ParentalLockPolicy.hash(pin: "424242", salt: Data(repeating: 9, count: 16), iterations: cheapIterations)
        #expect(a != otherSalt)

        let moreRounds = ParentalLockPolicy.hash(pin: "424242", salt: salt, iterations: cheapIterations + 1)
        #expect(a != moreRounds)

        let otherPIN = ParentalLockPolicy.hash(pin: "424243", salt: salt, iterations: cheapIterations)
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
        #expect(ParentalLockPolicy.verify(pin: "424242", against: stored) == .unlocked({
            var cleared = stored
            cleared.failedAttempts = 0
            cleared.lockedUntil = nil
            cleared.backoffAnchor = nil
            return cleared
        }()))
    }

    // MARK: - Vérification

    @Test("Le bon code ouvre et remet les compteurs à zéro")
    func correctPINUnlocksAndClearsCounters() {
        var stored = credential()
        stored.failedAttempts = 3
        stored.lockedUntil = Date().addingTimeInterval(-10)   // fenêtre expirée

        guard case .unlocked(let updated) = ParentalLockPolicy.verify(pin: "424242", against: stored) else {
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

    /// Une lecture des deux horloges : `wall` réglable par l'utilisateur,
    /// `monotonic` non. Même démarrage ⇔ `wall − monotonic` constant.
    private func clock(wall: TimeInterval, monotonic: TimeInterval) -> ParentalLockClock {
        ParentalLockClock(wall: Date(timeIntervalSince1970: wall), monotonic: monotonic)
    }

    /// Un credential dont la fenêtre de `duration` s'est ouverte à `at`.
    private func throttled(at clock: ParentalLockClock, duration: TimeInterval) -> ParentalLockCredential {
        var stored = credential()
        stored.failedAttempts = 6
        stored.backoffAnchor = ParentalLockBackoffAnchor(wall: clock.wall, monotonic: clock.monotonic, duration: duration)
        stored.lockedUntil = clock.wall.addingTimeInterval(duration)
        return stored
    }

    @Test("Fenêtre ouverte : même le BON code est refusé")
    func throttleRefusesEvenTheCorrectPIN() {
        let start = clock(wall: 1_000_000, monotonic: 500)
        let stored = throttled(at: start, duration: 120)
        let later = clock(wall: 1_000_010, monotonic: 510)

        guard case .throttled(let until, let reanchored) = ParentalLockPolicy.verify(pin: "424242", against: stored, clock: later) else {
            Issue.record("la fenêtre est ouverte : le bon code aussi doit être refusé")
            return
        }
        #expect(until == later.wall.addingTimeInterval(110))
        #expect(reanchored == nil)
    }

    @Test("Marteler le pavé pendant une fenêtre ne la prolonge pas")
    func mashingDoesNotExtendTheWindow() {
        let start = clock(wall: 1_000_000, monotonic: 500)
        let stored = throttled(at: start, duration: 60)
        let later = clock(wall: 1_000_005, monotonic: 505)

        // Le refus intervient AVANT tout calcul d'empreinte, donc rien n'est
        // renvoyé à persister : les compteurs ne bougent pas et la fenêtre ne
        // se décale pas. Sans cette propriété, un enfant appuyant en rafale
        // repousserait indéfiniment l'accès du parent.
        for _ in 0..<20 {
            #expect(ParentalLockPolicy.verify(pin: "000000", against: stored, clock: later)
                == .throttled(until: later.wall.addingTimeInterval(55), reanchored: nil))
        }
        #expect(stored.failedAttempts == 6)
    }

    @Test("Fenêtre écoulée (horloge monotone) : la vérification reprend normalement")
    func expiredWindowLetsAttemptsThrough() {
        let start = clock(wall: 1_000_000, monotonic: 500)
        let stored = throttled(at: start, duration: 30)
        let later = clock(wall: 1_000_031, monotonic: 531)

        guard case .wrong(let updated, _) = ParentalLockPolicy.verify(pin: "000000", against: stored, clock: later) else {
            Issue.record("la fenêtre étant écoulée, l'essai devait être évalué")
            return
        }
        #expect(updated.failedAttempts == 7)
        // Une fenêtre écoulée n'est pas reportée : la nouvelle est dérivée du
        // compte désormais plus élevé, et ancrée sur l'horloge monotone.
        #expect(updated.backoffAnchor == ParentalLockBackoffAnchor(wall: later.wall, monotonic: 531, duration: 60))
        #expect(updated.lockedUntil == later.wall.addingTimeInterval(60))
    }

    /// Audit 2026-09-22 (S9) : avancer la date dans Réglages refermait la
    /// fenêtre sur-le-champ. L'heure murale ne compte plus.
    @Test("Avancer la date ne referme pas la fenêtre : elle repart de sa durée")
    func settingTheDateForwardDoesNotCloseTheWindow() {
        let start = clock(wall: 1_000_000, monotonic: 500)
        let stored = throttled(at: start, duration: 3600)
        // Dix secondes plus tard sur l'horloge monotone, mais un jour plus
        // tard sur l'horloge murale.
        let tampered = clock(wall: 1_000_000 + 86_400, monotonic: 510)

        let window = ParentalLockPolicy.backoffRemaining(stored, at: tampered)
        #expect(window.remaining == 3600)
        #expect(window.reanchored?.backoffAnchor == ParentalLockBackoffAnchor(wall: tampered.wall, monotonic: 510, duration: 3600))
        guard case .throttled = ParentalLockPolicy.verify(pin: "424242", against: stored, clock: tampered) else {
            Issue.record("la fenêtre aurait dû rester ouverte")
            return
        }
    }

    @Test("Reculer la date ne la referme pas non plus")
    func settingTheDateBackDoesNotCloseTheWindow() {
        let start = clock(wall: 1_000_000, monotonic: 500)
        let stored = throttled(at: start, duration: 300)
        let tampered = clock(wall: 1_000_000 - 86_400, monotonic: 520)
        #expect(ParentalLockPolicy.backoffRemaining(stored, at: tampered).remaining == 300)
    }

    @Test("Un redémarrage (horloge monotone remise à zéro) relance la fenêtre")
    func rebootRestartsTheWindow() {
        let start = clock(wall: 1_000_000, monotonic: 50_000)
        let stored = throttled(at: start, duration: 900)
        let afterReboot = clock(wall: 1_000_120, monotonic: 30)
        let window = ParentalLockPolicy.backoffRemaining(stored, at: afterReboot)
        #expect(window.remaining == 900)
        #expect(window.reanchored?.backoffAnchor?.monotonic == 30)
    }

    @Test("Une petite correction de l'heure réseau ne relance rien")
    func networkTimeNudgeIsTolerated() {
        let start = clock(wall: 1_000_000, monotonic: 500)
        let stored = throttled(at: start, duration: 60)
        let nudged = clock(wall: 1_000_020.5, monotonic: 520)   // +0,5 s de correction
        let window = ParentalLockPolicy.backoffRemaining(stored, at: nudged)
        #expect(window.remaining == 40)
        #expect(window.reanchored == nil)
    }

    @Test("Une fenêtre écoulée est effacée, pour qu'un redémarrage ne la relance pas")
    func expiredAnchorIsCleared() {
        let start = clock(wall: 1_000_000, monotonic: 500)
        let stored = throttled(at: start, duration: 30)
        let window = ParentalLockPolicy.backoffRemaining(stored, at: clock(wall: 1_000_040, monotonic: 540))
        #expect(window.remaining == 0)
        #expect(window.reanchored?.backoffAnchor == nil)
        #expect(window.reanchored?.lockedUntil == nil)
    }

    @Test("Un credential d'avant l'ancre (lockedUntil seul) est réancré, borné à une heure")
    func legacyWindowIsReanchored() {
        var stored = credential()
        stored.failedAttempts = 6
        stored.lockedUntil = Date(timeIntervalSince1970: 1_000_090)
        let now = clock(wall: 1_000_000, monotonic: 7)
        let window = ParentalLockPolicy.backoffRemaining(stored, at: now)
        #expect(window.remaining == 90)
        #expect(window.reanchored?.backoffAnchor == ParentalLockBackoffAnchor(wall: now.wall, monotonic: 7, duration: 90))

        stored.lockedUntil = Date(timeIntervalSince1970: 1_000_000 + 10 * 86_400)   // absurde
        #expect(ParentalLockPolicy.backoffRemaining(stored, at: now).remaining == 3600)
    }

    // MARK: - Longueur du code

    @Test("Un ancien code de 4 chiffres ouvre encore, et sa longueur est apprise")
    func legacyShortPINStillUnlocks() {
        let legacy = ParentalLockCredential(
            salt: salt,
            hash: ParentalLockPolicy.hash(pin: "4242", salt: salt, iterations: cheapIterations),
            iterations: cheapIterations
        )
        #expect(legacy.pinLength == nil)
        #expect(ParentalLockPolicy.needsLongerPIN(legacy) == false, "longueur inconnue : pas d'invitation")

        guard case .unlocked(let updated) = ParentalLockPolicy.verify(pin: "4242", against: legacy) else {
            Issue.record("un code de 4 chiffres déjà enrôlé doit toujours ouvrir")
            return
        }
        #expect(updated.pinLength == 4)
        #expect(ParentalLockPolicy.needsLongerPIN(updated))

        let fresh = credential()
        #expect(fresh.pinLength == 6)
        #expect(ParentalLockPolicy.needsLongerPIN(fresh) == false)
    }

    @Test("Un credential enregistré avant ces champs se décode toujours")
    func credentialDecodesWithoutNewFields() throws {
        let json = #"{"salt":"AQID","hash":"BAUG","iterations":2,"failedAttempts":1,"biometricsEnabled":false}"#
        let decoded = try JSONDecoder().decode(ParentalLockCredential.self, from: Data(json.utf8))
        #expect(decoded.backoffAnchor == nil)
        #expect(decoded.pinLength == nil)
        #expect(decoded.failedAttempts == 1)
    }

    // MARK: - Jeu biométrique

    /// Relecture de ee87c6b : Face ID bloqué après des échecs rend un état
    /// `nil`, que le déverrouillage par code lisait comme un jeu modifié.
    @Test("Un état biométrique illisible n'est pas un changement de visages")
    func unreadableBiometricStateIsNotAChange() {
        let armed = Data([1, 2, 3])
        #expect(ParentalLockPolicy.biometricSetChanged(armedState: armed, currentState: nil) == false)
        #expect(ParentalLockPolicy.biometricSetChanged(armedState: nil, currentState: armed) == false)
        #expect(ParentalLockPolicy.biometricSetChanged(armedState: armed, currentState: armed) == false)
        #expect(ParentalLockPolicy.biometricSetChanged(armedState: armed, currentState: Data([9])))
    }

    // MARK: - Comparaison

    @Test("La comparaison refuse deux longueurs différentes")
    func constantTimeEqualsRejectsLengthMismatch() {
        #expect(ParentalLockPolicy.constantTimeEquals(Data([1, 2, 3]), Data([1, 2])) == false)
        #expect(ParentalLockPolicy.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(ParentalLockPolicy.constantTimeEquals(Data(), Data()))
    }

    // MARK: - Biométrie (audit 2026-09-22, S4)

    /// Le code de l'appareil suffit pour AJOUTER un visage ou un doigt : le
    /// raccourci ne doit valoir que pour le jeu biométrique sur lequel il a été
    /// armé, et seul le code parental le réarme.
    @Test("La biométrie n'ouvre que le jeu enrôlé au moment de l'armement")
    func biometricsRequireTheArmedSet() {
        let armed = Data([1, 2, 3])
        #expect(ParentalLockPolicy.biometricsAllowed(armedState: armed, currentState: armed))
        #expect(!ParentalLockPolicy.biometricsAllowed(armedState: armed, currentState: Data([1, 2, 4])),
                "un visage ajouté change l'état")
        #expect(!ParentalLockPolicy.biometricsAllowed(armedState: nil, currentState: armed),
                "jamais armé (ou armé avant ce correctif) : le code d'abord")
        #expect(!ParentalLockPolicy.biometricsAllowed(armedState: armed, currentState: nil))
    }

    @Test("Un identifiant enregistré avant l'état biométrique se décode toujours")
    func legacyCredentialDecodes() throws {
        let legacy = #"{"salt":"AQI=","hash":"AwQ=","iterations":10,"failedAttempts":0,"biometricsEnabled":true}"#
        let decoded = try JSONDecoder().decode(ParentalLockCredential.self, from: Data(legacy.utf8))
        #expect(decoded.biometricsEnabled)
        #expect(decoded.biometricDomainState == nil)
    }
}
