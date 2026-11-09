import Foundation
import Observation
import OSLog
import CinemaxKit
import JellyfinAPI

/// States and transitions only: never an address, a cookie or a key.
private let logger = Logger(subsystem: "com.cinemax", category: "Seerr")

/// What the admin sees next to a Jellyfin user: whether Seerr will accept them.
enum SeerrUserLineKind: Equatable, Sendable {
    /// The account is capped by age on the server: Seerr is never opened to it.
    case ageCapped
    /// Seerr knows the user: their Seerr id and permissions.
    case linked(SeerrUser)
    /// Seerr does not know them yet but creates the account on first sign-in.
    case willBeCreated
    /// Seerr does not know them and will not create them: the admin must add them.
    case mustBeAdded
    /// The lookup failed (or there is no Seerr credential to ask with).
    case unknown

    /// Pure. The cap wins over everything, then a failed lookup, then what
    /// Seerr answered. Only the SERVER cap is visible from this device: the
    /// other devices' `privacy.maxContentAge` cannot be known.
    nonisolated static func kind(
        policy: UserPolicy?, seerrUser: SeerrUser?, lookupFailed: Bool, newPlexLogin: Bool
    ) -> Self {
        if policy?.maxParentalRating != nil { return .ageCapped }
        if lookupFailed { return .unknown }
        if let seerrUser {
            return .linked(seerrUser)
        }
        return newPlexLogin ? .willBeCreated : .mustBeAdded
    }

    var seerrUser: SeerrUser? {
        if case .linked(let user) = self { user } else { nil }
    }
}

/// Whether the account page may change a user's « Validation automatique »,
/// and why not. Pure. Seerr approves an admin's and a manager's requests
/// whatever the bits say, refuses (403) a change to the caller's own account,
/// and needs `MANAGE_USERS` from the caller — never inferred from Jellyfin's
/// admin flag.
enum SeerrAutoApprovalAccess: Equatable, Sendable {
    case editable
    case alwaysAdmin
    case alwaysManager
    case notAllowed
    case ownAccount

    nonisolated static func of(_ target: SeerrUser, me: SeerrUser?) -> Self {
        if target.permissions.contains(.admin) { return .alwaysAdmin }
        if target.permissions.canManageRequests { return .alwaysManager }
        guard let me, me.permissions.canManageUsers else { return .notAllowed }
        if me.id == target.id { return .ownAccount }
        return .editable
    }

    /// The sentence under the switches when they cannot be changed.
    var noteKey: String? {
        switch self {
        case .editable: nil
        case .alwaysAdmin: "seerr.user.autoApprove.admin"
        case .alwaysManager: "seerr.user.autoApprove.manager"
        case .notAllowed: "seerr.user.autoApprove.notAllowed"
        case .ownAccount: "seerr.user.autoApprove.ownAccount"
        }
    }
}

struct SeerrUserLine: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var isEnabled: Bool
    var kind: SeerrUserLineKind
}

/// The admin's activation of Seerr, user by user (Settings → Demandes). Every
/// write is read → `SeerrUserConfig.merged` → write on that user's own
/// DisplayPreferences, so nothing else stored there is lost, and a user capped
/// by age is never written to `true`.
@MainActor @Observable
final class SeerrActivationModel {
    private(set) var lines: [SeerrUserLine] = []
    /// Users whose « Peut demander » write is under way.
    private(set) var togglingUserIds: Set<String> = []
    /// Users whose permissions are being written: ONE write per user at a
    /// time, since each is a read-modify-write of the whole set.
    private(set) var savingAutoApprove: Set<String> = []

    var enabledCount: Int { lines.filter(\.isEnabled).count }

    /// The admin's own address — what `setEnabled(true)` writes for a user.
    @ObservationIgnored private var address: URL?
    @ObservationIgnored private var loadedAccount: String?

    private enum Lookup: Sendable {
        case skipped
        case failed
        case found(SeerrUser?)
    }

    private struct Loaded: Sendable {
        let index: Int
        let config: SeerrUserConfig
        let lookup: Lookup
    }

    // MARK: Load

