import Foundation
import CryptoKit

/// Stored state of the parental-controls lock: the PIN verifier, the throttle
/// counters, and whether biometrics may stand in for the PIN on this install.
///
/// Persisted as one JSON blob in the app-private Keychain
/// (`KeychainService.getParentalLock()`), never in `UserDefaults` — the whole
/// point of the feature is that the person it restrains has the device in their
/// hands, and a `UserDefaults` plist is readable and writable from a paired Mac.
///
/// `iterations` travels WITH the credential rather than being read from
/// `ParentalLockPolicy.iterations` at verify time: raising the constant later
/// must not invalidate an enrolled PIN. A credential is re-hashed at the current
/// cost only when the user sets a new PIN.
public struct ParentalLockCredential: Codable, Sendable, Equatable {
    /// Per-install random salt. Its only job is to stop one leaked digest from
    /// being looked up in a rainbow table of the 10 000 four-digit PINs.
    public var salt: Data
    /// `ParentalLockPolicy.hash(pin:salt:iterations:)` of the enrolled PIN.
    public var hash: Data
    public var iterations: Int
    /// Consecutive wrong PINs since the last success. Reset by a success, and
    /// stored so a force-quit cannot clear the back-off.
    public var failedAttempts: Int
    /// Instant before which no attempt is even hashed. `nil` = no back-off.
    public var lockedUntil: Date?
    /// Whether Face ID / Touch ID may unlock instead of the PIN. Advisory: the
    /// PIN always remains a valid path, so a broken sensor can never lock the
    /// parent out of their own settings.
    public var biometricsEnabled: Bool

    public init(
        salt: Data,
        hash: Data,
        iterations: Int,
        failedAttempts: Int = 0,
        lockedUntil: Date? = nil,
        biometricsEnabled: Bool = false
    ) {
        self.salt = salt
        self.hash = hash
        self.iterations = iterations
        self.failedAttempts = failedAttempts
        self.lockedUntil = lockedUntil
        self.biometricsEnabled = biometricsEnabled
    }
}

/// Outcome of one unlock attempt. Carries the UPDATED credential so the caller
/// persists exactly what the policy decided — the throttle counters are part of
/// the verdict, not a side effect the caller has to reconstruct.
public enum ParentalLockVerdict: Sendable, Equatable {
    /// Correct PIN. The credential has its counters cleared; persist it.
    case unlocked(ParentalLockCredential)
    /// Wrong PIN. `attemptsLeft` is how many more are free before the next
    /// back-off window opens (0 once one is open).
    case wrong(ParentalLockCredential, attemptsLeft: Int)
    /// A back-off window is still open; the PIN was NOT hashed or compared.
    case throttled(until: Date)
}

/// Pure logic of the parental-controls lock: PIN shape, hashing, verification
/// and the failed-attempt back-off.
///
/// **RULE — this is the ONLY place a PIN is turned into a digest, and the digest
/// is all that is ever stored.** Everything here is `nonisolated` and free of
/// I/O so it can be exercised without a Keychain and run OFF the main actor:
/// `hash` is deliberately expensive (see `iterations`), and the unlock screen
/// calls it from a detached task rather than hitching the main thread.
///
/// **What this lock is worth, stated honestly.** It closes the one in-app path
/// that lifts the client-side content-age cap (the Privacy & Security age row).
/// It is NOT a boundary against someone who can read the Keychain — anyone who
/// can has the access token too, i.e. owns the session outright — and it does
/// not survive deleting the app, which drops both `privacy.maxContentAge` and
/// the stored session, so signing back in costs the Jellyfin password. The
/// robust control remains the server's own per-user `UserPolicy.maxParentalRating`,
/// which the UI points at.
public enum ParentalLockPolicy {
    /// Shortest PIN accepted. Four digits is the familiar length and gives
    /// 10 000 combinations, which the back-off below turns into days of guessing.
    public static let minPINLength = 4
    /// Longest PIN accepted, so the pad's dot row stays readable.
    public static let maxPINLength = 8

    /// Wrong attempts allowed before the first back-off window opens.
    public static let freeAttempts = 5

    /// Work factor for a NEW credential. Iterated SHA-256 rather than a single
    /// pass: a 4-digit PIN has only 10 000 candidates, so one unsalted hash
    /// would be enumerable in microseconds by anybody who read the blob. This
    /// is not a substitute for the server-side cap (see the type doc) — it just
    /// makes the stored digest cost something to invert.
    public static let iterations = 150_000

