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
    /// Seerr knows the user; `autoApproves` = their requests need no approval.
    case linked(autoApproves: Bool)
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
            return .linked(autoApproves: seerrUser.permissions.autoApproves(.movie)
                           && seerrUser.permissions.autoApproves(.tv))
        }
        return newPlexLogin ? .willBeCreated : .mustBeAdded
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

    var enabledCount: Int { lines.filter(\.isEnabled).count }

    /// The admin's own address — what `setEnabled(true)` writes for a user.
    @ObservationIgnored private var address: URL?

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
        guard session.isCurrent(snapshot) else { return }

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

    /// Read → change → write one user's entity. Throws when either call does.
    private func write(
        userId: String, appState: AppState, _ change: (SeerrUserConfig) -> SeerrUserConfig
    ) async throws {
        let api = appState.apiClient
        let dto = try await api.getDisplayPreferences(
            id: SeerrUserConfig.preferencesId, client: SeerrUserConfig.client, userId: userId)
        let next = change(SeerrUserConfig.read(dto))
        try await api.updateDisplayPreferences(
            SeerrUserConfig.merged(next, into: dto),
            id: SeerrUserConfig.preferencesId, client: SeerrUserConfig.client, userId: userId)
    }

    private func record(_ userId: String, enabled: Bool) {
        guard let index = lines.firstIndex(where: { $0.id == userId }) else { return }
        lines[index].isEnabled = enabled
    }

    /// `nil` on success, else the sentence to show the admin.
    func setEnabled(_ on: Bool, userId: String, appState: AppState, loc: LocalizationManager) async -> String? {
        let line = lines.first { $0.id == userId }
        let name = line?.name ?? ""
        if on, line?.kind == .ageCapped {
            return loc.localized("seerr.activation.refused.capped", name)
        }
        let target = address
        if on, target == nil { return loc.localized("seerr.activation.noAddress") }
        let account = appState.activeAccountKey
        do {
            try await write(userId: userId, appState: appState) { existing in
                // Off keeps the address already stored: `merged` would drop it.
                SeerrUserConfig(isEnabled: on, url: on ? target : existing.url)
            }
        } catch {
            logger.notice("Seerr ▸ activation write failed")
            return loc.localized(on ? "seerr.activation.failed.enable" : "seerr.activation.failed.disable", name)
        }
        if appState.activeAccountKey == account { record(userId, enabled: on) }
        return nil
    }

    /// Enables everyone who can be; returns the sentence summarising it.
    func enableAll(appState: AppState, loc: LocalizationManager) async -> String {
        var refused: [String] = []
        var failed: [String] = []
        for line in lines {
            if line.kind == .ageCapped {
                refused.append(line.name)
            } else if !line.isEnabled {
                if await setEnabled(true, userId: line.id, appState: appState, loc: loc) != nil {
                    failed.append(line.name)
                }
            }
        }
        return Self.activationSummary(enabled: enabledCount, refusedNames: refused, failedNames: failed, loc: loc)
    }

    /// Switches every enabled user off, each keeping the address already
    /// stored — the admin's included.
    func disableAll(appState: AppState) async {
        let account = appState.activeAccountKey
        for line in lines where line.isEnabled {
            do {
                try await write(userId: line.id, appState: appState) {
                    SeerrUserConfig(isEnabled: false, url: $0.url)
                }
                if appState.activeAccountKey == account { record(line.id, enabled: false) }
            } catch {
                logger.notice("Seerr ▸ deactivation write failed")
            }
        }
    }

    /// The admin changed the Seerr address: the admin's own entity and every
    /// enabled user's carry it from now on. A disabled user is left alone.
    func setAddress(_ url: URL, appState: AppState) async {
        var targets = lines.filter(\.isEnabled).map(\.id)
        if let adminId = appState.currentUserId, !targets.contains(adminId) { targets.append(adminId) }
        for userId in targets {
            do {
                try await write(userId: userId, appState: appState) { SeerrUserConfig(isEnabled: $0.isEnabled, url: url) }
            } catch {
                logger.notice("Seerr ▸ address write failed")
            }
        }
        address = url
    }

    // MARK: Wording

    /// « Activé pour 3 utilisateurs. Tom n'a pas pu être activé : limite d'âge
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
