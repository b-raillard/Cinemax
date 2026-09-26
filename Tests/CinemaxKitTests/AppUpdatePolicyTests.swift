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

    @Test("tvOS : la page de l'App Store se déduit du lien https")
    func tvAppStoreURLFromPage() throws {
        let page = try #require(URL(string: "https://apps.apple.com/ch/app/cinemax/id6747012345?uo=4"))
        #expect(AppStoreLookup.tvAppStoreURL(for: page)?.absoluteString
                == "com.apple.TVAppStore://itunes.apple.com/app/id6747012345")
    }

    @Test("tvOS : un lien sans identifiant numérique ne donne rien")
    func tvAppStoreURLRefusesMalformed() throws {
        for link in ["https://apps.apple.com/ch/app/cinemax", "https://apps.apple.com/app/id", "https://apps.apple.com/app/idabc"] {
            let page = try #require(URL(string: link))
            #expect(AppStoreLookup.tvAppStoreURL(for: page) == nil)
        }
    }
}

/// Audit 2026-09-22 (T5) : `AppUpdateChecker` porte deux RULES — la décision
/// se recalcule à chaque lancement depuis la version mémorisée (seule la
/// REQUÊTE est limitée à une par jour), et l'horodatage est posé AVANT l'attente
/// réseau. Aucun test ne les tenait.
@MainActor
@Suite("Vérification de version — orchestration")
struct AppUpdateCheckerTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    nonisolated private static func release(_ raw: String) -> AppStoreRelease {
        AppStoreRelease(version: ServerVersion(raw)!, displayVersion: raw, storeURL: URL(string: "https://apps.apple.com/app/id1"))
    }

    @Test("A stored newer release is offered again at launch without any request")
    func storedReleaseOfferedWithoutRequest() async {
        let defaults = UserDefaults.isolatedForTesting()
        let calls = Counter()
        let first = AppUpdateChecker(defaults: defaults, bundleId: "com.test") { _ in calls.increment(); return Self.release("99.0") }
        await first.refresh(now: Date(timeIntervalSince1970: 1_000_000))
        #expect(calls.count == 1)
        #expect(first.decision == .offer(Self.release("99.0")))

        // Next launch, same day: throttled — but the offer stands.
        let second = AppUpdateChecker(defaults: defaults, bundleId: "com.test") { _ in calls.increment(); return nil }
        await second.refresh(now: Date(timeIntervalSince1970: 1_000_000 + 3600))
        #expect(calls.count == 1, "one Store query a day")
        #expect(second.decision == .offer(Self.release("99.0")))
    }

    @Test("« Plus tard » silences that version only; a newer one speaks again")
    func declineIsPerVersion() async {
        let defaults = UserDefaults.isolatedForTesting()
        let checker = AppUpdateChecker(defaults: defaults, bundleId: "com.test") { _ in Self.release("99.0") }
        await checker.refresh(now: Date(timeIntervalSince1970: 1_000_000))
        checker.decline()
        #expect(checker.decision == .none)

        let nextDay = AppUpdateChecker(defaults: defaults, bundleId: "com.test") { _ in Self.release("99.1") }
        await nextDay.refresh(now: Date(timeIntervalSince1970: 1_000_000 + 2 * 86_400))
        #expect(nextDay.decision == .offer(Self.release("99.1")))
    }

    @Test("The check is stamped BEFORE the lookup: a second refresh during a slow one asks nothing")
    func stampedBeforeAwait() async {
        let defaults = UserDefaults.isolatedForTesting()
        let calls = Counter()
        let gate = TestLatch()
        let checker = AppUpdateChecker(defaults: defaults, bundleId: "com.test") { _ in
            calls.increment()
            await gate.wait()
            return nil
        }
        let slow = Task { await checker.refresh(now: Date(timeIntervalSince1970: 1_000_000)) }
        #expect(await eventually { calls.count == 1 })
        await checker.refresh(now: Date(timeIntervalSince1970: 1_000_000 + 60))
        #expect(calls.count == 1)
        gate.open()
        await slow.value
    }

    @Test("No Store page, no button")
    func noStoreURLNoButton() async {
        let defaults = UserDefaults.isolatedForTesting()
        let checker = AppUpdateChecker(defaults: defaults, bundleId: "com.test") { _ in
            AppStoreRelease(version: ServerVersion("99.0")!, displayVersion: "99.0", storeURL: nil)
        }
        await checker.refresh(now: Date(timeIntervalSince1970: 1_000_000))
        #expect(checker.storeURLToOpen == nil)
    }
}