    func load(appState: AppState, session: SeerrSession) async {
        guard let snapshot = session.snapshot() else { return }
        // Another account's users are never shown for this one.
        if snapshot.accountKey != loadedAccount {
            lines = []
            address = nil
            loadedAccount = snapshot.accountKey
        }
        let users: [UserDto]
        do {
            users = try await appState.apiClient.getUsers()
        } catch {
            logger.notice("Seerr ▸ users unreadable")
            return
        }
        guard session.isCurrent(snapshot) else { return }

        let api = appState.apiClient
        let hasCredential = session.credential() != nil
        let loaded = await withTaskGroup(of: Loaded.self) { group in
            for (index, user) in users.enumerated() {
                group.addTask { [session] in
                    let config = await Self.readConfig(api: api, userId: user.id)
                    let capped = user.policy?.maxParentalRating != nil
                    guard let id = user.id, !capped else {
                        return Loaded(index: index, config: config, lookup: .skipped)
                    }
                    guard hasCredential else { return Loaded(index: index, config: config, lookup: .failed) }
                    do {
                        let found: SeerrUser? = try await session.perform { client, credential in
                            try await client.user(forJellyfinUserId: id, auth: Self.lookupAuth(credential))
                        }
                        return Loaded(index: index, config: config, lookup: .found(found))
                    } catch {
                        return Loaded(index: index, config: config, lookup: .failed)
                    }
                }
            }
            var all: [Loaded] = []
            for await item in group { all.append(item) }
            return all.sorted { $0.index < $1.index }
        }
        // A load cancelled midway (its trigger moved) holds failed lookups:
        // it must not overwrite what the load replacing it writes.
        guard session.isCurrent(snapshot), !Task.isCancelled else { return }

        let newPlexLogin = session.publicSettings?.newPlexLogin ?? false
        var built: [SeerrUserLine] = []
        for (user, item) in zip(users, loaded) {
            let kind: SeerrUserLineKind
            switch item.lookup {
            case .skipped:
                kind = SeerrUserLineKind.kind(policy: user.policy, seerrUser: nil, lookupFailed: false, newPlexLogin: newPlexLogin)
            case .failed:
                kind = SeerrUserLineKind.kind(policy: user.policy, seerrUser: nil, lookupFailed: true, newPlexLogin: newPlexLogin)
            case .found(let seerrUser):
                kind = SeerrUserLineKind.kind(policy: user.policy, seerrUser: seerrUser, lookupFailed: false, newPlexLogin: newPlexLogin)
            }
            built.append(SeerrUserLine(
                id: user.id ?? "", name: user.name ?? "",
                isEnabled: item.config.isEnabled && kind != .ageCapped, kind: kind))
        }
        if let adminId = appState.currentUserId,
           let index = users.firstIndex(where: { $0.id == adminId }) {
            address = loaded[index].config.url ?? session.config?.url
        } else {
            address = session.config?.url
        }
        lines = built
    }

    nonisolated private static func lookupAuth(_ credential: SeerrCredential) -> SeerrLookupAuth {
        switch credential {
        case .session(let cookie): .session(cookie: cookie)
        case .apiKey(let key, _): .adminKey(key)
        }
    }

    nonisolated private static func readConfig(api: any APIClientProtocol, userId: String?) async -> SeerrUserConfig {
        guard let userId else { return SeerrUserConfig(isEnabled: false, url: nil) }
        let dto = try? await api.getDisplayPreferences(
            id: SeerrUserConfig.preferencesId, client: SeerrUserConfig.client, userId: userId)
        return SeerrUserConfig.read(dto)
    }

    // MARK: Writes

    /// Read → change → write one user's entity, on the API client and for the
    /// account captured when the operation began: the account is re-checked
    /// before the read and again before the write, and a switch throws
    /// `CancellationError` — an old account's user ids never reach another
    /// account's server.
    private func write(
        userId: String, appState: AppState, scope: Scope,
        _ change: (SeerrUserConfig) -> SeerrUserConfig
    ) async throws {
        guard appState.activeAccountKey == scope.account else { throw CancellationError() }
        let dto = try await scope.api.getDisplayPreferences(
            id: SeerrUserConfig.preferencesId, client: SeerrUserConfig.client, userId: userId)
        let next = change(SeerrUserConfig.read(dto))
        guard appState.activeAccountKey == scope.account else { throw CancellationError() }
        try await scope.api.updateDisplayPreferences(
            SeerrUserConfig.merged(next, into: dto),
            id: SeerrUserConfig.preferencesId, client: SeerrUserConfig.client, userId: userId)
    }

    /// The API client and account an operation started on.
    @MainActor private struct Scope {
        let api: any APIClientProtocol
        let account: String?
        init(_ appState: AppState) {
            api = appState.apiClient
            account = appState.activeAccountKey
        }
    }

