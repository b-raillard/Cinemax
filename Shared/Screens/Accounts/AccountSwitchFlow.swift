import SwiftUI
import CinemaxKit

/// The « pick a profile » journey, shared by the iOS switcher and the tvOS
/// « Qui regarde ? » screen: try the switch, ask for the account's code — or
/// the parental code when the account is LESS restricted than the current one
/// — then switch, or route an expired account to its sign-in.
///
/// The decisions are `AppState.switchAccount`'s (it refuses `.locked` itself,
/// so no screen can open a protected profile by forgetting a check); this type
/// only drives the steps and the messages.
@MainActor @Observable
final class AccountSwitchFlow {
    enum Step: Equatable {
        case pick
        /// Typing a code to open `account`. `parental` = the parental code
        /// (the account has none of its own but would lift the age cap).
        case code(SavedAccount, parental: Bool)
    }

    private(set) var step: Step = .pick
    var entry: String = ""
    private(set) var message: String?
    private(set) var isWorking = false
    /// An account whose session the server refused: the screen presents its
    /// sign-in (`UserSwitchSheet(prefilledUsername:)`).
    var reconnect: SavedAccount?

    /// A reconnection (password step, Quick Connect) just closed: the screen
    /// closes too when the active account changed — to the account it was
    /// opened for, or to another one signed in from the same step (« Annuler »
    /// on the prefilled password leads to the server's user list).
    nonisolated static func reconnectionOpened(before: String?, after: String?) -> Bool {
        after != nil && after != before
    }

    /// Tries to open `account`. `true` = switched (the caller dismisses).
    func select(
        _ account: SavedAccount,
        appState: AppState,
        locks: AccountLockStore,
        toasts: ToastCenter,
        loc: LocalizationManager
    ) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        let result = await appState.switchAccount(to: account.userId)
        return handle(result, account: account, hasOwnCode: Self.hasOwnCode(account, appState: appState, locks: locks), toasts: toasts, loc: loc)
    }

    /// Checks the typed code, then switches. `true` = switched.
    func submit(
        appState: AppState,
        locks: AccountLockStore,
        parentalLock: ParentalLockController,
        toasts: ToastCenter,
        loc: LocalizationManager
    ) async -> Bool {
        guard case .code(let account, let parental) = step, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        let pin = entry
        entry = ""
        let verdict: ParentalLockVerdict
        if parental {
            verdict = await parentalLock.verify(pin: pin)
        } else {
            guard let key = appState.accountKey(for: account) else { return false }
            verdict = await locks.verify(key: key, pin: pin)
        }
        switch verdict {
        case .unlocked:
            message = nil
            // The parental code opened ONE switch, not the parental settings:
            // `verify` leaves the controller unlocked for the session, which
            // would hand Privacy & Security and « Gérer les comptes » to
            // whoever holds the device next. Closed again at once.
            if parental { parentalLock.lockForBackground() }
            let result = await appState.switchAccount(to: account.userId, unlocked: true)
            return handle(result, account: account, hasOwnCode: Self.hasOwnCode(account, appState: appState, locks: locks), toasts: toasts, loc: loc)
        case .wrong(_, let attemptsLeft):
            message = attemptsLeft > 0
                ? loc.localized("accounts.pin.wrong")
                : loc.localized("accounts.pin.wrongLast")
            Haptics.error()
            return false
        case .throttled(let until, _):
            let seconds = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
            message = loc.localized("accounts.pin.throttled", seconds)
            Haptics.warning()
            return false
        }
    }

    #if os(iOS)
    /// Face ID past the code (the account's own code only — the parental
    /// lock's Face ID is offered by its own controller's rules).
    func biometrics(
        appState: AppState,
        locks: AccountLockStore,
        parentalLock: ParentalLockController,
        toasts: ToastCenter,
        loc: LocalizationManager
    ) async -> Bool {
        guard case .code(let account, let parental) = step else { return false }
        let reason = loc.localized("accounts.faceID.reason", account.username)
        let ok: Bool
        if parental {
            ok = await parentalLock.unlockWithBiometrics(reason: reason)
            // Same as the code path: one switch, not the parental settings.
            if ok { parentalLock.lockForBackground() }
        } else {
            guard let key = appState.accountKey(for: account) else { return false }
            ok = await locks.unlockWithBiometrics(key: key, reason: reason)
        }
        guard ok else { return false }
        let result = await appState.switchAccount(to: account.userId, unlocked: true)
        return handle(result, account: account, hasOwnCode: Self.hasOwnCode(account, appState: appState, locks: locks), toasts: toasts, loc: loc)
    }
    #endif

    func back() {
        step = .pick
        entry = ""
        message = nil
    }

    private static func hasOwnCode(_ account: SavedAccount, appState: AppState, locks: AccountLockStore) -> Bool {
        appState.accountKey(for: account).map(locks.hasLock) ?? false
    }

    private func handle(
        _ result: AppState.AccountSwitchResult,
        account: SavedAccount,
        hasOwnCode: Bool,
        toasts: ToastCenter,
        loc: LocalizationManager
    ) -> Bool {
        switch result {
        case .switched:
            step = .pick
            toasts.success(loc.localized("accounts.switchedTo", account.username))
            return true
        case .locked:
            step = .code(account, parental: !hasOwnCode)
            entry = ""
            message = nil
            return false
        case .needsLogin:
            step = .pick
            reconnect = account
            return false
        case .offline:
            toasts.error(loc.localized("accounts.offline"))
            return false
        case .unreachable:
            toasts.error(loc.localized("accounts.unreachable"))
            return false
        }
    }
}

extension AppState {
    /// `serverId|userId` of a remembered account of the ACTIVE server.
    func accountKey(for account: SavedAccount) -> String? {
        guard let activeServerId else { return nil }
        return ServerRegistry.accountKey(serverId: activeServerId, userId: account.userId)
    }

    func isExpired(_ account: SavedAccount) -> Bool {
        accountKey(for: account).map(expiredAccountIds.contains) ?? false
    }

    /// Whether opening `account` will ask for a sign-in: always in free (other
    /// than the current account), else when this device holds no valid session.
    func needsSignIn(_ account: SavedAccount) -> Bool {
        account.userId != currentUserId && (!keepsAccountSessions || !account.hasSession || isExpired(account))
    }
}
