#if os(iOS)
import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// Locks the API-key list against the shape Jellyfin actually sends: every key
/// carries `Id = 0` and `IsActive = false` (`AuthenticationManager.GetApiKeys`
/// fills in only AppName / AccessToken / DateCreated). The screen used to
/// filter on `isActive` and key its rows on `id`, so it always read « Aucune
/// clé API ».
@Suite("Admin API keys")
@MainActor
struct AdminApiKeysTests {

    private func serverKey(_ app: String, token: String, created: TimeInterval) -> AuthenticationInfo {
        AuthenticationInfo(
            accessToken: token,
            appName: app,
            dateCreated: Date(timeIntervalSince1970: created),
            id: 0,
            isActive: false
        )
    }

    @Test("keys sent with IsActive = false and Id = 0 are all listed, newest first, each with its own id")
    func listsServerShapedKeys() {
        let listed = AdminApiKeysViewModel.listable([
            serverKey("Seerr", token: "aaaa1111bbbb2222cccc", created: 100),
            serverKey("Home Assistant", token: "dddd3333eeee4444ffff", created: 300),
            serverKey("Script", token: "gggg5555hhhh6666iiii", created: 200),
        ])

        #expect(listed.map(\.appName) == ["Home Assistant", "Script", "Seerr"])
        #expect(Set(listed.compactMap(\.id)).count == 3)
    }

    @Test("a revoked or tokenless entry is still dropped")
    func dropsRevokedAndTokenless() {
        var revoked = serverKey("Old", token: "jjjj7777kkkk8888llll", created: 50)
        revoked.dateRevoked = Date(timeIntervalSince1970: 60)
        let listed = AdminApiKeysViewModel.listable([
            revoked,
            serverKey("Empty", token: "", created: 70),
            serverKey("Kept", token: "mmmm9999nnnn0000oooo", created: 80),
        ])

        #expect(listed.map(\.appName) == ["Kept"])
    }

    @Test("revealing one key reveals that key only")
    func revealIsPerKey() async {
        let api = MockAPIClient()
        api.stubbedApiKeys = [
            serverKey("A", token: "aaaa1111bbbb2222cccc", created: 100),
            serverKey("B", token: "dddd3333eeee4444ffff", created: 200),
        ]
        let vm = AdminApiKeysViewModel()
        await vm.load(using: api, loc: LocalizationManager())

        vm.toggleReveal(vm.keys[0])

        #expect(vm.isRevealed(vm.keys[0]))
        #expect(!vm.isRevealed(vm.keys[1]))
    }

    @Test("a created key is found and surfaced although the server gives it Id = 0")
    func createdKeyIsSurfaced() async {
        let api = MockAPIClient()
        api.stubbedApiKeys = [serverKey("A", token: "aaaa1111bbbb2222cccc", created: 100)]
        let vm = AdminApiKeysViewModel()
        await vm.load(using: api, loc: LocalizationManager())

        vm.newAppName = "Nouvelle"
        let ok = await vm.createKey(using: api, loc: LocalizationManager())

        #expect(ok)
        #expect(vm.keys.count == 2)
        #expect(vm.freshlyCreatedKey?.appName == "Nouvelle")
    }

    @Test("revoking removes that key and leaves the other one")
    func revokeRemovesOnlyThatKey() async {
        let api = MockAPIClient()
        api.stubbedApiKeys = [
            serverKey("A", token: "aaaa1111bbbb2222cccc", created: 100),
            serverKey("B", token: "dddd3333eeee4444ffff", created: 200),
        ]
        let vm = AdminApiKeysViewModel()
        await vm.load(using: api, loc: LocalizationManager())

        let ok = await vm.revoke(vm.keys[0], using: api, loc: LocalizationManager())

        #expect(ok)
        #expect(vm.keys.map(\.appName) == ["A"])
    }
}

@Suite("Admin activity row")
@MainActor
struct AdminActivityRowTests {
    @Test("a summary whose value is missing is not shown; a real one is")
    func dropsDanglingLabel() {
        #expect(AdminActivityScreen.displayedShortOverview("Adresse IP : ") == nil)
        #expect(AdminActivityScreen.displayedShortOverview("IP address:") == nil)
        #expect(AdminActivityScreen.displayedShortOverview("   ") == nil)
        #expect(AdminActivityScreen.displayedShortOverview(nil) == nil)
        #expect(AdminActivityScreen.displayedShortOverview("Adresse IP : 172.17.0.1") == "Adresse IP : 172.17.0.1")
    }
}

/// Audit 2026-09-22 (S11) : le journal serveur reste sélectionnable (copier
/// une ligne d'erreur est l'usage de l'écran), mais sans les jetons qu'il porte.
@MainActor
@Suite("Journal serveur — jetons masqués")
struct AdminLogViewerScrubTests {
    @Test("Les jetons d'un journal sont masqués avant affichage, ligne par ligne")
    func logContentsAreScrubbed() async {
        let api = MockAPIClient()
        api.stubbedLogFileContents = "GET /Items?api_key=abc123&x=1 200\nAuthorization: MediaBrowser Token=\"tok456\"\n\nfin"
        let vm = AdminLogViewerViewModel(fileName: "log_1.log")
        await vm.load(using: api, loc: LocalizationManager())
        #expect(!vm.contents.contains("abc123"))
        #expect(!vm.contents.contains("tok456"))
        #expect(vm.contents.hasSuffix("\n\nfin"), "les lignes (vides comprises) sont conservées")
    }
}
#endif
