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

        await vm.connect(using: makeAppState(api: api))

        #expect(vm.errorMessage != nil)
        #expect(!api.connectCalled)
    }

    @Test("URL without scheme is automatically prefixed with https")
    func urlWithoutSchemePrefixedWithHttps() async {
        let api = MockAPIClient()
        api.stubbedServerInfo = ServerInfo(name: "Home Server", serverID: "s1", version: "10.9.0", url: URL(string: "https://jellyfin.local")!)
        let vm = ServerSetupViewModel()
        vm.serverURL = "jellyfin.local"

        await vm.connect(using: makeAppState(api: api))

        #expect(api.connectCalled)
        #expect(vm.errorMessage == nil)
    }

    @Test("Invalid URL format shows error")
    func invalidURLShowsError() async {
        let api = MockAPIClient()
        let vm = ServerSetupViewModel()
        vm.serverURL = "not a url at all !!!"

        await vm.connect(using: makeAppState(api: api))

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

        await vm.connect(using: appState)

        #expect(appState.hasServer)
        #expect(keychain.savedServerURL?.host == "localhost")
        #expect(vm.serverInfo?.name == api.stubbedServerInfo.name)
        #expect(vm.errorMessage == nil)
        #expect(!vm.isConnecting)
    }

    // MARK: - Failure path

    @Test("Connection failure sets errorMessage")
    func connectionFailureSetsErrorMessage() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = ServerSetupViewModel()
        vm.serverURL = "http://unreachable.local"

        await vm.connect(using: makeAppState(api: api))

        #expect(vm.errorMessage != nil)
        #expect(!vm.isConnecting)
    }
}
