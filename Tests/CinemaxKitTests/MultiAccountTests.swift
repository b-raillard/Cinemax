import Testing
import Foundation
import Observation
@testable import CinemaxKit
@testable import Cinemax

// MARK: - Registry: remembered accounts

@Suite("Comptes mémorisés — registre")
struct SavedAccountRegistryTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func server(token: String? = "tokA", userId: String? = "A", username: String? = "Alice") -> ServerEntry {
        ServerEntry(
            name: "Maison",
            url: ServerURLNormalizer.normalize("https://maison.local")!,
            accessToken: token,
            userId: userId,
            username: username,
            lastUsedAt: t0
        )
    }

    @Test("Un registre sans savedAccounts se décode (champ optionnel)")
    func legacyDecode() throws {
        let legacy = """
        [{"id":"S1","name":"Maison","url":"https://maison.local","accessToken":"tokA","userId":"A","username":"Alice","lastUsedAt":0}]
        """
        let decoded = try JSONDecoder().decode([ServerEntry].self, from: Data(legacy.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].savedAccounts == nil)
        #expect(ServerRegistry.accounts(of: decoded[0]).map(\.userId) == ["A"])
    }

    @Test("accounts(of:) inclut le compte actif, sans doublon, le plus récent d'abord")
    func accountsIncludeActive() {
        var entry = server()
        entry = ServerRegistry.remembering(userId: "B", username: "Bob", accessToken: "tokB", at: t0.addingTimeInterval(60), in: entry)
        entry = ServerRegistry.remembering(userId: "A", username: "Alice", accessToken: "tokA", at: t0, in: entry)
        let ids = ServerRegistry.accounts(of: entry).map(\.userId)
        #expect(ids == ["B", "A"])
    }

    @Test("Un serveur déconnecté n'a aucun compte actif à lister")
    func signedOutHasNoActive() {
        let entry = server(token: nil, userId: nil, username: nil)
        #expect(ServerRegistry.accounts(of: entry).isEmpty)
    }

    @Test("remembering met à jour un compte existant par userId")
    func rememberingUpdates() {
        var entry = ServerRegistry.remembering(userId: "B", username: "Bob", accessToken: "old", at: t0, in: server())
        entry = ServerRegistry.remembering(userId: "B", username: "Bobby", accessToken: "new", at: t0.addingTimeInterval(5), in: entry)
        let b = entry.savedAccounts?.filter { $0.userId == "B" }
        #expect(b?.count == 1)
        #expect(b?.first?.accessToken == "new")
        #expect(b?.first?.username == "Bobby")
    }

    @Test("activating recopie le compte dans le triplet et garde l'ancien actif mémorisé")
    func activatingSwaps() throws {
        let base = ServerRegistry.remembering(userId: "B", username: "Bob", accessToken: "tokB", at: t0, in: server())
        let switched = try #require(ServerRegistry.activating(userId: "B", in: base))
        #expect(switched.userId == "B")
        #expect(switched.accessToken == "tokB")
        #expect(switched.username == "Bob")
        #expect(Set(ServerRegistry.accounts(of: switched).map(\.userId)) == ["A", "B"])
        #expect(switched.id == base.id)
    }

    @Test("activating d'un compte inconnu rend nil")
    func activatingUnknown() {
        #expect(ServerRegistry.activating(userId: "Z", in: server()) == nil)
    }

    @Test("forgetting d'un compte inactif laisse le triplet intact")
    func forgettingOther() {
        let base = ServerRegistry.remembering(userId: "B", username: "Bob", accessToken: "tokB", at: t0, in: server())
        let after = ServerRegistry.forgetting(userId: "B", in: base)
        #expect(after.userId == "A")
        #expect(after.accessToken == "tokA")
        #expect(ServerRegistry.accounts(of: after).map(\.userId) == ["A"])
    }

    @Test("forgetting du compte actif vide le triplet")
    func forgettingActive() {
        let base = ServerRegistry.remembering(userId: "B", username: "Bob", accessToken: "tokB", at: t0, in: server())
        let after = ServerRegistry.forgetting(userId: "A", in: base)
        #expect(after.userId == nil)
        #expect(after.accessToken == nil)
        #expect(after.username == nil)
        #expect(ServerRegistry.accounts(of: after).map(\.userId) == ["B"])
    }

    @Test("nextAccount prend le plus récent des autres comptes")
    func nextAccount() {
        var entry = ServerRegistry.remembering(userId: "B", username: "Bob", accessToken: "tokB", at: t0.addingTimeInterval(10), in: server())
        entry = ServerRegistry.remembering(userId: "C", username: "Carl", accessToken: "tokC", at: t0.addingTimeInterval(20), in: entry)
        #expect(ServerRegistry.nextAccount(after: "A", in: entry)?.userId == "C")
        #expect(ServerRegistry.nextAccount(after: "C", in: ServerRegistry.forgetting(userId: "B", in: entry))?.userId == "A")
    }

    @Test("upsert conserve les comptes mémorisés et met à jour le jeton du compte entrant")
    func upsertPreservesAccounts() {
        let stored = ServerRegistry.remembering(userId: "B", username: "Bob", accessToken: "tokB", at: t0, in: server())
        // A login as B arrives as a bare entry (no savedAccounts), as every caller builds it.
        let incoming = ServerEntry(
            name: "Maison",
            url: ServerURLNormalizer.normalize("https://maison.local")!,
            accessToken: "tokB2",
            userId: "B",
            username: "Bob",
            lastUsedAt: t0.addingTimeInterval(30)
        )
        let merged = ServerRegistry.upsert(incoming, into: [stored])
        #expect(merged.count == 1)
        let accounts = ServerRegistry.accounts(of: merged[0])
        #expect(Set(accounts.map(\.userId)) == ["A", "B"])
        #expect(accounts.first { $0.userId == "B" }?.accessToken == "tokB2")
        #expect(merged[0].userId == "B")
    }

    @Test("La clé de compte combine serveur et utilisateur")
    func accountKey() {
        #expect(ServerRegistry.accountKey(serverId: "S1", userId: "A") == "S1|A")
    }

    // MARK: Session closed, account kept (free switch, 2026-10-20)

    @Test("droppingSession garde le compte inactif, sans jeton, et laisse l'actif intact")
    func droppingSessionKeepsAccount() {
        let base = ServerRegistry.remembering(userId: "B", username: "Bob", accessToken: "tokB", at: t0, in: server())
        let after = ServerRegistry.droppingSession(userId: "B", in: base)
        let bob = ServerRegistry.accounts(of: after).first { $0.userId == "B" }
        #expect(bob?.hasSession == false)
        #expect(bob?.username == "Bob")
        #expect(after.userId == "A")
        #expect(after.accessToken == "tokA")
    }

    @Test("droppingSession du compte présent seulement dans le triplet le garde listé, sans jeton")
    func droppingSessionOfTripleOnlyAccount() {
        let after = ServerRegistry.droppingSession(userId: "A", in: server())
        let accounts = ServerRegistry.accounts(of: after)
        #expect(accounts.map(\.userId) == ["A"])
        #expect(accounts.first?.hasSession == false)
        #expect(after.accessToken == nil)
        #expect(after.userId == nil)
    }

    @Test("droppingSession d'un compte inconnu ne change rien")
    func droppingSessionOfUnknownIsNoOp() {
        let base = server()
        #expect(ServerRegistry.droppingSession(userId: "Z", in: base) == base)
    }

    @Test("activating d'un compte sans session rend un triplet sans jeton (AppState refuse)")
    func activatingSessionlessAccount() throws {
        let base = ServerRegistry.droppingSession(
            userId: "B",
            in: ServerRegistry.remembering(userId: "B", username: "Bob", accessToken: "tokB", at: t0, in: server())
        )
        let switched = try #require(ServerRegistry.activating(userId: "B", in: base))
        #expect(switched.accessToken == "")
    }

    @Test("upsert d'une connexion de A ne redonne pas de jeton à B déconnecté")
    func upsertKeepsSessionlessAccount() {
        let stored = ServerRegistry.droppingSession(
            userId: "B",
            in: ServerRegistry.remembering(userId: "B", username: "Bob", accessToken: "tokB", at: t0, in: server())
        )
        let incoming = ServerEntry(name: "Maison", url: ServerURLNormalizer.normalize("https://maison.local")!,
                                   accessToken: "tokA2", userId: "A", username: "Alice", lastUsedAt: t0.addingTimeInterval(30))
        let merged = ServerRegistry.upsert(incoming, into: [stored])
        let bob = ServerRegistry.accounts(of: merged[0]).first { $0.userId == "B" }
        #expect(bob?.hasSession == false)
    }

    @Test("nextAccount préfère un compte qui a encore une session")
    func nextAccountPrefersSession() {
        var entry = ServerRegistry.remembering(userId: "B", username: "Bob", accessToken: "tokB", at: t0.addingTimeInterval(10), in: server())
        entry = ServerRegistry.remembering(userId: "C", username: "Carl", accessToken: "tokC", at: t0.addingTimeInterval(20), in: entry)
        entry = ServerRegistry.droppingSession(userId: "C", in: entry)
        #expect(ServerRegistry.nextAccount(after: "A", in: entry)?.userId == "B")
    }
}

