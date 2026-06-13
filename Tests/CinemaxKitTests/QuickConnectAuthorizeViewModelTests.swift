import Testing
import Foundation
import CinemaxKit
@testable import Cinemax

@MainActor
@Suite("QuickConnectAuthorizeViewModel")
struct QuickConnectAuthorizeViewModelTests {

    private func makeAppState(api: MockAPIClient = MockAPIClient()) -> AppState {
        AppState(apiClient: api, keychain: MockKeychain())
    }

    // MARK: - Input sanitizing

    @Test("sanitize strips non-digits and caps at the code length")
    func sanitizeStripsAndCaps() {
        let vm = QuickConnectAuthorizeViewModel()
        vm.sanitize("12ab34")
        #expect(vm.code == "1234")
        vm.sanitize("9876543210")
        #expect(vm.code == "987654")
        #expect(vm.code.count == QuickConnectAuthorizeViewModel.codeLength)
    }

    @Test("canSubmit only with a full code and not mid-submit")
    func canSubmitRules() {
        let vm = QuickConnectAuthorizeViewModel()
        vm.sanitize("123")
        #expect(!vm.canSubmit)
        vm.sanitize("123456")
        #expect(vm.canSubmit)
        vm.isSubmitting = true
        #expect(!vm.canSubmit)
    }

    // MARK: - Success path

    @Test("Approving a valid code calls the API and flips didAuthorize")
    func approveSuccess() async {
        let api = MockAPIClient()
        api.stubbedAuthorizeQuickConnectResult = true
        let vm = QuickConnectAuthorizeViewModel()
        vm.sanitize("853873")

        await vm.submit(using: makeAppState(api: api), loc: LocalizationManager())

        #expect(api.authorizeQuickConnectCalls == ["853873"])
        #expect(vm.didAuthorize)
        #expect(vm.errorMessage == nil)
        #expect(!vm.isSubmitting)
    }

    // MARK: - Failure paths

    @Test("A rejected (false) code shows an error and does not authorize")
    func rejectedCodeShowsError() async {
        let api = MockAPIClient()
        api.stubbedAuthorizeQuickConnectResult = false
        let vm = QuickConnectAuthorizeViewModel()
        vm.sanitize("000000")

        await vm.submit(using: makeAppState(api: api), loc: LocalizationManager())

        #expect(!vm.didAuthorize)
        #expect(vm.errorMessage != nil)
        #expect(!vm.isSubmitting)
    }

    @Test("A thrown error surfaces a message and does not authorize")
    func thrownErrorShowsMessage() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = QuickConnectAuthorizeViewModel()
        vm.sanitize("123456")

        await vm.submit(using: makeAppState(api: api), loc: LocalizationManager())

        #expect(!vm.didAuthorize)
        #expect(vm.errorMessage != nil)
        #expect(!vm.isSubmitting)
    }

    @Test("submit is a no-op when the code is incomplete")
    func noOpOnIncompleteCode() async {
        let api = MockAPIClient()
        let vm = QuickConnectAuthorizeViewModel()
        vm.sanitize("12")

        await vm.submit(using: makeAppState(api: api), loc: LocalizationManager())

        #expect(api.authorizeQuickConnectCalls.isEmpty)
        #expect(!vm.didAuthorize)
    }
}