    /// Salt length in bytes.
    public static let saltLength = 16

    // MARK: - PIN shape

    /// Accepts only ASCII digits, `minPINLength`…`maxPINLength` of them.
    ///
    /// Digits only because the pad that enters it has ten keys, on both
    /// platforms — a PIN a remote cannot type would be a lockout, not a lock.
    public static func isValidPIN(_ pin: String) -> Bool {
        guard pin.count >= minPINLength, pin.count <= maxPINLength else { return false }
        return pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: - Hashing

    /// Iterated SHA-256 over `salt ‖ pin`, re-mixing the salt at every round so
    /// the chain cannot be shortened by precomputing a suffix.
    ///
    /// Deterministic and side-effect-free, which is what lets the unlock screen
    /// run it on a detached task.
    public static func hash(pin: String, salt: Data, iterations: Int) -> Data {
        let rounds = max(1, iterations)
        var digest = Data(SHA256.hash(data: salt + Data(pin.utf8)))
        for _ in 1..<rounds {
            digest = Data(SHA256.hash(data: salt + digest))
        }
        return digest
    }

    /// Builds a credential for `pin`, or `nil` when the PIN fails
    /// `isValidPIN`. `salt` is injectable so a test can pin the digest; every
    /// production caller omits it and gets fresh randomness.
    public static func makeCredential(
        pin: String,
        biometricsEnabled: Bool,
        salt: Data? = nil,
        iterations: Int = Self.iterations
    ) -> ParentalLockCredential? {
        guard isValidPIN(pin) else { return nil }
        let salt = salt ?? randomSalt()
        return ParentalLockCredential(
            salt: salt,
            hash: hash(pin: pin, salt: salt, iterations: iterations),
            iterations: iterations,
            biometricsEnabled: biometricsEnabled
        )
    }

    /// `saltLength` cryptographically-random bytes.
    public static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // `SecRandomCopyBytes` does not fail in practice. If it ever did,
            // falling back to `SystemRandomNumberGenerator` keeps enrolment
            // working with a still-unpredictable salt rather than shipping a
            // constant one — which would be the only genuinely broken outcome.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<saltLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes)
    }

    // MARK: - Verification

    /// Verifies `pin` against `credential` and returns the credential to persist.
    ///
    /// **A throttled attempt is refused BEFORE hashing**, so mashing the pad
    /// during a back-off window costs neither CPU nor an extra failure — the
    /// window would otherwise extend itself on every press and the parent could
    /// be locked out by a child hammering keys.
    public static func verify(
        pin: String,
        against credential: ParentalLockCredential,
        now: Date = Date()
    ) -> ParentalLockVerdict {
        if let until = credential.lockedUntil, until > now {
            return .throttled(until: until)
        }

        let candidate = hash(pin: pin, salt: credential.salt, iterations: credential.iterations)
        if constantTimeEquals(candidate, credential.hash) {
            var cleared = credential
            cleared.failedAttempts = 0
            cleared.lockedUntil = nil
            return .unlocked(cleared)
        }

        var failed = credential
        failed.failedAttempts = credential.failedAttempts + 1
        // An expired window is cleared, not carried: the next failure re-derives
        // its own from the (now higher) count.
        failed.lockedUntil = backoff(afterFailures: failed.failedAttempts).map { now.addingTimeInterval($0) }
        let left = max(0, freeAttempts - failed.failedAttempts)
        return .wrong(failed, attemptsLeft: left)
    }

    /// Back-off for a given number of CONSECUTIVE failures, or `nil` while the
    /// free attempts last.
    ///
    /// Escalates then plateaus at an hour: an unbounded schedule turns a child's
    /// fiddling into the parent losing access to their own settings for a week.
    /// With this curve, exhausting the 10 000 four-digit PINs takes years.
    public static func backoff(afterFailures failures: Int) -> TimeInterval? {
        guard failures > freeAttempts else { return nil }
        switch failures - freeAttempts {
        case 1:  return 30
        case 2:  return 60
        case 3:  return 5 * 60
        case 4:  return 15 * 60
        default: return 60 * 60
        }
    }

    /// Length-independent byte comparison. The threat it answers is modest (see
    /// the type doc — reading the digest already implies owning the session),
    /// but a digest comparison that leaks its prefix on timing is the kind of
    /// detail worth not writing in the first place.
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (l, r) in zip(lhs, rhs) { difference |= l ^ r }
        return difference == 0
    }
}