// MARK: - Revocation of ONE token

/// `DELETE /Devices?id=` needed an administrator and revoked EVERY token of the
/// device id (all users): a non-admin's logout never revoked anything, and with
/// several remembered accounts an admin's logout would have killed them all.
@Suite("Révocation de session — un seul jeton")
struct SessionRevokeRequestTests {

    @Test("POST /Sessions/Logout, authentifié par le jeton révoqué, sans identifiant d'appareil en query")
    func logoutRequest() throws {
        let request = try #require(ServerSessionRevoker.makeRequest(
            url: URL(string: "https://maison.local/jellyfin")!,
            accessToken: "tokB",
            deviceId: "dev-1"
        ))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://maison.local/jellyfin/Sessions/Logout")
        let auth = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(auth.contains("Token=tokB"))
        #expect(auth.contains("DeviceId=dev-1"))
    }

    @Test("Rien à révoquer sans jeton")
    func noToken() {
        #expect(ServerSessionRevoker.makeRequest(url: URL(string: "https://maison.local")!, accessToken: "", deviceId: "dev-1") == nil)
    }
}

// MARK: - AppState orchestration

/// Collects the tokens `AppState` revokes, from its background tasks.
private actor RevokedTokens {
    private(set) var tokens: [String] = []
    func record(_ token: String) { tokens.append(token) }
}

@MainActor
@Suite("Multi-comptes — AppState")
struct MultiAccountAppStateTests {

