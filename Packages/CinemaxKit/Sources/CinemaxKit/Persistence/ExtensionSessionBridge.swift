import Foundation
import OSLog
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(TVServices)
import TVServices
#endif

private let logger = Logger(subsystem: "com.cinemax", category: "ExtensionBridge")

/// Hands the Jellyfin session to the app extensions (iOS widget, tvOS Top
/// Shelf) through the **shared Keychain access group** — the app *publishes*
/// a snapshot on every session change (login, restore, user switch, logout)
/// and the extensions only ever read. The token is never written in
/// plaintext, so it can't be lifted from the App Group container or a device
/// backup.
///
/// The extensions deliberately don't link CinemaxKit (widget memory budgets
/// are tight) — they re-declare the Keychain service/account/group literals
/// and the same JSON shape. Keep `KeychainService.serviceName` /
/// `sharedSessionAccount` / `sharedAccessGroupSuffix` and `Session`'s coding
/// keys in sync with `Widgets/` and `TopShelf/` if they ever change.
///
/// `appGroupId` / `sessionKey` survive only to name the *legacy* plaintext
/// App Group copy that `publish` scrubs on upgraded installs — nothing reads
/// them any more.
public enum ExtensionSessionBridge {
    public static let appGroupId = "group.com.cinemax.shared"
    public static let sessionKey = "extension.session"

    public struct Session: Codable, Sendable, Equatable {
        public let serverURL: URL
        public let accessToken: String
        public let userId: String
        /// The user's `privacy.maxContentAge` ceiling, so the extensions can
        /// apply the SAME cap the app applies (#230). `0`/`nil` = unrestricted.
        ///
        /// **Optional, and it has to stay optional**: a blob written by a build
        /// that predates this field must keep decoding, and the extensions read
        /// it with `try? JSONDecoder().decode` — a required field would turn
        /// every upgraded install's widget into "not connected" until the next
        /// publish. It rides HERE because the cap lives in app-private
        /// `UserDefaults` the extensions cannot read, and this blob is the only
        /// channel that already exists.
        public let maxContentAge: Int?
        /// SHA-256 of the leaf certificate the user approved for THIS server
        /// (`ServerTrustDelegate`'s pin for its `host:port`), or `nil` when the
        /// server needs none. The pins live in the app-private Keychain group,
        /// which the extensions cannot read — without this, a self-signed server
        /// the app uses read as « not connected » in the widget and the Top
        /// Shelf. Optional for the same backward-compatibility reason as the cap.
        public let pinnedCertificateSHA256: String?

        /// `maxContentAge` / `pinnedCertificateSHA256` default here — unlike on
        /// `publish`, which must never let a call site forget them. Only
        /// `publish` builds one in production; the defaults exist so a test can
        /// state just the fields it cares about.
        public init(
            serverURL: URL,
            accessToken: String,
            userId: String,
            maxContentAge: Int? = nil,
            pinnedCertificateSHA256: String? = nil
        ) {
            self.serverURL = serverURL
            self.accessToken = accessToken
            self.userId = userId
            self.maxContentAge = maxContentAge
            self.pinnedCertificateSHA256 = pinnedCertificateSHA256
        }
    }

