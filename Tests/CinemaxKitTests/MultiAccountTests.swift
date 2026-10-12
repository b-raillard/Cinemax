import Testing
import Foundation
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

    @Test("Ajout en gratuit : l'ancien compte est oublié et son jeton révoqué")
    func addFree() async {
        let api = MockAPIClient()
        let revoked = RevokedTokens()
        let app = makeState(api: api, servers: [household(rememberBob: false)], multiAccount: false, revoked: revoked)

        await app.addAccount(session: UserSession(userID: "C", username: "Carl", accessToken: "tokC", serverID: "srv"))

        #expect(app.currentUserId == "C")
        #expect(app.activeAccounts.map(\.userId) == ["C"])
        #expect(await eventually { await revoked.tokens == ["tokA"] })
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