    private let url = ServerURLNormalizer.normalize("https://maison.local")!

    /// Server « Maison » signed in as Alice (A) with Bob (B) remembered.
    private func household(rememberBob: Bool = true) -> ServerEntry {
        var entry = ServerEntry(id: "S1", name: "Maison", url: url, serverID: "srv",
                                accessToken: "tokA", userId: "A", username: "Alice",
                                lastUsedAt: Date(timeIntervalSince1970: 1_000))
        if rememberBob {
            entry = ServerRegistry.remembering(userId: "B", username: "Bob", accessToken: "tokB",
                                               at: Date(timeIntervalSince1970: 500), in: entry)
        }
        return entry
    }

    private func makeState(
        api: MockAPIClient,
        keychain: MockKeychain = MockKeychain(),
        servers: [ServerEntry],
        multiAccount: Bool = true,
        revoked: RevokedTokens? = nil
    ) -> AppState {
        keychain.savedServers = servers
        keychain.savedActiveServerId = servers.first?.id
        let app = AppState(apiClient: api, keychain: keychain)
        app.sessionValidator = { _, _ in await api.validateSession() }
        app.multiAccountProvider = { multiAccount }
        if let revoked {
            app.sessionRevoker = { _, token in await revoked.record(token) }
        } else {
            app.sessionRevoker = { _, _ in }
        }
        app.loadServersFromKeychain()
        app.serverURL = url
        app.hasServer = true
        app.isAuthenticated = true
        app.accessToken = servers.first?.accessToken
        app.currentUserId = servers.first?.userId
        return app
    }

    @Test("Bascule validée : le compte cible devient actif, client et miroir suivent, l'autre reste mémorisé")
    func switchValid() async {
        let api = MockAPIClient()
        api.stubbedValidity = .valid
        let kc = MockKeychain()
        let app = makeState(api: api, keychain: kc, servers: [household()])

        let result = await app.switchAccount(to: "B")

        #expect(result == .switched)
        #expect(app.currentUserId == "B")
        #expect(app.accessToken == "tokB")
        #expect(app.activeServerId == "S1")
        #expect(app.activeAccountKey == "S1|B")
        #expect(api.reconnectedTokens.last == "tokB")
        #expect(kc.savedSession?.userID == "B")
        #expect(Set(app.activeAccounts.map(\.userId)) == ["A", "B"])
    }

    @Test("Bascule refusée par le serveur : compte marqué expiré, rien d'autre ne bouge")
    func switchInvalid() async {
        let api = MockAPIClient()
        api.stubbedValidity = .invalid
        let app = makeState(api: api, servers: [household()])

        let result = await app.switchAccount(to: "B")

        #expect(result == .needsLogin)
        #expect(app.currentUserId == "A")
        #expect(app.expiredAccountIds.contains("S1|B"))
        #expect(api.reconnectedTokens.isEmpty)
        // Kept: the user may reconnect it.
        #expect(app.activeAccounts.contains { $0.userId == "B" })
    }

    @Test("Bascule indéterminée (serveur lent) : rien n'est détruit")
    func switchIndeterminate() async {
        let api = MockAPIClient()
        api.stubbedValidity = .indeterminate
        let app = makeState(api: api, servers: [household()])

        #expect(await app.switchAccount(to: "B") == .unreachable)
        #expect(app.currentUserId == "A")
        #expect(app.expiredAccountIds.isEmpty)
        #expect(api.reconnectedTokens.isEmpty)
    }

    @Test("Bascule hors ligne : aucun appel")
    func switchOffline() async {
        let api = MockAPIClient()
        let app = makeState(api: api, servers: [household()])
        app.isOnlineProvider = { false }

        #expect(await app.switchAccount(to: "B") == .offline)
        #expect(api.validateSessionCallCount == 0)
        #expect(app.currentUserId == "A")
    }

    @Test("Ajout en Pro : le nouveau compte devient actif, les autres restent")
    func addPro() async {
        let api = MockAPIClient()
        let revoked = RevokedTokens()
        let app = makeState(api: api, servers: [household(rememberBob: false)], revoked: revoked)

        await app.addAccount(session: UserSession(userID: "C", username: "Carl", accessToken: "tokC", serverID: "srv"))

        #expect(app.currentUserId == "C")
        #expect(Set(app.activeAccounts.map(\.userId)) == ["A", "C"])
        #expect(await revoked.tokens.isEmpty)
    }

    @Test("Connexion en gratuit : l'ancien compte reste listé, sans session, son jeton révoqué, ses réglages gardés")
    func freeSignInKeepsOthersListed() async throws {
        let api = MockAPIClient()
        let revoked = RevokedTokens()
        let app = makeState(api: api, servers: [household(rememberBob: false)], multiAccount: false, revoked: revoked)
        app.settingsDefaults = .isolatedForTesting()

        await app.addAccount(session: UserSession(userID: "C", username: "Carl", accessToken: "tokC", serverID: "srv"))

        #expect(app.currentUserId == "C")
        #expect(Set(app.activeAccounts.map(\.userId)) == ["A", "C"])
        let alice = try #require(app.activeAccounts.first { $0.userId == "A" })
        #expect(alice.hasSession == false)
        #expect(await eventually { await revoked.tokens == ["tokA"] })
        #expect(AccountSettingsStore.load(for: "S1|A", defaults: app.settingsDefaults) != nil)
    }

