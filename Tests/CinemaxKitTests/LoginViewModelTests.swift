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

        await vm.authenticate(using: makeAppState(api: api), loc: LocalizationManager())

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
        let task = Task { await vm.authenticate(using: appState, loc: LocalizationManager()) }
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

        await vm.authenticate(using: makeAppState(api: api), loc: LocalizationManager())

        #expect(vm.errorMessage != nil)
        #expect(!vm.isAuthenticating)
        #expect(!vm.showSuccess)
    }

    @Test("isAuthenticating is false after completion")
    func isAuthenticatingResetAfterCompletion() async {
        let vm = LoginViewModel()
        vm.username = "Alice"
        vm.password = "secret"

        await vm.authenticate(using: makeAppState(), loc: LocalizationManager())

        #expect(!vm.isAuthenticating)
    }

    // MARK: - Quick Connect poll resilience

    /// Polls the VM until `condition` holds or the budget elapses. Keeps the
    /// Quick Connect tests off wall-clock sleeps.
    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Transient poll failures keep polling and approval still completes")
    func quickConnectSurvivesTransientPollFailures() async {
        let api = MockAPIClient()
        api.stubbedSession = UserSession(userID: "u1", username: "Alice", accessToken: "tok", serverID: "s1")
        // One under the budget, then approval — the flow must not have exited.
        api.quickConnectAuthorizedHandler = { index in
            if index < LoginViewModel.quickConnectFailureBudget { throw MockError.genericFailure }
            return true
        }
        let vm = LoginViewModel()
        vm.quickConnectPollInterval = .milliseconds(1)

        vm.startQuickConnect(using: makeAppState(api: api), loc: LocalizationManager())
        await waitFor { vm.showSuccess }
        vm.cancelQuickConnect()

        #expect(vm.showSuccess)
        #expect(vm.quickConnectError == nil)
        #expect(api.quickConnectPollCount == LoginViewModel.quickConnectFailureBudget)
    }

    @Test("A successful poll resets the consecutive-failure budget")
    func quickConnectResetsBudgetOnSuccessfulPoll() async {
        let api = MockAPIClient()
        api.stubbedSession = UserSession(userID: "u1", username: "Alice", accessToken: "tok", serverID: "s1")
        // 4 failures, one successful (not-yet-approved) poll, then 4 more
        // failures: 8 total failures but never 5 in a row, so the flow survives
        // and completes on the 10th poll.
        api.quickConnectAuthorizedHandler = { index in
            if index == 5 { return false }
            if index < 10 { throw MockError.genericFailure }
            return true
        }
        let vm = LoginViewModel()
        vm.quickConnectPollInterval = .milliseconds(1)

        vm.startQuickConnect(using: makeAppState(api: api), loc: LocalizationManager())
        await waitFor { vm.showSuccess }
        vm.cancelQuickConnect()

        #expect(vm.showSuccess)
        #expect(vm.quickConnectError == nil)
    }

    @Test("Poll gives up after the consecutive-failure budget")
    func quickConnectGivesUpAfterBudget() async {
        let api = MockAPIClient()
        api.quickConnectAuthorizedHandler = { _ in throw MockError.genericFailure }
        let vm = LoginViewModel()
        vm.quickConnectPollInterval = .milliseconds(1)

        vm.startQuickConnect(using: makeAppState(api: api), loc: LocalizationManager())
        await waitFor { vm.quickConnectError != nil }

        #expect(vm.quickConnectError != nil)
        #expect(!vm.showSuccess)
        #expect(api.quickConnectPollCount == LoginViewModel.quickConnectFailureBudget)
    }

    @Test("Cancelling the sheet exits the poll loop without surfacing an error")
    func quickConnectCancelExitsSilently() async {
        let api = MockAPIClient()
        api.quickConnectAuthorizedHandler = { _ in false }   // never approved
        let vm = LoginViewModel()
        vm.quickConnectPollInterval = .milliseconds(1)

        vm.startQuickConnect(using: makeAppState(api: api), loc: LocalizationManager())
        await waitFor { api.quickConnectPollCount > 2 }
        vm.cancelQuickConnect()
        let pollsAtCancel = api.quickConnectPollCount
        try? await Task.sleep(for: .milliseconds(60))

        #expect(vm.quickConnectError == nil)
        #expect(vm.quickConnectCode == nil)
        // Loop actually stopped — not just "no error surfaced".
        #expect(api.quickConnectPollCount <= pollsAtCancel + 1)
    }
}