    private func record(_ userId: String, enabled: Bool) {
        guard let index = lines.firstIndex(where: { $0.id == userId }) else { return }
        lines[index].isEnabled = enabled
    }

    /// `nil` on success, else the sentence to show the admin.
    func setEnabled(_ on: Bool, userId: String, appState: AppState, loc: LocalizationManager) async -> String? {
        await setEnabled(on, userId: userId, appState: appState, scope: Scope(appState), loc: loc)
    }

    private func setEnabled(
        _ on: Bool, userId: String, appState: AppState, scope: Scope, loc: LocalizationManager
    ) async -> String? {
        let line = lines.first { $0.id == userId }
        let name = line?.name ?? ""
        if on {
            // The cap is only known from the lines: an unknown id is never enabled.
            guard let line else { return loc.localized("seerr.activation.failed.enable", name) }
            if line.kind == .ageCapped { return loc.localized("seerr.activation.refused.capped", name) }
        }
        let target = address
        if on, target == nil { return loc.localized("seerr.activation.noAddress") }
        do {
            try await write(userId: userId, appState: appState, scope: scope) { existing in
                // Off keeps the address already stored: `merged` would drop it.
                SeerrUserConfig(isEnabled: on, url: on ? target : existing.url)
            }
        } catch is CancellationError {
            return nil
        } catch {
            logger.notice("Seerr ▸ activation write failed")
            return loc.localized(on ? "seerr.activation.failed.enable" : "seerr.activation.failed.disable", name)
        }
        if appState.activeAccountKey == scope.account { record(userId, enabled: on) }
        return nil
    }

    /// Enables everyone who can be; returns the sentence summarising it.
    func enableAll(appState: AppState, loc: LocalizationManager) async -> String {
        let scope = Scope(appState)
        var refused: [String] = []
        var failed: [String] = []
        for line in lines {
            guard appState.activeAccountKey == scope.account else { break }
            if line.kind == .ageCapped {
                refused.append(line.name)
            } else if !line.isEnabled {
                let message = await setEnabled(true, userId: line.id, appState: appState, scope: scope, loc: loc)
                if message != nil { failed.append(line.name) }
            }
        }
        return Self.activationSummary(enabled: enabledCount, refusedNames: refused, failedNames: failed, loc: loc)
    }

    /// Switches every enabled user off, each keeping the address already
    /// stored — the admin's included. `nil` = all done, else who could not be.
    func disableAll(appState: AppState, loc: LocalizationManager) async -> String? {
        let scope = Scope(appState)
        var failed: [String] = []
        for line in lines where line.isEnabled {
            do {
                try await write(userId: line.id, appState: appState, scope: scope) {
                    SeerrUserConfig(isEnabled: false, url: $0.url)
                }
                if appState.activeAccountKey == scope.account { record(line.id, enabled: false) }
            } catch is CancellationError {
                return nil
            } catch {
                logger.notice("Seerr ▸ deactivation write failed")
                failed.append(line.name)
            }
        }
        return Self.failureSentence("seerr.activation.summary.disableFailed", failed, loc)
    }

    /// The admin changed the Seerr address: the admin's own entity and every
    /// enabled user's carry it from now on. A disabled user is left alone. The
    /// remembered address only moves once the admin's own write succeeded.
    func setAddress(_ url: URL, appState: AppState, loc: LocalizationManager) async -> String? {
        let scope = Scope(appState)
        let adminId = appState.currentUserId
        var targets: [(id: String, name: String)] = []
        if let adminId {
            // The lines may not be loaded yet: the admin is the signed-in user.
            targets.append((adminId, lines.first { $0.id == adminId }?.name ?? appState.currentUser?.name ?? ""))
        }
        for line in lines where line.isEnabled && line.id != adminId { targets.append((line.id, line.name)) }
        var failed: [String] = []
        var adminWritten = false
        for target in targets {
            do {
                try await write(userId: target.id, appState: appState, scope: scope) {
                    SeerrUserConfig(isEnabled: $0.isEnabled, url: url)
                }
                if target.id == adminId { adminWritten = true }
            } catch is CancellationError {
                return nil
            } catch {
                logger.notice("Seerr ▸ address write failed")
                failed.append(target.name)
            }
        }
        if adminWritten { address = url }
        return Self.failureSentence("seerr.activation.summary.addressFailed", failed, loc)
    }