    @Test("Connexion en gratuit : un jeton resté d'une période Pro est révoqué aussi")
    func freeSignInDropsLeftoverTokens() async throws {
        let api = MockAPIClient()
        let revoked = RevokedTokens()
        let app = makeState(api: api, servers: [household()], multiAccount: false, revoked: revoked)

        await app.addAccount(session: UserSession(userID: "A", username: "Alice", accessToken: "tokA2", serverID: "srv"))

        let bob = try #require(app.activeAccounts.first { $0.userId == "B" })
        #expect(bob.hasSession == false)
        #expect(await eventually { await revoked.tokens.contains("tokB") })
        #expect(app.currentUserId == "A")
    }

    @Test("Bascule en gratuit : toujours une connexion, même avec un jeton valide, sans appel serveur")
    func freeSwitchNeedsSignIn() async {
        let api = MockAPIClient()
        api.stubbedValidity = .valid
        let app = makeState(api: api, servers: [household()], multiAccount: false)

        #expect(await app.switchAccount(to: "B") == .needsLogin)
        #expect(app.currentUserId == "A")
        #expect(api.validateSessionCallCount == 0)
    }

    @Test("Bascule en gratuit hors ligne : hors ligne, pas de connexion vouée à l'échec")
    func freeSwitchOffline() async {
        let api = MockAPIClient()
        let app = makeState(api: api, servers: [household()], multiAccount: false)
        app.isOnlineProvider = { false }

        #expect(await app.switchAccount(to: "B") == .offline)
    }

    @Test("Bascule en Pro vers un compte sans session : connexion, sans appel serveur")
    func proSwitchSessionlessNeedsLogin() async {
        let api = MockAPIClient()
        let entry = ServerRegistry.droppingSession(userId: "B", in: household())
        let app = makeState(api: api, servers: [entry])

        #expect(await app.switchAccount(to: "B") == .needsLogin)
        #expect(api.validateSessionCallCount == 0)
    }

    @Test("Retirer un compte non actif : révoqué et oublié, la session active intacte")
    func removeOther() async {
        let api = MockAPIClient()
        let revoked = RevokedTokens()
        let app = makeState(api: api, servers: [household()], revoked: revoked)

        await app.removeAccount(userId: "B")

        #expect(app.currentUserId == "A")
        #expect(app.accessToken == "tokA")
        #expect(app.activeAccounts.map(\.userId) == ["A"])
        #expect(api.reconnectedTokens.isEmpty)
        #expect(await eventually { await revoked.tokens == ["tokB"] })
    }

    @Test("Déconnexion du compte actif : bascule vers un autre compte du même serveur avant tout autre serveur")
    func logoutHopsToSameServerAccount() async {
        let api = MockAPIClient()
        api.stubbedValidity = .valid
        let other = ServerEntry(id: "S2", name: "Chalet", url: ServerURLNormalizer.normalize("https://chalet.local")!,
                                accessToken: "tokZ", userId: "Z", username: "Zoé",
                                lastUsedAt: Date(timeIntervalSince1970: 9_999_999))
        let revoked = RevokedTokens()
        let app = makeState(api: api, servers: [household(), other], revoked: revoked)

        let outcome = await app.logout(reason: .userInitiated)

        #expect(outcome == .switchedAccount(name: "Bob"))
        #expect(app.activeServerId == "S1")
        #expect(app.currentUserId == "B")
        // The signed-out account is gone from the list, token included.
        #expect(app.activeAccounts.map(\.userId) == ["B"])
        #expect(await eventually { await revoked.tokens == ["tokA"] })
    }

    @Test("Une déconnexion ne laisse aucun jeton du compte dans la liste mémorisée")
    func logoutForgetsToken() async {
        let app = makeState(api: MockAPIClient(), servers: [household(rememberBob: false)])

        _ = await app.logout(reason: .sessionExpired)

        let stored = app.servers.first { $0.id == "S1" }
        #expect(stored?.accessToken == nil)
        #expect(ServerRegistry.accounts(of: stored!).isEmpty)
        #expect(stored?.savedAccounts?.contains { $0.accessToken == "tokA" } != true)
    }
}

// MARK: - Per-account settings (age cap, accent, theme)

@Suite("Réglages par compte")
struct AccountSettingsTests {

    @Test("Échange : l'ancien compte est sauvé, le nouveau chargé ; sans instantané on hérite")
    func swapAndInherit() {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set(10, forKey: SettingsKey.privacyMaxContentAge)
        defaults.set("orange", forKey: SettingsKey.accentColor)
        defaults.set(true, forKey: SettingsKey.darkMode)

        // A → B, B never seen: B inherits A's values (a restricted device stays restricted).
        let first = AccountSettingsStore.swap(from: "S1|A", to: "S1|B", defaults: defaults)
        #expect(first == nil)
        #expect(defaults.integer(forKey: SettingsKey.privacyMaxContentAge) == 10)

        // B changes its own values, then B → A restores A's.
        defaults.set(0, forKey: SettingsKey.privacyMaxContentAge)
        defaults.set("blue", forKey: SettingsKey.accentColor)
        defaults.set(false, forKey: SettingsKey.darkMode)
        let back = AccountSettingsStore.swap(from: "S1|B", to: "S1|A", defaults: defaults)
        #expect(back == AccountSettingsSnapshot(maxContentAge: 10, accentColor: "orange", darkMode: true))
        #expect(defaults.integer(forKey: SettingsKey.privacyMaxContentAge) == 10)

        // …and A → B brings B's own values back.
        let again = AccountSettingsStore.swap(from: "S1|A", to: "S1|B", defaults: defaults)
        #expect(again == AccountSettingsSnapshot(maxContentAge: 0, accentColor: "blue", darkMode: false))
    }

