import Testing
import Foundation
@testable import CinemaxKit
@testable import Cinemax

/// Verrouille la confiance explicite envers un certificat auto-signé (#186).
///
/// Ce qui doit tenir : la décision ne change RIEN pour un serveur ordinaire
/// (c'est la propriété de non-régression), un certificat que le système accepte
/// déjà n'a pas besoin d'épingle, et un certificat qui a CHANGÉ redemande une
/// approbation au lieu de se connecter en silence.
@Suite("Confiance certificat serveur")
struct ServerCertificateTrustTests {

    private let pin = "aa11bb22cc33"

    // MARK: - Décision

    @Test("Un défi qui n'est pas de confiance serveur est rendu tel quel")
    func nonTrustChallengeIsUntouched() {
        #expect(ServerCertificateTrust.decide(
            isServerTrustMethod: false, systemTrusts: false, leafFingerprint: "zz", expected: pin
        ) == .systemDefault)
    }

    @Test("Un certificat que le système accepte n'a PAS besoin d'épingle")
    func systemTrustWinsOverThePin() {
        // Load-bearing : un serveur qui passe plus tard à une vraie autorité —
        // ou qui renouvelle dans une AC privée que l'appareil connaît désormais —
        // continue de marcher sans que personne n'efface quoi que ce soit. Même
        // avec une épingle qui ne correspond plus.
        #expect(ServerCertificateTrust.decide(
            isServerTrustMethod: true, systemTrusts: true, leafFingerprint: "autre", expected: pin
        ) == .systemDefault)
    }

    @Test("Hôte sans épingle : comportement d'avant la fonctionnalité, au bit près")
    func unpinnedHostFallsThrough() {
        // C'est CETTE ligne qui rend la fonctionnalité invisible pour tous les
        // serveurs ordinaires : rien n'est accepté d'office, on rend la main.
        #expect(ServerCertificateTrust.decide(
            isServerTrustMethod: true, systemTrusts: false, leafFingerprint: "abc", expected: nil
        ) == .systemDefault)
        #expect(ServerCertificateTrust.decide(
            isServerTrustMethod: true, systemTrusts: false, leafFingerprint: "abc", expected: ""
        ) == .systemDefault)
    }

    @Test("L'épingle qui correspond accepte, la casse ne compte pas")
    func matchingPinAccepts() {
        #expect(ServerCertificateTrust.decide(
            isServerTrustMethod: true, systemTrusts: false, leafFingerprint: pin, expected: pin
        ) == .accept)
        #expect(ServerCertificateTrust.decide(
            isServerTrustMethod: true, systemTrusts: false, leafFingerprint: pin.uppercased(), expected: pin
        ) == .accept)
    }

    @Test("Certificat changé : refus, jamais une connexion silencieuse")
    func rotatedCertificateIsRefused() {
        #expect(ServerCertificateTrust.decide(
            isServerTrustMethod: true, systemTrusts: false, leafFingerprint: "dd44ee55", expected: pin
        ) == .fingerprintChanged)
    }

    @Test("Feuille illisible : on rend la main plutôt que d'accepter")
    func unreadableLeafFallsThrough() {
        #expect(ServerCertificateTrust.decide(
            isServerTrustMethod: true, systemTrusts: false, leafFingerprint: nil, expected: pin
        ) == .systemDefault)
    }

    // MARK: - Clé d'épinglage

    @Test("La clé est hôte:port, port par défaut rendu explicite")
    func trustKeyFillsTheDefaultPort() throws {
        // Les deux côtés explicitent le port, donc `https://nas.local` et
        // `https://nas.local:443` ne peuvent pas désigner deux épingles.
        #expect(ServerCertificateTrust.trustKey(for: try #require(URL(string: "https://nas.local"))) == "nas.local:443")
        #expect(ServerCertificateTrust.trustKey(for: try #require(URL(string: "https://nas.local:443"))) == "nas.local:443")
        #expect(ServerCertificateTrust.trustKey(for: try #require(URL(string: "http://nas.local"))) == "nas.local:80")
        #expect(ServerCertificateTrust.trustKey(for: try #require(URL(string: "https://nas.local:8920"))) == "nas.local:8920")
        // Un sous-chemin ne fait pas partie de l'identité TLS.
        #expect(ServerCertificateTrust.trustKey(for: try #require(URL(string: "https://nas.local/jellyfin"))) == "nas.local:443")
    }

    @Test("L'hôte est replié en minuscules, et une URL sans hôte n'a pas de clé")
    func trustKeyNormalisesHost() throws {
        #expect(ServerCertificateTrust.trustKey(for: try #require(URL(string: "https://NAS.Local"))) == "nas.local:443")
        #expect(ServerCertificateTrust.trustKey(for: try #require(URL(string: "file:///tmp/x"))) == nil)
    }

    // MARK: - Affichage

    @Test("L'empreinte s'affiche par paires, en majuscules")
    func fingerprintFormatting() {
        #expect(ServerCertificateTrust.formatFingerprint("aa11bb") == "AA:11:BB")
        #expect(ServerCertificateTrust.formatFingerprint("") == "")
        // Longueur impaire : rendue telle quelle plutôt que découpée de travers.
        #expect(ServerCertificateTrust.formatFingerprint("abc") == "ABC")
    }

    // MARK: - Détection de l'échec

    @MainActor
    @Test("Seules les erreurs DE CERTIFICAT ouvrent l'invite d'approbation")
    func certificateErrorDetection() {
        func urlError(_ code: Int) -> NSError {
            NSError(domain: NSURLErrorDomain, code: code)
        }
        // Les cinq codes retenus, plus larges que le seul -1202 de l'issue : un
        // certificat auto-signé ET périmé rapporte -1201, une AC privée -1203.
        for code in [-1200, -1201, -1202, -1203, -1204] {
            #expect(ServerSetupViewModel.isCertificateError(urlError(code)), "code \(code)")
        }
        // Hors ligne : pas un problème de certificat, l'invite ne doit pas sortir.
        #expect(ServerSetupViewModel.isCertificateError(urlError(NSURLErrorNotConnectedToInternet)) == false)
        #expect(ServerSetupViewModel.isCertificateError(NSError(domain: "autre", code: -1202)) == false)
        // Enveloppée : le SDK remonte l'erreur de transport des deux façons selon
        // le chemin d'appel, donc ne tester que l'enveloppe extérieure en rate la
        // moitié.
        let wrapped = NSError(
            domain: "Get.APIError",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: urlError(NSURLErrorServerCertificateUntrusted)]
        )
        #expect(ServerSetupViewModel.isCertificateError(wrapped))
    }
}
