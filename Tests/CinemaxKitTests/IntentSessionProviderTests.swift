import Testing
import Foundation
import CinemaxKit
@testable import Cinemax

/// The App Intents entity query runs **without the app's UI** — Siri resolves a
/// spoken title before deciding what to do, and the Shortcuts editor browses
/// items without ever presenting the app. So the session has to be rebuilt from
/// the Keychain alone, with no `AppState` and no SwiftUI.
///
/// These lock the two things that must not go wrong there: refusing to act when
/// there is no usable session, and never letting an intent see more than the
/// app itself would show.
@Suite("Intent session provider")
struct IntentSessionProviderTests {

    private func makeKeychain(
        entries: [ServerEntry],
        activeId: String?
    ) -> MockKeychain {
        let keychain = MockKeychain()
        keychain.savedServers = entries
        keychain.savedActiveServerId = activeId
        return keychain
    }

    private func signedInEntry(
        id: String = "server-a",
        url: String = "https://media.example.com"
    ) -> ServerEntry {
        ServerEntry(
            id: id,
            name: "Maison",
            url: URL(string: url)!,
            accessToken: "token-\(id)",
            userId: "user-\(id)"
        )
    }

    // MARK: Refusing to act

    @Test("No active server means no session")
    func noActiveServer() {
        let keychain = makeKeychain(entries: [signedInEntry()], activeId: nil)
        #expect(IntentSessionProvider.resolveContext(keychain: keychain) == nil)
    }

    @Test("An active id with no matching entry means no session")
    func danglingActiveId() {
        let keychain = makeKeychain(entries: [signedInEntry()], activeId: "server-gone")
        #expect(IntentSessionProvider.resolveContext(keychain: keychain) == nil)
    }

    @Test("A signed-out entry means no session")
    func signedOutEntry() {
        // Logging out strips credentials but keeps the entry so its card stays
        // in the servers list — an intent must not treat that as usable.
        let entry = ServerEntry(id: "server-a", url: URL(string: "https://media.example.com")!)
        let keychain = makeKeychain(entries: [entry], activeId: "server-a")
        #expect(IntentSessionProvider.resolveContext(keychain: keychain) == nil)
    }

    @Test("An entry with a token but no user id means no session")
    func tokenWithoutUser() {
        let entry = ServerEntry(
            id: "server-a",
            url: URL(string: "https://media.example.com")!,
            accessToken: "token"
        )
        let keychain = makeKeychain(entries: [entry], activeId: "server-a")
        #expect(IntentSessionProvider.resolveContext(keychain: keychain) == nil)
    }

    // MARK: Resolving

    @Test("A complete active entry resolves to its own credentials")
    func resolvesActiveEntry() throws {
        let keychain = makeKeychain(
            entries: [signedInEntry(id: "server-a"), signedInEntry(id: "server-b", url: "https://other.example.com")],
            activeId: "server-b"
        )
        let context = try #require(IntentSessionProvider.resolveContext(keychain: keychain))
        #expect(context.serverId == "server-b")
        #expect(context.userId == "user-server-b")
        #expect(context.accessToken == "token-server-b")
        #expect(context.serverURL == URL(string: "https://other.example.com")!)
    }

    // MARK: Parental controls

    @Test("The rating ceiling defaults to unrestricted")
    func ratingCeilingDefault() {
        let defaults = UserDefaults(suiteName: "intent-session-tests-default")!
        defaults.removePersistentDomain(forName: "intent-session-tests-default")
        #expect(IntentSessionProvider.contentRatingLimit(defaults: defaults) == 0)
    }

    @Test("The rating ceiling is read from settings so Siri can't bypass it")
    func ratingCeilingHonoured() {
        // Without this, an intent would surface titles the app itself hides —
        // Siri would become a way around the parental-controls setting.
        let suite = "intent-session-tests-capped"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(12, forKey: SettingsKey.privacyMaxContentAge)
        #expect(IntentSessionProvider.contentRatingLimit(defaults: defaults) == 12)
        defaults.removePersistentDomain(forName: suite)
    }
}

#if os(iOS)
/// Siri, Shortcuts and the Control Center « Reprendre » are ONE Pro feature
/// (spec 2026-10-22): in free, every intent answers « fonction Pro » and the
/// app — which `openAppWhenRun` has already opened — shows the Pro sheet.
@MainActor
@Suite("Intents et Pro")
struct IntentProGateTests {

    private func access(launched: Bool) -> ProFeatureAccess {
        ProFeatureAccess {
            ProFeatureGate.tier(proLaunched: launched, isPro: false, isEarlyAdopter: false, override: .automatic)
        }
    }

    @Test("Avant le lancement, un raccourci passe, sans feuille")
    func openBeforeLaunch() throws {
        let gate = access(launched: false)
        try IntentProGate.admit(gate)
        #expect(gate.upsell == nil)
    }

    @Test("En gratuit, l'intent répond « fonction Pro » et ouvre la feuille Pro des raccourcis")
    func freeIsRefused() {
        let gate = access(launched: true)
        #expect(throws: CinemaxIntentError.proRequired) { try IntentProGate.admit(gate) }
        #expect(gate.upsell == .shortcuts)
    }

    @Test("Le message « fonction Pro » existe dans chaque langue")
    func messageLocalized() throws {
        #expect(CinemaxIntentError.proRequired.key == "intent.error.proRequired")
        for lang in AppLanguage.supported {
            let path = try #require(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: lang))
            let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
            #expect(table["intent.error.proRequired"] != nil, "\(lang)")
        }
    }

    /// Recette 2026-10-23, DEF-IOS3: appareil en anglais, app en français →
    /// « Siri and Shortcuts are part of JellyGlass Pro ». The system resolved
    /// the key in the DEVICE's language.
    @Test("Les erreurs des intents parlent la langue de l'app, pas celle de l'appareil")
    func errorsFollowTheAppLanguage() throws {
        for lang in AppLanguage.supported {
            let path = try #require(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: lang))
            let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
            let defaults = UserDefaults.isolatedForTesting()
            defaults.set(lang, forKey: SettingsKey.appLanguage)
            for error in CinemaxIntentError.allCases {
                let expected = try #require(table[error.key], "\(lang) \(error.key)")
                #expect(String(localized: error.localizedStringResource(defaults: defaults)) == expected, "\(lang) \(error)")
            }
        }
    }
}
#endif