    @Test("Retirer un compte efface son instantané ; retirer un serveur, ceux de ses comptes")
    func removal() {
        let defaults = UserDefaults.isolatedForTesting()
        AccountSettingsStore.save(AccountSettingsSnapshot(maxContentAge: 12, accentColor: "red", darkMode: true), for: "S1|A", defaults: defaults)
        AccountSettingsStore.save(AccountSettingsSnapshot(maxContentAge: 0, accentColor: "red", darkMode: true), for: "S1|B", defaults: defaults)
        AccountSettingsStore.save(AccountSettingsSnapshot(maxContentAge: 0, accentColor: "red", darkMode: true), for: "S2|A", defaults: defaults)

        AccountSettingsStore.remove(accountKey: "S1|A", defaults: defaults)
        #expect(AccountSettingsStore.load(for: "S1|A", defaults: defaults) == nil)
        AccountSettingsStore.removeServer(serverId: "S1", defaults: defaults)
        #expect(AccountSettingsStore.load(for: "S1|B", defaults: defaults) == nil)
        #expect(AccountSettingsStore.load(for: "S2|A", defaults: defaults) != nil)
    }

    @MainActor
    @Test("Une bascule applique la limite d'âge du compte cible AVANT de recharger")
    func switchAppliesAgeCap() async {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set(0, forKey: SettingsKey.privacyMaxContentAge)
        AccountSettingsStore.save(AccountSettingsSnapshot(maxContentAge: 10, accentColor: "green", darkMode: true),
                                  for: "S1|B", defaults: defaults)
        let api = MockAPIClient()
        api.stubbedValidity = .valid
        let kc = MockKeychain()
        var entry = ServerEntry(id: "S1", name: "Maison", url: ServerURLNormalizer.normalize("https://maison.local")!,
                                accessToken: "tokA", userId: "A", username: "Alice")
        entry = ServerRegistry.remembering(userId: "B", username: "Bob", accessToken: "tokB", at: Date(), in: entry)
        kc.savedServers = [entry]
        kc.savedActiveServerId = "S1"
        let app = AppState(apiClient: api, keychain: kc)
        app.settingsDefaults = defaults
        app.sessionValidator = { _, _ in .valid }
        app.multiAccountProvider = { true }   // a one-tap switch is Pro
        app.loadServersFromKeychain()
        app.currentUserId = "A"
        app.isAuthenticated = true

        await app.switchAccount(to: "B")

        #expect(api.appliedRatingLimits.last == 10)
        #expect(defaults.integer(forKey: SettingsKey.privacyMaxContentAge) == 10)
        #expect(AccountSettingsStore.load(for: "S1|A", defaults: defaults)?.maxContentAge == 0)
    }
}

// MARK: - Per-account code

final class InMemoryAccountLockStorage: AccountLockStorage, @unchecked Sendable {
    var items: [String: ParentalLockCredential] = [:]
    func getAccountLock(key: String) -> ParentalLockCredential? { items[key] }
    func saveAccountLock(_ credential: ParentalLockCredential, key: String) throws { items[key] = credential }
    func deleteAccountLock(key: String) { items[key] = nil }
}

@MainActor
@Suite("Code par compte")
struct AccountLockTests {