    /// Publishes the current session, or clears it when any part is nil
    /// (logout / disconnect).
    ///
    /// `maxContentAge` and `pinnedCertificateSHA256` carry **no default value**, deliberately: a defaulted
    /// `nil` would let a future publish site forget the parental cap and ship a
    /// widget that silently ignores it — exactly the defect #230 exists to
    /// close. A new call site gets a compile error instead, the same discipline
    /// as `MediaCardContextMenu`'s required `artwork:`.
    public static func publish(
        serverURL: URL?,
        accessToken: String?,
        userId: String?,
        maxContentAge: Int?,
        pinnedCertificateSHA256: String?
    ) {
        // Runs on BOTH paths (publish + clear) and *before* the skip
        // early-return below, so an upgraded install's leftover plaintext copy
        // is deleted even when the session itself hasn't changed.
        scrubLegacyDefaultsCopy()

        let incoming: Session? = {
            guard let serverURL, let accessToken, !accessToken.isEmpty,
                  let userId, !userId.isEmpty else { return nil }
            return Session(
                serverURL: serverURL,
                accessToken: accessToken,
                userId: userId,
                maxContentAge: maxContentAge,
                pinnedCertificateSHA256: pinnedCertificateSHA256
            )
        }()

        // In-process memo, checked BEFORE the Keychain. `refreshCurrentUser()`
        // calls this on every foreground — and `SecItemCopyMatching` is a
        // synchronous XPC round-trip to `securityd` made from the main actor,
        // i.e. the same class of main-thread hop as `AVAudioSession`'s. Once
        // this process has published a session, it knows what the store holds
        // without asking: nothing else writes that item (the extensions only
        // ever read it), so a repeat publish of the same session is provably a
        // no-op. The Keychain stays the authority for the FIRST publish of each
        // process, which is the case a fresh launch has to get right.
        if let memo = lastPublishedInProcess, memo.value == incoming {
            logger.debug("ExtensionBridge ▸ session unchanged (memo), skipped")
            return
        }

        let keychain = KeychainService()
        let existingKeychainData = keychain.readSharedSession()
        guard !isCurrent(session: incoming, keychainData: existingKeychainData) else {
            rememberPublished(incoming)
            logger.debug("ExtensionBridge ▸ session unchanged, skipped")
            return
        }
        // Sole store: the shared, device-only Keychain group — the token is
        // never written in plaintext nor included in device backups.
        let written: Bool
        if let session = incoming {
            written = (try? JSONEncoder().encode(session)).map { keychain.saveSharedSession($0) } ?? false
        } else {
            written = keychain.deleteSharedSession()
        }
        // The memo is taken only once the store really holds what was
        // intended (audit 2026-09-22, S8). Taken BEFORE the write, as it used to
        // be, a failed write was then skipped by every later publish of the
        // same session — and a failed clear at logout left the previous token
        // with the widget for the rest of the process.
        guard let memo = memoAfterWrite(of: incoming, succeeded: written) else {
            forgetPublished(clearFailed: incoming == nil)
            logger.error("ExtensionBridge ▸ \(incoming == nil ? "clear" : "publish", privacy: .public) failed — retried on the next publish")
            return
        }
        rememberPublished(memo.value)
        if let session = incoming {
            logger.info("ExtensionBridge ▸ session published host=\(session.serverURL.host() ?? "?", privacy: .public)")
        } else {
            logger.info("ExtensionBridge ▸ session cleared")
        }
        // Writing the snapshot is not enough — the extensions render from
        // their own cached timelines/content. Without an explicit poke the
        // widget keeps its pre-login "sign in" entry for up to its 30-min
        // refresh window after the user logs in (and a stale shelf lingers
        // after logout). Only reached when a write above actually happened.
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        #if canImport(TVServices)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }

    /// Deletes the legacy plaintext App Group copy of the session that 1.0.3
    /// through 1.0.6 dual-wrote. That write is gone (the token now lives only
    /// in the shared Keychain group), but installs upgrading from those builds
    /// still carry the cleartext blob in the App Group container — and in
    /// their backups — until something removes it.
    ///
    /// Presence-guarded on purpose: the steady state costs one
    /// `object(forKey:)` read and never a write, so calling this ahead of
    /// `publish`'s skip early-return doesn't defeat that optimisation. A
    /// missing App Group suite only skips the scrub — it must never abort the
    /// Keychain publish, which doesn't depend on the App Group at all.
    private static func scrubLegacyDefaultsCopy() {
        guard let defaults = UserDefaults(suiteName: appGroupId) else {
            logger.error("ExtensionBridge ▸ App Group suite unavailable — entitlement missing?")
            return
        }
        guard defaults.object(forKey: sessionKey) != nil else { return }
        defaults.removeObject(forKey: sessionKey)
        logger.info("ExtensionBridge ▸ legacy plaintext session copy scrubbed")
    }

    /// Pure equivalence decision: is `session` (nil ⇒ the "clear" intent)
    /// already what's stored in the shared Keychain, so `publish` can skip the
    /// write + WidgetCenter/Top Shelf poke entirely? Compares decoded
    /// `Session` values field-wise (never raw `Data` bytes — JSON key order
    /// isn't guaranteed stable), and treats a corrupt/undecodable stored blob
    /// as "changed" so a bad read never suppresses a legitimate publish.
    /// The legacy plaintext copy is deliberately NOT an input — it's scrubbed
    /// unconditionally by `scrubLegacyDefaultsCopy()`, never republished.
    /// Internal + testable via `@testable import`.
    /// What this process last wrote (or cleared) in the shared Keychain item.
    ///
    /// A box rather than a bare `Session?` so "published nothing yet" and
    /// "published a cleared session" stay distinguishable — the first must
    /// still consult the Keychain, the second must not. Lock-guarded because
    /// `publish` is nonisolated and `KeychainService` is callable from any
    /// actor; `nonisolated(unsafe)` for the same reason `JellyfinAPIClient`'s
    /// fields are, with the same invariant: no access outside these two
    /// helpers.
    struct PublishedMemo: Sendable, Equatable { let value: Session? }
    private static let memoLock = NSLock()
    nonisolated(unsafe) private static var _lastPublishedInProcess: PublishedMemo?
    /// Set when a CLEAR failed, so `retryFailedClear()` knows there is a token
    /// left behind to remove. Same lock and invariant as the memo.
    nonisolated(unsafe) private static var _clearFailed = false

    /// What the memo becomes after a write: the intended session when the
    /// store took it, nothing when it did not — so the next publish goes back
    /// to the Keychain instead of trusting a write that never happened.
    static func memoAfterWrite(of session: Session?, succeeded: Bool) -> PublishedMemo? {
        succeeded ? PublishedMemo(value: session) : nil
    }

    /// Retries a clear that failed at logout. Called on every return to the
    /// foreground; a no-op unless a clear failed in this process, so it never
    /// touches a session published since (a successful publish resets it).
    public static func retryFailedClear() {
        memoLock.lock()
        let pending = _clearFailed
        memoLock.unlock()
        guard pending else { return }
        publish(serverURL: nil, accessToken: nil, userId: nil, maxContentAge: nil, pinnedCertificateSHA256: nil)
    }

    private static var lastPublishedInProcess: PublishedMemo? {
        memoLock.lock()
        defer { memoLock.unlock() }
        return _lastPublishedInProcess
    }

    private static func rememberPublished(_ session: Session?) {
        memoLock.lock()
        _lastPublishedInProcess = PublishedMemo(value: session)
        _clearFailed = false
        memoLock.unlock()
    }

    private static func forgetPublished(clearFailed: Bool) {
        memoLock.lock()
        _lastPublishedInProcess = nil
        _clearFailed = clearFailed
        memoLock.unlock()
    }

    static func isCurrent(session: Session?, keychainData: Data?) -> Bool {
        guard let session else {
            // Clearing: only current if the store is already empty — a stale
            // leftover still needs the clear to run.
            return keychainData == nil
        }
        guard let keychainData,
              let storedKeychainSession = try? JSONDecoder().decode(Session.self, from: keychainData) else {
            return false
        }
        return storedKeychainSession == session
    }
}
