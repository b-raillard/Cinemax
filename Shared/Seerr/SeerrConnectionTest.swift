import Foundation
import CinemaxKit

/// What « Tester la connexion » found: the lines it verified (already
/// localized), the warnings that do not block saving, or the first failure.
struct SeerrTestReport: Equatable {
    var verified: [String] = []
    var warnings: [String] = []
    var failure: SeerrTestFailure?

    /// A report describes the address it tested: it stays on screen while the
    /// field still names that address (the normalized form the test writes
    /// back included) and goes as soon as the field names another one.
    static func stillApplies(typed: String, testedAddress: URL?) -> Bool {
        SeerrAddress.sameOrigin(SeerrAddress.normalize(typed), testedAddress)
    }
}

/// Checks a Seerr address in a fixed order and stops at the first failure,
/// each with an explicit, fixable message (spec, « Test connection »).
///
/// It tests the TYPED address and saves nothing: the caller (Settings) saves
/// only when the report carries no failure. The key mode is the one with a
/// device key; otherwise the account mode signs in with Quick Connect — the
/// session stores that cookie bound to the typed address, so it is never sent
/// anywhere else.
@MainActor
enum SeerrConnectionTest {
    private static let minimumVersion = ServerVersion(3, 4)

    static func run(
        address: URL, deviceKey: String?, session: SeerrSession, appState: AppState, loc: LocalizationManager
    ) async -> SeerrTestReport {
        let client = session.makeTestClient(for: address)
        var report = SeerrTestReport()

        // 1. Something answers, and it is Seerr.
        let status: SeerrStatusInfo
        do {
            status = try await client.status()
        } catch {
            return stop(at: error, in: report, atStatus: true)
        }
        // 2. Recent enough.
        guard let version = ServerVersion(status.version), version >= minimumVersion else {
            report.failure = .tooOld(status.version)
            return report
        }
        // 3. Backed by a Jellyfin, not Plex or Emby.
        do {
            guard try await client.publicSettings().isJellyfin else {
                report.failure = .notJellyfin
                return report
            }
        } catch {
            return stop(at: error, in: report)
        }
        report.verified.append(loc.localized("seerr.test.ok.version", status.version))

        let user: SeerrUser
        let key = deviceKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty {
            // 4a. Key mode: the key is accepted, the user is imported, and the
            // Jellyfin Seerr talks to is this one.
            guard let userId = appState.currentUserId else { return SeerrTestReport() }
            do {
                // The server id first: a Seerr linked to another Jellyfin must
                // say so, not « not in Seerr ». Unknown on our side ⇒ closed.
                let seerrServerId = try await client.jellyfinServerId(adminKey: key)
                let own = appState.serverInfo?.serverID
                    ?? appState.servers.first { $0.id == appState.activeServerId }?.serverID
                guard let own, !own.isEmpty, seerrServerId == own else {
                    report.failure = .otherJellyfin
                    return report
                }
                guard let found = try await client.user(forJellyfinUserId: userId, auth: .adminKey(key)) else {
                    report.failure = .notInSeerr
                    return report
                }
                user = found
            } catch SeerrError.forbidden {
                report.failure = .keyRefused
                return report
            } catch {
                return stop(at: error, in: report)
            }
            report.verified.append(loc.localized("seerr.test.ok.server", appState.activeServerDisplayName))
        } else {
            // 4b. Account mode: the one-gesture sign-in works end to end.
            // Without Quick Connect, Jellyfin's refusal would read as a device
            // one; a probe that does not get through says nothing about it.
            let quickConnectOn: Bool
            do {
                quickConnectOn = try await appState.apiClient.isQuickConnectEnabled()
            } catch is CancellationError {
                return SeerrTestReport()
            } catch {
                report.failure = .unreachable
                return report
            }
            guard quickConnectOn else {
                report.failure = .quickConnectOff
                return report
            }
            switch await session.signIn(address: address, appState: appState) {
            case .success(let signedIn):
                user = signedIn
            case .failure(let error):
                // `.cancelled` maps to nothing: an empty report (R19).
                guard let failure = SeerrAccess.signInFailure(error, policy: appState.currentUser?.policy) else {
                    return SeerrTestReport()
                }
                report.failure = failure
                return report
            }
            report.verified.append(loc.localized("seerr.test.ok.server", appState.activeServerDisplayName))
            report.verified.append(loc.localized("seerr.test.ok.quickConnect"))
            // From an HTTPS Jellyfin, this session will only ever be renewed
            // by the visible sign-in (`SeerrAccess.downgradesFromHTTPS`). Key
            // mode renews nothing: no warning there.
            if SeerrAccess.downgradesFromHTTPS(jellyfin: appState.serverURL, seerr: address) {
                report.warnings.append(loc.localized("seerr.test.warning.httpSeerr"))
            }
        }

        report.verified.append(loc.localized("seerr.test.ok.account", roles(of: user.permissions, loc: loc)))
        if !user.permissions.canManageRequests {
            report.warnings.append(loc.localized("seerr.test.warning.cannotManage"))
        }
        return report
    }

    /// `atStatus`: the first call. Only there is an HTTP answer that is not
    /// Seerr's — Jellyfin's own empty 404 on `/api/v1/status` when the port is
    /// 8096 — « a server answers, but not Seerr »; once `/status` has answered
    /// as Seerr, a later error is not the port's. A gateway error (502–504) is
    /// a reverse proxy speaking for a Seerr that is down: « ne répond pas ».
    private static func stop(at error: Error, in report: SeerrTestReport, atStatus: Bool = false) -> SeerrTestReport {
        var report = report
        if error is CancellationError { return SeerrTestReport() }
        switch error as? SeerrError {
        case .redirected: report.failure = .redirected
        case .notSeerr: report.failure = .notSeerr
        case .unreachable, nil: report.failure = .unreachable
        case .http(let code) where (502...504).contains(code): report.failure = .unreachable
        case .some: report.failure = atStatus ? .notSeerr : .unreachable
        }
        return report
    }

    /// « administrateur », « validation automatique », « peut valider »…
    private static func roles(of permissions: SeerrPermissions, loc: LocalizationManager) -> String {
        var parts: [String] = []
        if permissions.contains(.admin) { parts.append(loc.localized("seerr.test.ok.role.admin")) }
        if permissions.autoApproves(.movie) || permissions.autoApproves(.tv) {
            parts.append(loc.localized("seerr.test.ok.role.autoApprove"))
        }
        if permissions.canManageRequests { parts.append(loc.localized("seerr.test.ok.role.manage")) }
        if parts.isEmpty { parts.append(loc.localized("seerr.test.ok.role.request")) }
        return parts.joined(separator: ", ")
    }
}
