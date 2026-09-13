import Foundation
import Testing
@testable import Cinemax
@testable import CinemaxKit

/// La décision « une nouvelle version est disponible » : elle décide de PARLER
/// ou de se taire, et le coût d'une erreur est asymétrique — une alerte qui
/// n'aurait pas dû s'afficher s'interpose entre l'utilisateur et son film.
@Suite("Vérification de version au lancement")
struct AppUpdatePolicyTests {

    private func release(_ raw: String, url: String? = "https://apps.apple.com/app/id1") -> AppStoreRelease {
        AppStoreRelease(
            version: ServerVersion(raw)!,
            displayVersion: raw,
            storeURL: url.flatMap(URL.init(string:))
        )
    }

    // MARK: - Silence

    @Test("Sans version installée lisible, on ne dit rien")
    func silentWithoutInstalledVersion() {
        let decision = AppUpdatePolicy.decide(
            installed: nil,
            release: release("2.1.0"),
            minimumSupported: nil,
            declinedVersion: nil
        )
        #expect(decision == .none)
    }

    @Test("Sans réponse du Store, on ne dit rien")
    func silentWithoutRelease() {
        let decision = AppUpdatePolicy.decide(
            installed: ServerVersion("2.0.0"),
            release: nil,
            minimumSupported: nil,
            declinedVersion: nil
        )
        #expect(decision == .none)
    }

    @Test("Une version du Store identique ou plus ancienne ne déclenche rien")
    func silentWhenStoreIsNotAhead() {
        let installed = ServerVersion("2.1.0")
        #expect(AppUpdatePolicy.decide(installed: installed, release: release("2.1.0"),
                                       minimumSupported: nil, declinedVersion: nil) == .none)
        #expect(AppUpdatePolicy.decide(installed: installed, release: release("2.0.9"),
                                       minimumSupported: nil, declinedVersion: nil) == .none)
    }

    // MARK: - Proposition

    @Test("Une version plus récente est proposée")
    func offersNewerVersion() {
        let newer = release("2.1.0")
        let decision = AppUpdatePolicy.decide(
            installed: ServerVersion("2.0.0"),
            release: newer,
            minimumSupported: nil,
            declinedVersion: nil
        )
        #expect(decision == .offer(newer))
    }

    @Test("La comparaison est numérique : 2.10 est plus récent que 2.9")
    func comparesNumericallyNotLexicographically() {
        let decision = AppUpdatePolicy.decide(
            installed: ServerVersion("2.9.0"),
            release: release("2.10.0"),
            minimumSupported: nil,
            declinedVersion: nil
        )
        #expect(decision == .offer(release("2.10.0")))
    }

    // MARK: - « Plus tard »

    @Test("« Plus tard » fait taire CETTE version")
    func declinedVersionStaysSilent() {
        let decision = AppUpdatePolicy.decide(
            installed: ServerVersion("2.0.0"),
            release: release("2.1.0"),
            minimumSupported: nil,
            declinedVersion: "2.1.0"
        )
        #expect(decision == .none)
    }

    @Test("« Plus tard » ne vaut pas pour les versions suivantes")
    func declinedVersionDoesNotSuppressLaterOnes() {
        let next = release("2.2.0")
        let decision = AppUpdatePolicy.decide(
            installed: ServerVersion("2.0.0"),
            release: next,
            minimumSupported: nil,
            declinedVersion: "2.1.0"
        )
        #expect(decision == .offer(next))
    }

    // MARK: - Obligatoire

    @Test("Sous le plancher, la mise à jour est imposée")
    func requiresUpdateBelowFloor() {
        let newer = release("2.1.0")
        let decision = AppUpdatePolicy.decide(
            installed: ServerVersion("2.0.0"),
            release: newer,
            minimumSupported: ServerVersion("2.1.0"),
            declinedVersion: nil
        )
        #expect(decision == .required(newer))
    }

    @Test("Une mise à jour imposée ignore un « Plus tard » précédent")
    func requiredIgnoresDecline() {
        let decision = AppUpdatePolicy.decide(
            installed: ServerVersion("2.0.0"),
            release: release("2.1.0"),
            minimumSupported: ServerVersion("2.1.0"),
            declinedVersion: "2.1.0"
        )
        #expect(decision == .required(release("2.1.0")))
    }

    /// Le garde-fou qui rend la constante sûre à poser dans l'urgence : un
    /// plancher au-dessus de ce que le Store propose enfermerait l'utilisateur
    /// dans une app qu'il n'a aucun moyen de réparer.
    @Test("Un plancher au-dessus du Store n'enferme personne")
    func neverRequiresWithoutSomethingToInstall() {
        let decision = AppUpdatePolicy.decide(
            installed: ServerVersion("2.0.0"),
            release: release("2.0.0"),
            minimumSupported: ServerVersion("3.0.0"),
            declinedVersion: nil
        )
        #expect(decision == .none)
    }

    @Test("Au niveau du plancher, la mise à jour redevient facultative")
    func atFloorTheUpdateIsOptional() {
        let newer = release("2.2.0")
        let decision = AppUpdatePolicy.decide(
            installed: ServerVersion("2.1.0"),
            release: newer,
            minimumSupported: ServerVersion("2.1.0"),
            declinedVersion: nil
        )
        #expect(decision == .offer(newer))
    }

    // MARK: - Cadence de la requête

    @Test("Jamais interrogé : on interroge")
    func queriesWhenNeverChecked() {
        #expect(AppUpdatePolicy.shouldQueryStore(lastCheckedAt: nil, now: Date()))
    }

    @Test("Dans l'intervalle : on n'interroge pas")
    func skipsQueryInsideInterval() {
        let now = Date()
        let recent = now.addingTimeInterval(-3600)
        #expect(!AppUpdatePolicy.shouldQueryStore(lastCheckedAt: recent, now: now))
    }

    @Test("Passé l'intervalle : on interroge")
    func queriesAfterInterval() {
        let now = Date()
        let old = now.addingTimeInterval(-AppUpdatePolicy.checkInterval - 1)
        #expect(AppUpdatePolicy.shouldQueryStore(lastCheckedAt: old, now: now))
    }

    /// Une horloge reculée (fuseau, correction NTP) ne doit pas museler la
    /// vérification jusqu'à ce que le futur la rattrape.
    @Test("Une horloge reculée ne muselle pas la vérification")
    func queriesWhenClockWentBackwards() {
        let now = Date()
        let future = now.addingTimeInterval(86_400 * 30)
        #expect(AppUpdatePolicy.shouldQueryStore(lastCheckedAt: future, now: now))
    }
}