    @Test("Un code de compte à 4 chiffres est accepté ; le contrôle parental exige toujours 6")
    func pinLengths() {
        #expect(ParentalLockPolicy.makeCredential(pin: "1234", minimumLength: ParentalLockPolicy.accountPINLength,
                                                  biometricsEnabled: false, iterations: 1) != nil)
        #expect(ParentalLockPolicy.makeCredential(pin: "1234", biometricsEnabled: false, iterations: 1) == nil)
        #expect(ParentalLockPolicy.makeCredential(pin: "12a4", minimumLength: 4, biometricsEnabled: false, iterations: 1) == nil)
    }

    @Test("Enrôler, vérifier, retirer ; deux comptes sont indépendants")
    func enrolVerifyRemove() async {
        let storage = InMemoryAccountLockStorage()
        let locks = AccountLockStore(storage: storage, iterations: 1)

        #expect(await locks.enroll(key: "S1|A", pin: "1234", useBiometrics: false))
        #expect(locks.hasLock("S1|A"))
        #expect(!locks.hasLock("S1|B"))

        if case .wrong = await locks.verify(key: "S1|A", pin: "0000") {} else { Issue.record("a wrong code must be refused") }
        if case .unlocked = await locks.verify(key: "S1|A", pin: "1234") {} else { Issue.record("the right code must unlock") }

        locks.remove(key: "S1|A")
        #expect(!locks.hasLock("S1|A"))
        #expect(storage.items.isEmpty)
    }

    @Test("Passé les essais libres, la pause refuse même le bon code")
    func backoff() async {
        let locks = AccountLockStore(storage: InMemoryAccountLockStorage(), iterations: 1)
        _ = await locks.enroll(key: "S1|A", pin: "1234", useBiometrics: false)
        for _ in 0...ParentalLockPolicy.freeAttempts { _ = await locks.verify(key: "S1|A", pin: "0000") }
        if case .throttled = await locks.verify(key: "S1|A", pin: "1234") {} else { Issue.record("a throttled window refuses even the right code") }
    }

    @Test("Ajouter ou retirer un code redessine les vues qui lisent hasLock")
    func codeChangesAreObserved() async {
        final class Flag: @unchecked Sendable { var fired = false }
        let locks = AccountLockStore(storage: InMemoryAccountLockStorage(), iterations: 1)
        _ = await locks.enroll(key: "S1|A", pin: "1234", useBiometrics: false)

        let removal = Flag()
        withObservationTracking { _ = locks.hasLock("S1|A") } onChange: { removal.fired = true }
        locks.remove(key: "S1|A")
        #expect(removal.fired, "the toggle stayed on after removing the code (recette 2026-10-12)")

        let enrolment = Flag()
        withObservationTracking { _ = locks.hasLock("S1|A") } onChange: { enrolment.fired = true }
        _ = await locks.enroll(key: "S1|A", pin: "5678", useBiometrics: false)
        #expect(enrolment.fired)
    }

    @Test("AppState refuse de basculer vers un compte protégé sans code vérifié (Pro) ; en gratuit le code est ignoré",
          arguments: [true, false])
    func switchRequiresUnlock(multiAccount: Bool) async {
        let api = MockAPIClient()
        api.stubbedValidity = .valid
        let kc = MockKeychain()
        var entry = ServerEntry(id: "S1", name: "Maison", url: ServerURLNormalizer.normalize("https://maison.local")!,
                                accessToken: "tokA", userId: "A", username: "Alice")
        entry = ServerRegistry.remembering(userId: "B", username: "Bob", accessToken: "tokB", at: Date(), in: entry)
        kc.savedServers = [entry]
        kc.savedActiveServerId = "S1"
        let app = AppState(apiClient: api, keychain: kc)
        app.settingsDefaults = .isolatedForTesting()
        app.sessionValidator = { _, _ in .valid }
        app.accountLockProvider = { $0 == "S1|B" }
        app.multiAccountProvider = { multiAccount }
        app.loadServersFromKeychain()
        app.currentUserId = "A"
        app.isAuthenticated = true

        // Both tiers: a code already set keeps guarding (a Jellyfin account
        // may have no password); past it, free signs in, Pro switches.
        #expect(await app.switchAccount(to: "B") == .locked)
        #expect(app.currentUserId == "A")
        if multiAccount {
            #expect(await app.switchAccount(to: "B", unlocked: true) == .switched)
            #expect(app.currentUserId == "B")
        } else {
            #expect(await app.switchAccount(to: "B", unlocked: true) == .needsLogin)
            #expect(app.currentUserId == "A")
        }
    }
}

// MARK: - Parental control across accounts

@MainActor
@Suite("Contrôle parental et bascule de compte")
struct AccountSwitchParentalTests {

    private func makeApp(defaults: UserDefaults, parentalLock: Bool, bobAge: Int?, multiAccount: Bool = true) -> AppState {
        if let bobAge {
            AccountSettingsStore.save(AccountSettingsSnapshot(maxContentAge: bobAge, accentColor: "green", darkMode: true),
                                      for: "S1|B", defaults: defaults)
        }
        let api = MockAPIClient()
        api.stubbedValidity = .valid
        let kc = MockKeychain()
        var entry = ServerEntry(id: "S1", name: "Maison", url: ServerURLNormalizer.normalize("https://maison.local")!,
                                accessToken: "tokA", userId: "A", username: "Enfants")
        entry = ServerRegistry.remembering(userId: "B", username: "Bob", accessToken: "tokB", at: Date(), in: entry)
        kc.savedServers = [entry]
        kc.savedActiveServerId = "S1"
        let app = AppState(apiClient: api, keychain: kc)
        app.settingsDefaults = defaults
        app.sessionValidator = { _, _ in .valid }
        app.parentalLockProvider = { parentalLock }
        app.multiAccountProvider = { multiAccount }
        app.sessionRevoker = { _, _ in }
        app.loadServersFromKeychain()
        app.currentUserId = "A"
        app.isAuthenticated = true
        return app
    }

    @Test("Gratuit, code parental actif : le code parental d'abord, puis la connexion, sans brider la limite du compte")
    func freeParentalGateThenSignIn() async {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set(10, forKey: SettingsKey.privacyMaxContentAge)
        let app = makeApp(defaults: defaults, parentalLock: true, bobAge: 0, multiAccount: false)

        #expect(await app.switchAccount(to: "B") == .locked)
        #expect(await app.switchAccount(to: "B", unlocked: true) == .needsLogin)
        await app.addAccount(session: UserSession(userID: "B", username: "Bob", accessToken: "tokB2", serverID: "srv"))

        #expect(app.currentUserId == "B")
        #expect(app.ageCap(forAccountKey: "S1|B") == 0)
    }

