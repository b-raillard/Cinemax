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
