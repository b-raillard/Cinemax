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
    /// Instant before which no attempt is even hashed, on the WALL clock.
    /// Kept for display and for credentials written before `backoffAnchor`;
    /// the back-off itself is measured on `backoffAnchor` (see there).
    public var lockedUntil: Date?
    /// The open back-off window, measured on the monotonic clock. `nil` = none,
    /// or a credential written before it existed (see
    /// `ParentalLockPolicy.backoffRemaining`).
    public var backoffAnchor: ParentalLockBackoffAnchor?
    /// Number of digits of the enrolled PIN, when known: recorded at
    /// enrolment and learned at the next PIN unlock of an older credential.
    /// Only used to invite the parent to move to `minPINLength` digits.
    public var pinLength: Int?
    /// Whether Face ID / Touch ID may unlock instead of the PIN. Advisory: the
    /// PIN always remains a valid path, so a broken sensor can never lock the
    /// parent out of their own settings.
    public var biometricsEnabled: Bool
    /// `LAContext.evaluatedPolicyDomainState` when the biometric shortcut was
    /// armed — the fingerprint of the SET of enrolled faces / fingers. Optional
    /// so a credential stored before it existed keeps decoding; `nil` means
    /// "not armed", and only a PIN unlock arms it (see
    /// `ParentalLockPolicy.biometricsAllowed`).
    public var biometricDomainState: Data?

    public init(
        salt: Data,
        hash: Data,
        iterations: Int,
        failedAttempts: Int = 0,
        lockedUntil: Date? = nil,
        biometricsEnabled: Bool = false,
        biometricDomainState: Data? = nil,
        backoffAnchor: ParentalLockBackoffAnchor? = nil,
        pinLength: Int? = nil
    ) {
        self.salt = salt
        self.hash = hash
        self.iterations = iterations
        self.failedAttempts = failedAttempts
        self.lockedUntil = lockedUntil
        self.biometricsEnabled = biometricsEnabled
        self.biometricDomainState = biometricDomainState
        self.backoffAnchor = backoffAnchor
        self.pinLength = pinLength
    }
}

/// One reading of the two clocks the back-off is measured on.
///
/// The WALL clock is the user's to set: moving the date forward used to close
/// an open back-off window at once (audit 2026-09-22, S9), and the person the
/// lock restrains is the one holding the device. The MONOTONIC clock cannot be
/// set; it restarts at boot, and keeps counting while the device sleeps.
public struct ParentalLockClock: Sendable, Equatable {
    public var wall: Date
    /// Seconds on `CLOCK_MONOTONIC`, which on Darwin keeps counting during
    /// sleep and cannot be adjusted.
    public var monotonic: TimeInterval

    public init(wall: Date, monotonic: TimeInterval) {
        self.wall = wall
        self.monotonic = monotonic
    }

    public static func now() -> ParentalLockClock {
        ParentalLockClock(
            wall: Date(),
            monotonic: TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
        )
    }

    /// The wall instant this reading places the boot at. Constant across the
    /// readings of one boot — until somebody sets the clock, or the device
    /// reboots, which is exactly what it is used to notice.
    var impliedBoot: TimeInterval { wall.timeIntervalSince1970 - monotonic }
}

/// An open back-off window: `duration` seconds from `monotonic`.
public struct ParentalLockBackoffAnchor: Codable, Sendable, Equatable {
    public var wall: Date
    public var monotonic: TimeInterval
    public var duration: TimeInterval

    public init(wall: Date, monotonic: TimeInterval, duration: TimeInterval) {
        self.wall = wall
        self.monotonic = monotonic
        self.duration = duration
    }

    init(clock: ParentalLockClock, duration: TimeInterval) {
        self.init(wall: clock.wall, monotonic: clock.monotonic, duration: duration)
    }

    var impliedBoot: TimeInterval { wall.timeIntervalSince1970 - monotonic }
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
    /// `reanchored` is non-nil when the clock could not be trusted (reboot,
    /// date changed) and the window was restarted — persist it.
    case throttled(until: Date, reanchored: ParentalLockCredential?)
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
    /// Whether a biometric match may unlock: only against the enrolled set it
    /// was armed with.
    ///
    /// The device passcode — which the child being restrained very plausibly
    /// knows — is enough to ADD a face (an "alternate appearance") or a finger
    /// in iOS Settings, after which that child's own face would open the lock.
    /// Any change to the enrolled set changes the domain state, so the shortcut
    /// stands down until the parent's PIN re-arms it. A credential with no
    /// recorded state (armed before this existed, or never) is refused too.
    public static func biometricsAllowed(armedState: Data?, currentState: Data?) -> Bool {
        guard let armedState, let currentState else { return false }
        return armedState == currentState
    }