    @Test("Gratuit : une connexion annulée ne laisse pas sauter la limite à un « Ajouter » ultérieur")
    func cancelledSignInStillClampsLater() async {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set(10, forKey: SettingsKey.privacyMaxContentAge)
        let app = makeApp(defaults: defaults, parentalLock: true, bobAge: 0, multiAccount: false)

        #expect(await app.switchAccount(to: "B", unlocked: true) == .needsLogin)
        app.clearPendingSignIn()
        await app.addAccount(session: UserSession(userID: "B", username: "Bob", accessToken: "tokB2", serverID: "srv"))

        #expect(app.ageCap(forAccountKey: "S1|B") == 10)
    }

    @Test("Gratuit : une déconnexion ne laisse pas de marqueur qui ferait sauter la limite d'un « Ajouter » ultérieur")
    func logoutLeavesNoPendingSignIn() async {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set(18, forKey: SettingsKey.privacyMaxContentAge)
        let app = makeApp(defaults: defaults, parentalLock: true, bobAge: 18, multiAccount: false)

        // The sign-out tries the next remembered account (free: a sign-in it
        // never completes), then lands on server setup; the server is re-added
        // and a child signs in from LoginScreen, then « Ajouter » brings Bob.
        _ = await app.logout(reason: .userInitiated)
        app.serverURL = ServerURLNormalizer.normalize("https://maison.local")
        app.hasServer = true
        app.upsertActiveEntry(session: UserSession(userID: "A", username: "Enfants", accessToken: "tokA2", serverID: "srv"))
        app.currentUserId = "A"
        app.isAuthenticated = true
        defaults.set(10, forKey: SettingsKey.privacyMaxContentAge)
        await app.addAccount(session: UserSession(userID: "B", username: "Bob", accessToken: "tokB2", serverID: "srv"))

        #expect(app.ageCap(forAccountKey: "S1|B") == 10)
    }

    @Test("« Ajouter » sans passer par une bascule : un compte moins bridé reste bridé")
    func addAccountStillClampsWithoutGate() async {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set(10, forKey: SettingsKey.privacyMaxContentAge)
        let app = makeApp(defaults: defaults, parentalLock: true, bobAge: 0, multiAccount: false)

        await app.addAccount(session: UserSession(userID: "B", username: "Bob", accessToken: "tokB2", serverID: "srv"))

        #expect(app.ageCap(forAccountKey: "S1|B") == 10)
    }

    @Test("Code parental actif : un compte moins bridé exige un code")
    func lessRestrictedNeedsUnlock() async {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set(10, forKey: SettingsKey.privacyMaxContentAge)
        let app = makeApp(defaults: defaults, parentalLock: true, bobAge: 0)
        #expect(await app.switchAccount(to: "B") == .locked)
        #expect(defaults.integer(forKey: SettingsKey.privacyMaxContentAge) == 10)
        #expect(await app.switchAccount(to: "B", unlocked: true) == .switched)
    }

    @Test("Code parental actif : un compte au moins aussi bridé s'ouvre sans code")
    func sameOrStricterOpens() async {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set(12, forKey: SettingsKey.privacyMaxContentAge)
        #expect(await makeApp(defaults: defaults, parentalLock: true, bobAge: 10).switchAccount(to: "B") == .switched)
        let inherit = UserDefaults.isolatedForTesting()
        inherit.set(12, forKey: SettingsKey.privacyMaxContentAge)
        // No snapshot: B inherits 12, nothing is lifted.
        #expect(await makeApp(defaults: inherit, parentalLock: true, bobAge: nil).switchAccount(to: "B") == .switched)
    }

    @Test("Sans code parental, la limite par compte ne bloque rien")
    func noParentalLock() async {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set(10, forKey: SettingsKey.privacyMaxContentAge)
        #expect(await makeApp(defaults: defaults, parentalLock: false, bobAge: 0).switchAccount(to: "B") == .switched)
    }

    @Test("Échelle des limites : 0 = aucune limite, la plus permissive")
    func permissiveness() {
        #expect(AccountSettingsStore.isLessRestrictive(0, than: 10))
        #expect(AccountSettingsStore.isLessRestrictive(16, than: 12))
        #expect(!AccountSettingsStore.isLessRestrictive(10, than: 12))
        #expect(!AccountSettingsStore.isLessRestrictive(0, than: 0))
        #expect(!AccountSettingsStore.isLessRestrictive(12, than: 0))
    }
}

// MARK: - Final review fixes (sign-in paths, cleanup)

@MainActor
@Suite("Multi-comptes — connexions et nettoyage")
struct MultiAccountSignInTests {

    private func makeApp(defaults: UserDefaults, parentalLock: Bool, entry: ServerEntry, currentUser: String?) -> (AppState, MockAPIClient) {
        let api = MockAPIClient()
        api.stubbedValidity = .valid
        let kc = MockKeychain()
        kc.savedServers = [entry]
        kc.savedActiveServerId = entry.id
        let app = AppState(apiClient: api, keychain: kc)
        app.settingsDefaults = defaults
        app.sessionValidator = { _, _ in .valid }
        app.sessionRevoker = { _, _ in }
        app.multiAccountProvider = { true }
        app.parentalLockProvider = { parentalLock }
        app.loadServersFromKeychain()
        app.serverURL = entry.url
        app.hasServer = true
        app.currentUserId = currentUser
        app.isAuthenticated = currentUser != nil
        return (app, api)
    }

    private var maison: ServerEntry {
        ServerEntry(id: "S1", name: "Maison", url: ServerURLNormalizer.normalize("https://maison.local")!,
                    accessToken: "tokKid", userId: "kid", username: "Enfants")
    }

