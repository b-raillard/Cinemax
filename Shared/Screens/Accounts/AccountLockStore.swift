import Foundation
import Observation
import CinemaxKit
#if os(iOS)
import LocalAuthentication
#endif

/// The optional 4-digit code of each remembered account (multi-account).
///
/// Built on the parental lock's policy — salt, iterated hash, back-off on the
/// monotonic clock, biometrics armed on the enrolled SET and never on the
/// device passcode (`ParentalLockPolicy`, see `Settings/CLAUDE.md`) — with one
/// credential per account key (`<serverId>|<userId>`) in the app-private
/// Keychain. What differs from the parental lock: 4 digits
/// (`ParentalLockPolicy.accountPINLength`), and nothing stays « unlocked »: a
/// code opens ONE switch, then the account is locked again.
///
/// A process singleton (`AppNavigation.sharedAccountLocks`): it reads the
/// Keychain lazily per key and caches the answer.
@MainActor @Observable
final class AccountLockStore {
    /// Bumped by every mutator; the readers (`hasLock`, `biometricsEnabled`)
    /// read it so a view redraws when a code is added or removed. The lazy
    /// Keychain read itself only touches ignored state — mutating an observed
    /// property from inside a view's body read is what SwiftUI warns about.
    private(set) var revision = 0
    private(set) var isVerifying = false

    @ObservationIgnored private let storage: any AccountLockStorage
    @ObservationIgnored private let iterations: Int
    @ObservationIgnored private var credentials: [String: ParentalLockCredential] = [:]
    @ObservationIgnored private var loaded: Set<String> = []

    /// `iterations` is a test seam (150 000 rounds per test would be slow).
    init(storage: any AccountLockStorage = KeychainService(), iterations: Int = ParentalLockPolicy.iterations) {
        self.storage = storage
        self.iterations = iterations
    }

    func hasLock(_ key: String) -> Bool {
        _ = revision
        return credential(for: key) != nil
    }

    /// Whether Face ID can open `key` (enrolled, armed, iOS).
    func biometricsEnabled(_ key: String) -> Bool {
        _ = revision
        return credential(for: key)?.biometricsEnabled == true
    }

    /// Enrols (or replaces) `key`'s code.
    func enroll(key: String, pin: String, useBiometrics: Bool) async -> Bool {
        let effective = useBiometrics && Self.biometricsAvailable
        let rounds = iterations
        let made = await Task.detached(priority: .userInitiated) {
            ParentalLockPolicy.makeCredential(
                pin: pin, minimumLength: ParentalLockPolicy.accountPINLength,
                biometricsEnabled: effective, iterations: rounds
            )
        }.value
        guard var fresh = made else { return false }
        if fresh.biometricsEnabled { fresh.biometricDomainState = Self.currentBiometricDomainState() }
        return persist(fresh, key: key)
    }

    /// Verifies a code and persists the counters the policy returns.
    func verify(key: String, pin: String) async -> ParentalLockVerdict {
        guard let credential = credential(for: key) else {
            return .unlocked(ParentalLockCredential(salt: Data(), hash: Data(), iterations: 1))
        }
        isVerifying = true
        defer { isVerifying = false }
        let verdict = await Task.detached(priority: .userInitiated) {
            ParentalLockPolicy.verify(pin: pin, against: credential)
        }.value
        switch verdict {
        case .unlocked(let updated), .wrong(let updated, _):
            persist(updated, key: key)
        case .throttled(_, let reanchored):
            if let reanchored { persist(reanchored, key: key) }
        }
        return verdict
    }

    /// Seconds left in `key`'s back-off window, `0` when it may be tried.
    func throttleRemaining(_ key: String) -> TimeInterval {
        guard let credential = credential(for: key) else { return 0 }
        return ParentalLockPolicy.backoffRemaining(credential, at: .now()).remaining
    }

    func setBiometricsEnabled(_ enabled: Bool, key: String) {
        guard var credential = credential(for: key) else { return }
        let effective = enabled && Self.biometricsAvailable
        guard credential.biometricsEnabled != effective else { return }
        credential.biometricsEnabled = effective
        credential.biometricDomainState = effective ? Self.currentBiometricDomainState() : nil
        persist(credential, key: key)
    }

    /// Removes `key`'s code (account settings, or the account leaving).
    func remove(key: String) {
        storage.deleteAccountLock(key: key)
        credentials[key] = nil
        loaded.insert(key)
        revision &+= 1
    }

    #if os(iOS)
    /// Face ID as a shortcut past the code — same discipline as the parental
    /// lock: biometrics only, never the device passcode, refused when the
    /// enrolled set changed since the code was armed.
    func unlockWithBiometrics(key: String, reason: String) async -> Bool {
        guard let credential = credential(for: key), credential.biometricsEnabled else { return false }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        guard ParentalLockPolicy.biometricsAllowed(
            armedState: credential.biometricDomainState,
            currentState: context.domainState.biometry.stateHash
        ) else { return false }
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { @Sendable ok, _ in
                continuation.resume(returning: ok)
            }
        }
        guard success else { return false }
        var cleared = credential
        cleared.failedAttempts = 0
        cleared.lockedUntil = nil
        cleared.backoffAnchor = nil
        persist(cleared, key: key)
        return true
    }
    #endif

    static var biometricsAvailable: Bool {
        #if os(iOS)
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        #else
        false
        #endif
    }

    // MARK: - Private

    private func credential(for key: String) -> ParentalLockCredential? {
        if !loaded.contains(key) {
            loaded.insert(key)
            credentials[key] = storage.getAccountLock(key: key)
        }
        return credentials[key]
    }

    @discardableResult
    private func persist(_ credential: ParentalLockCredential, key: String) -> Bool {
        credentials[key] = credential
        loaded.insert(key)
        revision &+= 1
        do {
            try storage.saveAccountLock(credential, key: key)
            return true
        } catch {
            return false
        }
    }

    private static func currentBiometricDomainState() -> Data? {
        #if os(iOS)
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        return context.domainState.biometry.stateHash
        #else
        return nil
        #endif
    }
}
