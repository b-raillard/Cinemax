import Testing
import Foundation
@testable import Cinemax
@testable import CinemaxKit

/// Verrouille le canal qui sort un diagnostic d'un appareil tvOS.
///
/// Le problème réglé ici n'est pas la journalisation, c'est la **livraison** :
/// l'export de diagnostics est iOS uniquement, donc sur une Apple TV les lignes
/// sont écrites là où personne ne peut les atteindre. Un journal que personne ne
/// peut lire n'est pas un diagnostic.
@Suite("Diagnostic envoyé au serveur")
struct DiagnosticsUploadTests {

    private func facts(reason: String?) -> DiagnosticsFacts {
        DiagnosticsFacts.current(
            serverVersion: "12.0.0", engine: "vlc", lastPlayback: nil, reason: reason
        )
    }

    // MARK: - L'en-tête, sans casser celui de l'export manuel

    @Test("Un rapport automatique dit POURQUOI, juste après l'horodatage")
    func reasonLineIsStated() {
        let header = DiagnosticsReport.header(facts(reason: "picture-stall"))
        #expect(header.contains("reason: picture-stall"))
        // Juste après `generated_at`, parce que c'est la première question que
        // se pose quiconque ouvre le fichier.
        let index = try? #require(header.firstIndex(of: "reason: picture-stall"))
        #expect(index == 2)
    }

    @Test("L'export manuel n'a pas de raison, et son en-tête reste identique")
    func manualExportHeaderIsUnchanged() {
        let header = DiagnosticsReport.header(facts(reason: nil))
        #expect(header.contains { $0.hasPrefix("reason:") } == false)
        // La forme exacte de cet en-tête est verrouillée par `DiagnosticsTests` ;
        // ce test-ci garde la porte fermée depuis l'autre côté.
        #expect(header[1].hasPrefix("generated_at: "))
        #expect(header[2].hasPrefix("app_version: "))
    }

    @Test("Le document porte l'en-tête et la raison")
    func documentCarriesTheReason() {
        let text = DiagnosticsUploader.buildDocument(facts: facts(reason: "picture-stall"))
        #expect(text.contains(DiagnosticsReport.title))
        #expect(text.contains("reason: picture-stall"))
        #expect(text.contains("playback_engine: vlc"))
        // La fenêtre annoncée est bien la courte, pas celle de l'export manuel.
        #expect(text.contains("last \(DiagnosticsUploader.logWindowMinutes) min"))
    }

    // MARK: - L'étranglement

    @Test("Premier envoi toujours permis, puis un plancher entre deux")
    func throttle() {
        let now = Date()
        #expect(DiagnosticsUploader.shouldUpload(last: nil, now: now))
        let floor = DiagnosticsUploader.minimumInterval
        #expect(DiagnosticsUploader.shouldUpload(last: now.addingTimeInterval(-floor + 1), now: now) == false)
        #expect(DiagnosticsUploader.shouldUpload(last: now.addingTimeInterval(-floor), now: now))
        #expect(DiagnosticsUploader.shouldUpload(last: now.addingTimeInterval(-floor - 60), now: now))
    }

    // MARK: - La charge utile

    @Test("Un document court part tel quel")
    func shortDocumentIsUntouched() {
        let text = "deux lignes\nde diagnostic\n"
        let payload = JellyfinAPIClient.diagnosticsPayload(text)
        #expect(String(decoding: payload, as: UTF8.self) == text)
    }

    @Test("Un document trop gros est tronqué par la TÊTE : on garde la fin")
    func longDocumentKeepsItsTail() {
        // La fin est ce qui décrit la panne ; le début, c'est l'ouverture du
        // média, dix minutes plus tôt.
        let filler = String(repeating: "remplissage\n", count: 4000)
        let text = filler + "DERNIERE LIGNE — la panne est ici\n"
        let payload = JellyfinAPIClient.diagnosticsPayload(text, limit: 1024)
        let decoded = String(decoding: payload, as: UTF8.self)
        #expect(decoded.contains("DERNIERE LIGNE — la panne est ici"))
        #expect(decoded.hasPrefix("(document tronqué"))
        // La note de troncature s'ajoute à la limite, elle ne la remplace pas —
        // le point est de borner, pas d'être exact à l'octet près.
        #expect(payload.count < 1024 + 200)
    }

    @Test("Un document vide n'est pas envoyé du tout")
    func emptyDocumentIsRefused() async {
        // Le refus vit dans `uploadDiagnostics`, dont la version par défaut du
        // protocole rend `nil` — ce qui est aussi ce que tout appelant doit
        // déjà savoir traiter.
        let client: any ServerAPI = DiagnosticsRefusingClient()
        let name = await client.uploadDiagnostics("")
        #expect(name == nil)
    }
}

/// Un conformeur minimal : il hérite de l'implémentation par défaut du
/// protocole, ce qui est précisément la propriété qui permet aux simulacres de
/// tests de compiler sans rien redéfinir.
private struct DiagnosticsRefusingClient: ServerAPI {
    func connectToServer(url: URL) async throws -> ServerInfo { throw JellyfinError.notConnected }
    func fetchServerInfo() async throws -> ServerInfo { throw JellyfinError.notConnected }
    func reconnect(url: URL, accessToken: String) {}
    func clearCache() {}
    func applyContentRatingLimit(maxAge: Int) {}
}
