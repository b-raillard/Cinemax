import SwiftUI
import CinemaxKit
import OSLog
#if os(iOS)
import LocalAuthentication
#endif

private let lockLog = Logger(subsystem: "com.cinemax", category: "ParentalLock")

/// Owns the parental-controls lock: the enrolled credential, whether this
/// foreground session has been unlocked, and the three mutations (enrol, change,
/// disable).
///
/// **RULE — this is a process singleton held by `AppNavigation`, and
/// `isUnlocked` is deliberately NOT persisted.** Two reasons it cannot be a
/// plain `@State` store rebuilt on scene events: it reads the Keychain at init
/// (a synchronous XPC round-trip to `securityd` on the main actor — the same
/// class of hop as `AVAudioSession`'s, and the stated reason the other root
/// stores are singletons), and a rebuild would silently *re-open* an unlocked
/// session or drop one the parent is in the middle of using. The unlock lasts
/// until the app backgrounds (`lockForBackground()`, driven by `scenePhase`),
/// never across launches.
///
/// All the decisions live in the pure `ParentalLockPolicy` (CinemaxKit); this
/// type is storage, isolation and the biometric hop.
@MainActor
@Observable
final class ParentalLockController {
    private let keychain = KeychainService()

    /// The enrolled credential, or `nil` when no lock is set.
    private(set) var credential: ParentalLockCredential?

    /// Whether the gate is open for this foreground session.
    private(set) var isUnlocked = false

    /// True while a PIN is being hashed, so the pad can disable itself rather
    /// than queue presses behind a 150 000-round digest.
    private(set) var isVerifying = false

    var isEnabled: Bool { credential != nil }
    var biometricsEnabled: Bool { credential?.biometricsEnabled ?? false }

    /// The instant a back-off window closes, or `nil` when none is open.
    /// Recomputed from the stored credential, so it survives a force-quit.
    var throttledUntil: Date? {
        guard let until = credential?.lockedUntil, until > Date() else { return nil }
        return until
    }

    init() {
        credential = keychain.getParentalLock()
    }

    // MARK: - Biometrics availability

    /// Whether this device can evaluate biometrics at all. Always `false` on
    /// tvOS — an Apple TV has no sensor — which is what hides the row there
    /// rather than offering a switch that could never be honoured.
    static var biometricsAvailable: Bool {
        #if os(iOS)
        var error: NSError?
        let ok = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return ok
        #else
        return false
        #endif
    }

    // MARK: - Gate

    /// Opens the gate without a credential check. Reached only when no lock is
    /// enrolled — i.e. the screen is not protected — so it grants nothing.
    func openWhenNotEnabled() {
        guard credential == nil else { return }
        isUnlocked = true
    }

    /// Closes the gate. Called from `AppNavigation` on `scenePhase == .background`
    /// only: `.inactive` also fires for an app-switcher peek or a Control Center
    /// swipe, and dropping the unlock there would make the parent re-enter the
    /// PIN for having glanced at a notification.
    func lockForBackground() {
        guard credential != nil else { return }
        isUnlocked = false
    }

    // MARK: - Unlock

    /// Verifies a PIN and persists whatever the policy decided — the throttle
    /// counters are part of the verdict.
    ///
    /// The digest runs on a detached task: `ParentalLockPolicy.hash` is
    /// deliberately expensive and would otherwise hitch the main thread for
    /// hundreds of milliseconds on the Apple TV.
    func verify(pin: String) async -> ParentalLockVerdict {
        guard let credential else {
            // No lock: nothing to verify, and the gate is already open.
            isUnlocked = true
            return .unlocked(ParentalLockCredential(salt: Data(), hash: Data(), iterations: 1))
        }
        isVerifying = true
        defer { isVerifying = false }
        let verdict = await Task.detached(priority: .userInitiated) {
            ParentalLockPolicy.verify(pin: pin, against: credential)
        }.value
        switch verdict {
        case .unlocked(let updated):
            persist(updated)
            isUnlocked = true
        case .wrong(let updated, _):
            persist(updated)
        case .throttled:
            break
        }
        return verdict
    }

    #if os(iOS)
    /// Face ID / Touch ID as a shortcut past the PIN.
    ///
    /// **RULE — the policy is `.deviceOwnerAuthenticationWithBiometrics`, never
    /// `.deviceOwnerAuthentication`.** The latter falls back to the DEVICE
    /// passcode, which on the family iPad the child being restrained very
    /// plausibly knows — it would be a bypass wearing the clothes of a stronger
    /// check. `localizedFallbackTitle` is emptied for the same reason, and our
    /// own PIN remains the fallback path.
    ///
    /// **An open PIN back-off window does NOT block this.** A face cannot be
    /// brute-forced, so allowing it bypasses nothing — and refusing it would let
    /// a child mashing the pad lock the parent out of their own settings for an
    /// hour. Success clears the counters, which is the same escape hatch.
    func unlockWithBiometrics(reason: String) async -> Bool {
        guard let credential, credential.biometricsEnabled else { return false }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        // The completion handler is invoked off the main actor, hence `@Sendable`
        // — the same rule the speech-recognition callbacks documented the hard way.
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            ) { @Sendable ok, _ in
                continuation.resume(returning: ok)
            }
        }
        guard success else { return false }
        var cleared = credential
        cleared.failedAttempts = 0
        cleared.lockedUntil = nil
        persist(cleared)
        isUnlocked = true
        return true
    }
    #endif

    // MARK: - Enrolment

    /// Enrols (or replaces) the PIN. Returns `false` when the PIN fails
    /// `ParentalLockPolicy.isValidPIN` or the Keychain write fails — the caller
    /// surfaces that rather than pretending a lock is in place.
    ///
    /// Replacing a PIN is only reachable from behind an open gate, so this needs
    /// no proof of the previous one.
    func enroll(pin: String, useBiometrics: Bool) async -> Bool {
        let effectiveBiometrics = useBiometrics && Self.biometricsAvailable
        // Hoisted out of the `guard` on purpose: a trailing closure inside a
        // `guard` condition is ambiguous with the guard's own body and the
        // parser rejects it.
        let made = await Task.detached(priority: .userInitiated) {
            ParentalLockPolicy.makeCredential(pin: pin, biometricsEnabled: effectiveBiometrics)
        }.value
        guard let fresh = made else { return false }
        guard persist(fresh) else { return false }
        // Enrolling from an open screen must leave it open: the parent is
        // standing right there, and re-asking for the PIN they just chose reads
        // as the lock having failed.
        isUnlocked = true
        return true
    }

    /// Flips the biometric shortcut on an already-enrolled lock. No re-hash —
    /// the flag is metadata, not part of the verifier.
    func setBiometricsEnabled(_ enabled: Bool) {
        guard var credential else { return }
        let effective = enabled && Self.biometricsAvailable
        guard credential.biometricsEnabled != effective else { return }
        credential.biometricsEnabled = effective
        persist(credential)
    }

    /// Removes the lock. Refuses unless the gate is open, so the only way out
    /// of the lock is through it.
    func disable() {
        guard isUnlocked else { return }
        keychain.deleteParentalLock()
        credential = nil
        isUnlocked = true
    }

    // MARK: - Private

    @discardableResult
    private func persist(_ updated: ParentalLockCredential) -> Bool {
        do {
            try keychain.saveParentalLock(updated)
            credential = updated
            return true
        } catch {
            // Keep the in-memory copy in step with what the user just did even
            // when the write failed, so the session behaves coherently; the
            // failure is logged and the next launch re-reads the older blob.
            credential = updated
            lockLog.error("parental-lock keychain write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