    @Test("Code parental actif : ajouter un compte moins bridé ne lève pas la limite")
    func addAccountKeepsParentalCap() async {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set(10, forKey: SettingsKey.privacyMaxContentAge)
        AccountSettingsStore.save(AccountSettingsSnapshot(maxContentAge: 0, accentColor: "blue", darkMode: true),
                                  for: "S1|parent", defaults: defaults)
        let (app, api) = makeApp(defaults: defaults, parentalLock: true, entry: maison, currentUser: "kid")

        await app.addAccount(session: UserSession(userID: "parent", username: "Parent", accessToken: "tokP", serverID: "srv"))

        #expect(app.currentUserId == "parent")
        #expect(defaults.integer(forKey: SettingsKey.privacyMaxContentAge) == 10)
        #expect(api.appliedRatingLimits.last == 10)
    }

    @Test("Écran de connexion : le compte connecté ouvre avec SA limite d'âge")
    func loginAppliesAccountCap() {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set(0, forKey: SettingsKey.privacyMaxContentAge)
        AccountSettingsStore.save(AccountSettingsSnapshot(maxContentAge: 10, accentColor: "green", darkMode: true),
                                  for: "S1|kid", defaults: defaults)
        var signedOut = maison
        signedOut.accessToken = nil; signedOut.userId = nil; signedOut.username = nil
        let (app, api) = makeApp(defaults: defaults, parentalLock: false, entry: signedOut, currentUser: nil)

        app.upsertActiveEntry(session: UserSession(userID: "kid", username: "Enfants", accessToken: "tokKid2", serverID: "srv"))

        #expect(defaults.integer(forKey: SettingsKey.privacyMaxContentAge) == 10)
        #expect(api.appliedRatingLimits.last == 10)
    }

    @Test("Se déconnecter du compte actif efface ce qui le suivait (réglages, recherches, code)")
    func logoutCleansUpLeavingAccount() async {
        let defaults = UserDefaults.isolatedForTesting()
        AccountSettingsStore.save(AccountSettingsSnapshot(maxContentAge: 10, accentColor: "green", darkMode: true),
                                  for: "S1|kid", defaults: defaults)
        var entry = maison
        entry = ServerRegistry.remembering(userId: "parent", username: "Parent", accessToken: "tokP", at: Date(), in: entry)
        let (app, _) = makeApp(defaults: defaults, parentalLock: false, entry: entry, currentUser: "kid")
        var forgotten: [String] = []
        app.onAccountForgotten = { forgotten.append($0) }

        _ = await app.logout(reason: .userInitiated)

        #expect(app.currentUserId == "parent")
        #expect(forgotten == ["S1|kid"])
        #expect(AccountSettingsStore.load(for: "S1|kid", defaults: defaults) == nil)
    }
}

// MARK: - Server switch parity (security review)

@MainActor
@Suite("Changement de serveur et codes")
struct ServerSwitchLockTests {

    private func makeApp(defaults: UserDefaults, locked: Set<String>, parental: Bool, multiAccount: Bool = true) -> (AppState, ServerEntry) {
        let api = MockAPIClient()
        api.stubbedValidity = .valid
        let a = ServerEntry(id: "S1", name: "Maison", url: ServerURLNormalizer.normalize("https://maison.local")!,
                            accessToken: "tokKid", userId: "kid", username: "Enfants")
        let b = ServerEntry(id: "S2", name: "Chalet", url: ServerURLNormalizer.normalize("https://chalet.local")!,
                            accessToken: "tokP", userId: "parent", username: "Parent")
        let kc = MockKeychain()
        kc.savedServers = [a, b]
        kc.savedActiveServerId = "S1"
        let app = AppState(apiClient: api, keychain: kc)
        app.settingsDefaults = defaults
        app.sessionValidator = { _, _ in .valid }
        app.accountLockProvider = { locked.contains($0) }
        app.parentalLockProvider = { parental }
        app.multiAccountProvider = { multiAccount }
        app.loadServersFromKeychain()
        app.currentUserId = "kid"
        app.isAuthenticated = true
        return (app, b)
    }

    /// Free included: a server switch stays one-tap in free, so a code set on
    /// the other server's account (during a Pro period) must still be asked.
    @Test("Un compte protégé sur un autre serveur exige son code, Pro comme gratuit", arguments: [true, false])
    func protectedAccountOnOtherServer(multiAccount: Bool) async {
        let (app, b) = makeApp(defaults: .isolatedForTesting(), locked: ["S2|parent"], parental: false, multiAccount: multiAccount)
        #expect(await app.switchTo(b) == .locked)
        #expect(app.activeServerId == "S1")
        #expect(await app.switchTo(b, unlocked: true) == .commit)
        #expect(app.activeServerId == "S2")
    }

    @Test("Code parental actif : un compte moins bridé sur un autre serveur exige un code")
    func lessRestrictedOnOtherServer() async {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set(10, forKey: SettingsKey.privacyMaxContentAge)
        AccountSettingsStore.save(AccountSettingsSnapshot(maxContentAge: 0, accentColor: "green", darkMode: true),
                                  for: "S2|parent", defaults: defaults)
        let (app, b) = makeApp(defaults: defaults, locked: [], parental: true)
        #expect(await app.switchTo(b) == .locked)
        #expect(defaults.integer(forKey: SettingsKey.privacyMaxContentAge) == 10)
    }
}
