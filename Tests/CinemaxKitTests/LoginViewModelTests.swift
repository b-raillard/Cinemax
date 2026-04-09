import Testing
import Foundation
import CinemaxKit
@testable import Cinemax

@MainActor
@Suite("LoginViewModel")
struct LoginViewModelTests {

    private func makeAppState(api: MockAPIClient = MockAPIClient(), keychain: MockKeychain = MockKeychain()) -> AppState {
        AppState(apiClient: api, keychain: keychain)
    }

    // MARK: - Input validation

    @Test("Empty username shows error and skips network call")
    func emptyUsernameShowsError() async {
        let api = MockAPIClient()
        let vm = LoginViewModel()
        vm.username = "   "
        vm.password = "secret"

        await vm.authenticate(using: makeAppState(api: api))

        #expect(vm.errorMessage != nil)
        #expect(!api.authenticateCalled)
        #expect(!vm.isAuthenticating)
    }

    // MARK: - Success path

    @Test("Successful auth saves token to keychain and triggers showSuccess")
    func successfulAuthSavesToken() async {
        let api = MockAPIClient()
        api.stubbedSession = UserSession(userID: "u1", username: "Alice", accessToken: "tok42", serverID: "s1")
        let keychain = MockKeychain()
        let appState = makeAppState(api: api, keychain: keychain)
        let vm = LoginViewModel()
        vm.username = "Alice"
        vm.password = "password"

        // Run without awaiting the 1s sleep to keep tests fast
        let task = Task { await vm.authenticate(using: appState) }
        // Poll until showSuccess is set (before the sleep finishes)
        for _ in 0..<50 {
            if vm.showSuccess { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()

        #expect(api.authenticateCalled)
        #expect(vm.showSuccess)
        #expect(keychain.savedAccessToken == "tok42")
        #expect(appState.currentUserId == "u1")
        #expect(vm.errorMessage == nil)
    }

    // MARK: - Failure path

    @Test("Network error sets errorMessage and clears isAuthenticating")
    func networkErrorSetsMessage() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = LoginViewModel()
        vm.username = "Alice"
        vm.password = "wrong"

        await vm.authenticate(using: makeAppState(api: api))

        #expect(vm.errorMessage != nil)
        #expect(!vm.isAuthenticating)
        #expect(!vm.showSuccess)
    }

    @Test("isAuthenticating is false after completion")
    func isAuthenticatingResetAfterCompletion() async {
        let vm = LoginViewModel()
        vm.username = "Alice"
        vm.password = "secret"

        await vm.authenticate(using: makeAppState())

        #expect(!vm.isAuthenticating)
    }
}