    /// Shortest PIN a parent can CHOOSE. Six digits — a million combinations —
    /// since audit lot 6 (2026-09-25); it was four. The back-off below turns
    /// even four into days of guessing, but a 4-digit PIN is also the one a
    /// child sees typed over a shoulder, or guesses as a birth year.
    public static let minPINLength = 6
    /// Shortest PIN still ACCEPTED at unlock: a lock enrolled with 4 or 5
    /// digits before the minimum rose keeps working — rejecting it would lock
    /// the parent out of their own settings — and the Privacy screen invites
    /// them to choose a longer one (`needsLongerPIN`).
    public static let minUnlockPINLength = 4
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
        isDigits(pin, minLength: minPINLength)
    }

    /// Whether `pin` is worth hashing at unlock: digits, `minUnlockPINLength`
    /// … `maxPINLength` of them (an older, shorter PIN still opens the lock).
    public static func isUnlockCandidate(_ pin: String) -> Bool {
        isDigits(pin, minLength: minUnlockPINLength)
    }

    private static func isDigits(_ pin: String, minLength: Int) -> Bool {
        guard pin.count >= minLength, pin.count <= maxPINLength else { return false }
        return pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Whether the enrolled PIN is shorter than today's minimum. Unknown length
    /// (a credential not unlocked by PIN since this existed) reads `false`.
    public static func needsLongerPIN(_ credential: ParentalLockCredential) -> Bool {
        guard let length = credential.pinLength else { return false }
        return length < minPINLength
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
            biometricsEnabled: biometricsEnabled,
            pinLength: pin.count
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
        clock: ParentalLockClock = .now()
    ) -> ParentalLockVerdict {
        let window = backoffRemaining(credential, at: clock)
        if window.remaining > 0 {
            return .throttled(until: clock.wall.addingTimeInterval(window.remaining), reanchored: window.reanchored)
        }

        let candidate = hash(pin: pin, salt: credential.salt, iterations: credential.iterations)
        if constantTimeEquals(candidate, credential.hash) {
            var cleared = credential
            cleared.failedAttempts = 0
            cleared.lockedUntil = nil
            cleared.backoffAnchor = nil
            cleared.pinLength = pin.count
            return .unlocked(cleared)
        }

        var failed = credential
        failed.failedAttempts = credential.failedAttempts + 1
        // An expired window is cleared, not carried: the next failure re-derives
        // its own from the (now higher) count.
        let duration = backoff(afterFailures: failed.failedAttempts)
        failed.backoffAnchor = duration.map { ParentalLockBackoffAnchor(clock: clock, duration: $0) }
        failed.lockedUntil = duration.map { clock.wall.addingTimeInterval($0) }
        let left = max(0, freeAttempts - failed.failedAttempts)
        return .wrong(failed, attemptsLeft: left)
    }

    /// How far a reading may place the boot from where the window's anchor
    /// placed it before the clock is considered SET (or the device rebooted).
    /// Network time corrections are milliseconds; a hand-set date is minutes.
    public static let clockTolerance: TimeInterval = 10

    /// Seconds left in the open back-off window at `clock` (0 = none), and a
    /// credential to persist when the window had to be restarted.
    ///
    /// Measured on the MONOTONIC clock (audit 2026-09-22, S9): on the wall
    /// clock, setting the date forward closed the window at once. When the two
    /// clocks disagree with the anchor — the date was set, or the device
    /// rebooted, which restarts the monotonic clock — the time elapsed cannot
    /// be known, so the window RESTARTS with its full duration: moving the
    /// clock can only lengthen a wait, never shorten it. The cost, accepted: a
    /// parent rebooting mid-window waits it out again (at most an hour) — or
    /// uses Face ID, which no window blocks.
    ///
    /// A window found over is returned CLEARED, to persist: an expired anchor
    /// left behind would restart at the next reboot.
    ///
    /// A credential written before the anchor existed carries only
    /// `lockedUntil`; its remaining time (bounded by the longest back-off) is
    /// re-anchored on the monotonic clock here.
    public static func backoffRemaining(
        _ credential: ParentalLockCredential,
        at clock: ParentalLockClock
    ) -> (remaining: TimeInterval, reanchored: ParentalLockCredential?) {
        if let anchor = credential.backoffAnchor {
            let sameBoot = abs(anchor.impliedBoot - clock.impliedBoot) <= clockTolerance
                && clock.monotonic >= anchor.monotonic
            if sameBoot {
                let remaining = anchor.duration - (clock.monotonic - anchor.monotonic)
                if remaining > 0 { return (remaining, nil) }
                // Over, and measured so: drop the anchor, or a later reboot
                // would read it as a window of unknown age and restart it.
                var expired = credential
                expired.backoffAnchor = nil
                expired.lockedUntil = nil
                return (0, expired)
            }
            guard anchor.duration > 0 else { return (0, nil) }
            return (anchor.duration, restarted(credential, duration: anchor.duration, at: clock))
        }
        guard let until = credential.lockedUntil else { return (0, nil) }
        let remaining = min(until.timeIntervalSince(clock.wall), maxBackoff)
        guard remaining > 0 else { return (0, nil) }
        return (remaining, restarted(credential, duration: remaining, at: clock))
    }

    private static func restarted(
        _ credential: ParentalLockCredential,
        duration: TimeInterval,
        at clock: ParentalLockClock
    ) -> ParentalLockCredential {
        var updated = credential
        updated.backoffAnchor = ParentalLockBackoffAnchor(clock: clock, duration: duration)
        updated.lockedUntil = clock.wall.addingTimeInterval(duration)
        return updated
    }

    /// The plateau of `backoff(afterFailures:)`.
    static let maxBackoff: TimeInterval = 60 * 60

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
        default: return maxBackoff
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
