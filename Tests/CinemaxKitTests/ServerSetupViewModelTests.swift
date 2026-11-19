import Testing
import Foundation
@testable import CinemaxKit
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

    // MARK: - Scheme-less https → http retry (recette 2026-11-17)

    @Test("A scheme-less address whose https fails is retried once over http")
    func schemeLessRetriesOverHTTP() async {
        let api = MockAPIClient()
        api.connectHandler = { url in
            guard url.scheme == "http" else { throw URLError(.secureConnectionFailed) }
            return ServerInfo(name: "Bench", serverID: "b1", version: "10.11.0", url: url)
        }
        let keychain = MockKeychain()
        let appState = makeAppState(api: api, keychain: keychain)
        let vm = ServerSetupViewModel()
        vm.serverURL = "localhost:8096"

        await vm.connect(using: appState, loc: LocalizationManager())

        #expect(api.connectedURLs.map(\.absoluteString) == ["https://localhost:8096", "http://localhost:8096"])
        #expect(vm.errorMessage == nil)
        #expect(appState.serverURL?.scheme == "http")
        #expect(keychain.savedServerURL?.scheme == "http")
    }

    @Test("An address typed WITH a scheme is never retried on another one")
    func explicitSchemeNotRetried() async {
        let api = MockAPIClient()
        api.connectHandler = { _ in throw URLError(.cannotConnectToHost) }
        let vm = ServerSetupViewModel()
        vm.serverURL = "https://localhost:8096"

        await vm.connect(using: makeAppState(api: api), loc: LocalizationManager())

        #expect(api.connectedURLs.count == 1)
        #expect(vm.errorMessage != nil)
    }

    @Test("When both fail, the generic error stays and the server is not set")
    func bothSchemesFail() async {
        let api = MockAPIClient()
        api.connectHandler = { _ in throw URLError(.cannotConnectToHost) }
        let appState = makeAppState(api: api)
        let vm = ServerSetupViewModel()
        vm.serverURL = "nas.local:8096"

        await vm.connect(using: appState, loc: LocalizationManager())

        #expect(api.connectedURLs.count == 2)
        #expect(vm.errorMessage == LocalizationManager().localized("server.connectFailed"))
        #expect(!appState.hasServer)
    }

    @Test("A scheme-less address whose http spelling is already signed in is refused offline")
    func schemeLessMatchesRegisteredHTTP() async {
        let api = MockAPIClient()
        let keychain = MockKeychain()
        keychain.savedServers = [
            ServerEntry(
                name: "Bench",
                url: ServerURLNormalizer.normalize("http://localhost:8096")!,
                accessToken: "tok",
                userId: "user1",
                username: "U"
            )
        ]
        let appState = makeAppState(api: api, keychain: keychain)
        appState.loadServersFromKeychain()
        let vm = ServerSetupViewModel()
        vm.serverURL = "localhost:8096"

        await vm.connect(using: appState, loc: LocalizationManager())

        #expect(vm.errorMessage == LocalizationManager().localized("server.alreadyAdded"))
        #expect(!api.connectCalled)
    }

    @Test("A scheme-less host that PRESENTED a certificate is never retried in cleartext")
    func presentedCertificateNotDowngraded() async {
        let key = "192.168.1.50:443"
        ServerTrustDelegate.shared.recordPending(ServerCertificateSummary(
            trustKey: key, host: "192.168.1.50", subject: "test", serialNumber: nil, fingerprint: "ab"
        ))
        defer { ServerTrustDelegate.shared.clearPending(forTrustKey: key) }
        let api = MockAPIClient()
        api.connectHandler = { _ in throw URLError(.serverCertificateUntrusted) }
        let vm = ServerSetupViewModel()
        vm.serverURL = "192.168.1.50"

        await vm.connect(using: makeAppState(api: api), loc: LocalizationManager())

        #expect(api.connectedURLs.count == 1)
        #expect(vm.pendingCertificate?.fingerprint == "ab")
    }

    @Test("The http fallback keeps host, port and sub-path")
    func plainHTTPFallbackSpelling() {
        let https = ServerURLNormalizer.normalize("nas.local:8096/jellyfin")!
        #expect(ServerSetupViewModel.plainHTTPFallback(for: https)?.absoluteString == "http://nas.local:8096/jellyfin")
        #expect(ServerSetupViewModel.plainHTTPFallback(for: URL(string: "http://nas.local")!) == nil)
    }

    @Test("An address already known over https never falls back to cleartext")
    func knownHTTPSAddressKeepsTLS() {
        let typed = ServerURLNormalizer.normalize("192.168.1.10:8920")!
        let unpinned: (String) -> Bool = { _ in false }
        let https = ServerEntry(url: URL(string: "https://192.168.1.10:8920")!)
        let lan = ServerEntry(url: URL(string: "https://tv.example.net")!, localURL: URL(string: "https://192.168.1.10:8920")!)
        let http = ServerEntry(url: URL(string: "http://192.168.1.10:8920")!)
        let otherPort = ServerEntry(url: URL(string: "https://192.168.1.10:8921")!)

        #expect(!ServerSetupViewModel.isKnownOverHTTPS(typed, servers: [], isPinned: unpinned))
        #expect(!ServerSetupViewModel.isKnownOverHTTPS(typed, servers: [http, otherPort], isPinned: unpinned))
        #expect(ServerSetupViewModel.isKnownOverHTTPS(typed, servers: [https], isPinned: unpinned))
        #expect(ServerSetupViewModel.isKnownOverHTTPS(typed, servers: [lan], isPinned: unpinned))
        #expect(ServerSetupViewModel.isKnownOverHTTPS(typed, servers: [], isPinned: { $0 == "192.168.1.10:8920" }))
    }

    @Test("Only a home-network host may fall back to cleartext")
    func cleartextFallbackIsHomeNetworkOnly() {
        let allowed = ["localhost:8096", "127.0.0.1:8096", "[::1]:8096", "192.168.1.10:8096",
                       "10.0.0.5", "172.20.1.2", "169.254.3.4", "[fd00::1]:8096", "nas.local:8096"]
        let refused = ["movies.example.net", "jellyfin.example.com:8096", "8.8.8.8:8096",
                       "100.64.1.1", "local", "example.local.net"]
        for raw in allowed {
            #expect(ServerSetupViewModel.allowsPlainHTTPFallback(for: ServerURLNormalizer.normalize(raw)!), "\(raw)")
        }
        for raw in refused {
            #expect(!ServerSetupViewModel.allowsPlainHTTPFallback(for: ServerURLNormalizer.normalize(raw)!), "\(raw)")
        }
    }

    @Test("The login screen warns for the server in use, whatever was typed")
    func cleartextBannerKeysOnTheServerInUse() {
        // What the scheme-less retry leaves in `appState.serverURL`.
        #expect(PreAuthCleartextBanner.applies(to: URL(string: "http://192.168.1.10:8096")))
        #expect(PreAuthCleartextBanner.applies(to: URL(string: "HTTP://nas.local:8096/jellyfin")))
        #expect(!PreAuthCleartextBanner.applies(to: URL(string: "https://movies.example.net")))
        #expect(!PreAuthCleartextBanner.applies(to: nil))
    }

    @Test("A scheme-less PUBLIC host whose https fails is never retried in cleartext")
    func publicHostNotDowngraded() async {
        let api = MockAPIClient()
        api.connectHandler = { _ in throw URLError(.cannotConnectToHost) }
        let appState = makeAppState(api: api)
        let vm = ServerSetupViewModel()
        vm.serverURL = "movies.example.net"

        await vm.connect(using: appState, loc: LocalizationManager())

        #expect(api.connectedURLs.map(\.absoluteString) == ["https://movies.example.net"])
        #expect(vm.errorMessage == LocalizationManager().localized("server.connectFailed"))
        #expect(!appState.hasServer)
    }
}