    /// « Peut demander » pressed, from the list or the account page: a refusal
    /// (age cap, no address yet) informs, a failed write is an error.
    func toggle(
        _ line: SeerrUserLine, appState: AppState, session: SeerrSession, toasts: ToastCenter, loc: LocalizationManager
    ) async {
        guard !togglingUserIds.contains(line.id) else { return }
        togglingUserIds.insert(line.id)
        defer { togglingUserIds.remove(line.id) }
        let turningOn = !line.isEnabled
        if let message = await setEnabled(turningOn, userId: line.id, appState: appState, loc: loc) {
            if turningOn, line.kind == .ageCapped || session.config?.url == nil {
                toasts.info(message)
            } else {
                toasts.error(message)
            }
            return
        }
        // The admin's own switch changes the admin's own configuration (R22).
        if line.id == appState.currentUserId { await session.reload(appState: appState) }
    }

    /// Switches one kind's « Validation automatique » for a linked user:
    /// Seerr's CURRENT set is read, only the auto-approve bits change
    /// (`settingAutoApprove`), and the line takes what Seerr stored. `false`
    /// only when Seerr refused or did not answer — a press ignored, or an
    /// account that moved meanwhile, is not a failure to show.
    func setAutoApprove(
        _ kind: SeerrMediaKind, _ on: Bool, userId: String, session: SeerrSession, appState: AppState
    ) async -> Bool {
        guard !savingAutoApprove.contains(userId),
              let line = lines.first(where: { $0.id == userId }), let target = line.kind.seerrUser else { return true }
        savingAutoApprove.insert(userId)
        defer { savingAutoApprove.remove(userId) }
        let account = appState.activeAccountKey
        do {
            let stored = try await session.perform { client, credential in
                let current = try await client.permissions(ofUser: target.id, credential)
                return try await client.setPermissions(
                    current.settingAutoApprove(kind, on), ofUser: target.id, credential)
            }
            guard appState.activeAccountKey == account,
                  let index = lines.firstIndex(where: { $0.id == userId }) else { return true }
            lines[index].kind = .linked(SeerrUser(
                id: target.id, permissions: stored,
                jellyfinUserId: target.jellyfinUserId, displayName: target.displayName))
            return true
        } catch is CancellationError {
            return true
        } catch {
            logger.notice("Seerr ▸ auto-approval write failed")
            return false
        }
    }

    /// The line under a user's name: their state in Seerr, and for a linked
    /// user what Seerr approves without review.
    static func lineText(_ kind: SeerrUserLineKind, loc: LocalizationManager) -> String {
        switch kind {
        case .ageCapped: return loc.localized("seerr.settings.line.ageCapped")
        case .linked(let user):
            let movies = user.permissions.autoApproves(.movie)
            let series = user.permissions.autoApproves(.tv)
            let key = switch (movies, series) {
            case (true, true): "seerr.settings.line.linkedAutoApprove"
            case (true, false): "seerr.settings.line.linkedAutoApproveMovies"
            case (false, true): "seerr.settings.line.linkedAutoApproveSeries"
            case (false, false): "seerr.settings.line.linked"
            }
            return loc.localized(key)
        case .willBeCreated: return loc.localized("seerr.settings.line.willBeCreated")
        case .mustBeAdded: return loc.localized("seerr.settings.line.mustBeAdded")
        case .unknown: return loc.localized("seerr.settings.line.unknown")
        }
    }

    private static func failureSentence(_ key: String, _ names: [String], _ loc: LocalizationManager) -> String? {
        names.isEmpty ? nil : loc.localized(loc.pluralKey(key, names.count), names.joined(separator: ", "))
    }

    // MARK: Wording

    /// « Activé pour 3 utilisateurs. Impossible d'activer Tom : limite d'âge
    /// sur son compte. »
    static func activationSummary(
        enabled: Int, refusedNames: [String], failedNames: [String] = [], loc: LocalizationManager
    ) -> String {
        var parts = [loc.counted("seerr.activation.summary.enabled", enabled)]
        if !refusedNames.isEmpty {
            parts.append(loc.localized(
                loc.pluralKey("seerr.activation.summary.refused", refusedNames.count),
                refusedNames.joined(separator: ", ")))
        }
        if !failedNames.isEmpty {
            parts.append(loc.localized(
                loc.pluralKey("seerr.activation.summary.failed", failedNames.count),
                failedNames.joined(separator: ", ")))
        }
        return parts.joined(separator: " ")
    }
}