/// La forme du fil : ce que le lookup d'Apple renvoie réellement, verrouillé
/// par une charge utile plutôt que par une requête en direct.
@Suite("Lecture de la réponse de l'App Store")
struct AppStoreLookupParsingTests {

    private func payload(_ json: String) -> Data { Data(json.utf8) }

    @Test("Une réponse complète donne la version et le lien")
    func parsesCompletePayload() {
        let data = payload("""
        {"resultCount":1,"results":[
          {"version":"2.1.0","trackViewUrl":"https://apps.apple.com/fr/app/cinemax/id123"}
        ]}
        """)
        let release = AppStoreLookup.parse(data)
        #expect(release?.displayVersion == "2.1.0")
        #expect(release?.version == ServerVersion(2, 1, 0))
        #expect(release?.storeURL?.host == "apps.apple.com")
    }

    /// La chaîne affichée est celle du Store, pas celle de `ServerVersion` :
    /// `description` normalise sur quatre composants, donc « 2.1 » se
    /// présenterait comme « 2.1.0.0 » devant l'utilisateur.
    @Test("La chaîne affichée reste celle du Store")
    func keepsStoreSpellingForDisplay() {
        let release = AppStoreLookup.parse(payload(#"{"results":[{"version":"2.1"}]}"#))
        #expect(release?.displayVersion == "2.1")
        #expect(release?.version == ServerVersion(2, 1, 0, 0))
    }

    @Test("Un Store qui ne connaît pas l'app ne donne rien")
    func emptyResultsYieldNothing() {
        #expect(AppStoreLookup.parse(payload(#"{"resultCount":0,"results":[]}"#)) == nil)
    }

    @Test("Une entrée sans version ne donne rien")
    func missingVersionYieldsNothing() {
        #expect(AppStoreLookup.parse(payload(#"{"results":[{"trackViewUrl":"https://x.test"}]}"#)) == nil)
    }

    @Test("Une version illisible ne donne rien")
    func unparsableVersionYieldsNothing() {
        #expect(AppStoreLookup.parse(payload(#"{"results":[{"version":"bêta"}]}"#)) == nil)
    }

    /// Le lien vient du réseau et sert à ouvrir une page : tout ce qui n'est pas
    /// `https` est jeté, et la version reste utilisable sans lui — sur iOS le
    /// bouton disparaît, il ne devient pas mort.
    @Test("Un lien non-https est jeté, la version reste")
    func rejectsNonHTTPSLink() {
        let release = AppStoreLookup.parse(
            payload(#"{"results":[{"version":"2.1.0","trackViewUrl":"javascript:alert(1)"}]}"#)
        )
        #expect(release?.displayVersion == "2.1.0")
        #expect(release?.storeURL == nil)
    }

    @Test("Une réponse illisible ne donne rien")
    func garbageYieldsNothing() {
        #expect(AppStoreLookup.parse(payload("pas du json")) == nil)
        #expect(AppStoreLookup.parse(Data()) == nil)
    }
}
