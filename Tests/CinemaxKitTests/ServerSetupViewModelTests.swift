import Testing
import Foundation
import CinemaxKit
@testable import Cinemax

@MainActor
@Suite("ServerSetupViewModel")
struct ServerSetupViewModelTests {

    private func makeAppState(api: MockAPIClient = MockAPIClient(), keychain: MockKeychain = MockKeychain()) -> AppState {
        AppState(apiClient: api, keychain: keychain)
    }

    // MARK: - Input validation

    @Test("Empty URL shows error without connecting")
    func emptyURLShowsError() async {
        let api = MockAPIClient()
        let vm = ServerSetupViewModel()
        vm.serverURL = "   "

        await vm.connect(using: makeAppState(api: api), loc: LocalizationManager())

        #expect(vm.errorMessage != nil)
        #expect(!api.connectCalled)
    }

    @Test("URL without scheme is automatically prefixed with https")
    func urlWithoutSchemePrefixedWithHttps() async {
        let api = MockAPIClient()
        api.stubbedServerInfo = ServerInfo(name: "Home Server", serverID: "s1", version: "10.9.0", url: URL(string: "https://jellyfin.local")!)
        let vm = ServerSetupViewModel()
        vm.serverURL = "jellyfin.local"

        await vm.connect(using: makeAppState(api: api), loc: LocalizationManager())

        #expect(api.connectCalled)
        #expect(vm.errorMessage == nil)
    }

    @Test("Invalid URL format shows error")
    func invalidURLShowsError() async {
        let api = MockAPIClient()
        let vm = ServerSetupViewModel()
        vm.serverURL = "not a url at all !!!"

        await vm.connect(using: makeAppState(api: api), loc: LocalizationManager())

        #expect(vm.errorMessage != nil)
        #expect(!api.connectCalled)
    }

    // MARK: - Success path

    @Test("Successful connection sets appState.hasServer and saves URL to keychain")
    func successfulConnectionSetsHasServer() async {
        let api = MockAPIClient()
        let keychain = MockKeychain()
        let appState = makeAppState(api: api, keychain: keychain)
        let vm = ServerSetupViewModel()
        vm.serverURL = "http://localhost:8096"

        await vm.connect(using: appState, loc: LocalizationManager())

        #expect(appState.hasServer)
        #expect(keychain.savedServerURL?.host == "localhost")
        #expect(vm.serverInfo?.name == api.stubbedServerInfo.name)
        #expect(vm.errorMessage == nil)
        #expect(!vm.isConnecting)
    }

    // MARK: - Multi-server dedup

    @Test("An already-registered URL is refused without a network call")
    func alreadyRegisteredURLRefused() async {
        let api = MockAPIClient()
        let keychain = MockKeychain()
        // Seeded WITH a usable session (token AND user id): that is what the
        // gate keys on, so a credential-less seed would pass vacuously.
        keychain.savedServers = [
            ServerEntry(
                name: "Home",
                url: ServerURLNormalizer.normalize("https://host/jellyfin")!,
                accessToken: "tok",
                userId: "user1",
                username: "U"
            )
        ]
        let appState = makeAppState(api: api, keychain: keychain)
        appState.loadServersFromKeychain()

        let vm = ServerSetupViewModel()
        // A different spelling of the same server — dedup runs on the
        // normalized URL, so this must be refused too.
        vm.serverURL = "HTTPS://Host:443/jellyfin/"

        await vm.connect(using: appState, loc: LocalizationManager())

        #expect(vm.errorMessage != nil)
        #expect(!api.connectCalled)
        #expect(appState.servers.count == 1)
    }

    @Test("A registered but SIGNED-OUT server is let through (re-login path)")
    func signedOutServerNotRefused() async {
        let api = MockAPIClient()
        let keychain = MockKeychain()
        // Logging out of your only server leaves exactly this shape behind.
        // Refusing it here would lock the user out of the app.
        keychain.savedServers = [
            ServerEntry(name: "Home", url: ServerURLNormalizer.normalize("https://host/jellyfin")!)
        ]
        let appState = makeAppState(api: api, keychain: keychain)
        appState.loadServersFromKeychain()

        let vm = ServerSetupViewModel()
        vm.serverURL = "https://host/jellyfin"

        await vm.connect(using: appState, loc: LocalizationManager())

        #expect(vm.errorMessage == nil)
        #expect(api.connectCalled)
        #expect(appState.hasServer)
    }

    @Test("While ADDING a server, connect does not touch the legacy mirror")
    func addModeLeavesMirrorAlone() async {
        let api = MockAPIClient()
        let keychain = MockKeychain()
        keychain.savedServerURL = URL(string: "https://current.local")!
        let appState = makeAppState(api: api, keychain: keychain)
        appState.isAddingServer = true

        let vm = ServerSetupViewModel()
        vm.serverURL = "https://new.local"
        await vm.connect(using: appState, loc: LocalizationManager())

        #expect(api.connectCalled)
        #expect(appState.serverURL?.host == "new.local")          // in-memory, drives LoginScreen
        // The mirror still describes the server we're signed in to: killing the
        // app here must not pair the NEW url with the OLD token.
        #expect(keychain.savedServerURL?.host == "current.local")
    }

    // MARK: - Failure path

    @Test("Connection failure sets errorMessage")
    func connectionFailureSetsErrorMessage() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = ServerSetupViewModel()
        vm.serverURL = "http://unreachable.local"

        await vm.connect(using: makeAppState(api: api), loc: LocalizationManager())

        #expect(vm.errorMessage != nil)
        #expect(!vm.isConnecting)
    }
}
