import Testing
import Foundation
@testable import CinemaxKit
@testable import Cinemax

/// Confirm-before-logout: a single ambiguous 401 must NOT disconnect a user
/// whose token is still valid. Only a server-CONFIRMED `.invalid` logs out.
@MainActor
@Suite("Session resilience")
struct SessionResilienceTests {

    private func makeAuthedState(_ api: MockAPIClient, _ kc: MockKeychain) -> AppState {
        kc.savedSession = UserSession(userID: "user1", username: "U", accessToken: "tok", serverID: "s")
        kc.savedAccessToken = "tok"
        let app = AppState(apiClient: api, keychain: kc)
        app.isAuthenticated = true
        app.currentUserId = "user1"
        return app
    }

    @Test("Confirmed-invalid token logs the user out")
    func invalidLogsOut() async {
        let api = MockAPIClient(); api.stubbedValidity = .invalid
        let kc = MockKeychain()
        let app = makeAuthedState(api, kc)

        await app.handlePossibleSessionExpiry()

        #expect(app.isAuthenticated == false)
        #expect(kc.savedSession == nil)        // logout() → keychain.clearAll()
    }

    /// Multi-server semantics, locked deliberately: an expired session lands the
    /// user on THIS server's `LoginScreen`, never back on `ServerSetupScreen`,
    /// and it must not touch any other registered server's credentials.
    @Test("Session expiry keeps hasServer and spares the other servers")
    func sessionExpiryKeepsServerAndOthers() async {
        let api = MockAPIClient(); api.stubbedValidity = .invalid
        let kc = MockKeychain()
        let active = ServerEntry(
            name: "A", url: URL(string: "https://a.local")!,
            accessToken: "tok", userId: "user1", username: "U"
        )
        let other = ServerEntry(
            name: "B", url: URL(string: "https://b.local")!,
            accessToken: "other-tok", userId: "user2", username: "V"
        )
        kc.savedServers = [active, other]
        kc.savedActiveServerId = active.id

        let app = makeAuthedState(api, kc)
        app.loadServersFromKeychain()
        app.hasServer = true
        app.serverURL = active.url

        await app.handlePossibleSessionExpiry()

        #expect(app.isAuthenticated == false)
        #expect(app.hasServer)                                     // LoginScreen, not server setup
        #expect(app.serverURL == active.url)
        #expect(app.servers.first { $0.id == active.id }?.accessToken == nil)
        #expect(app.servers.first { $0.id == other.id }?.accessToken == "other-tok")
    }

    @Test("Valid token keeps the session (spurious 401 ignored)")
    func validKeepsSession() async {
        let api = MockAPIClient(); api.stubbedValidity = .valid
        let app = makeAuthedState(api, MockKeychain())

        await app.handlePossibleSessionExpiry()

        #expect(app.isAuthenticated == true)
    }

    @Test("Indeterminate (network) keeps the session")
    func indeterminateKeepsSession() async {
        let api = MockAPIClient(); api.stubbedValidity = .indeterminate
        let app = makeAuthedState(api, MockKeychain())

        await app.handlePossibleSessionExpiry()

        #expect(app.isAuthenticated == true)
    }

    @Test("Offline → never log out, never even probe")
    func offlineGate() async {
        let api = MockAPIClient(); api.stubbedValidity = .invalid
        let app = makeAuthedState(api, MockKeychain())
        app.isOnlineProvider = { false }

        await app.handlePossibleSessionExpiry()

        #expect(app.isAuthenticated == true)
        #expect(api.validateSessionCallCount == 0)
    }

    @Test("Concurrent triggers collapse into one probe (debounce)")
    func debounce() async {
        let api = MockAPIClient()
        api.stubbedValidity = .valid
        api.validateSessionDelayMs = 200      // keep the first cycle in-flight
        let app = makeAuthedState(api, MockKeychain())

        async let a: Void = app.handlePossibleSessionExpiry()
        async let b: Void = app.handlePossibleSessionExpiry()
        _ = await (a, b)

        #expect(api.validateSessionCallCount == 1)
    }
}

/// The precise 401 classifier — the regression this fixes is that a benign
/// error whose text merely contains "(401)" used to log the user out.
@Suite("401 classifier")
struct UnauthorizedClassifierTests {

    @Test("Structured + URL auth errors are 401")
    func positives() {
        #expect(JellyfinAPIClient.isUnauthorized(JellyfinError.unauthorized))
        #expect(JellyfinAPIClient.isUnauthorized(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired)))
    }

    @Test("Non-auth errors are NOT 401 (incl. benign text containing 401)")
    func negatives() {
        #expect(!JellyfinAPIClient.isUnauthorized(JellyfinError.notConnected))
        #expect(!JellyfinAPIClient.isUnauthorized(JellyfinError.playbackFailed("PlaybackInfo returned 403")))
        // The old substring heuristic flagged this as a 401 → spurious logout.
        #expect(!JellyfinAPIClient.isUnauthorized(
            NSError(domain: "x", code: 500, userInfo: [NSLocalizedDescriptionKey: "weird (401) in text"])))
        #expect(!JellyfinAPIClient.isUnauthorized(URLError(.notConnectedToInternet)))
    }
}
