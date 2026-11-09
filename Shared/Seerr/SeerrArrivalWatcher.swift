import Foundation
import OSLog
import CinemaxKit

/// States only: never a title, an id, a cookie or an address.
private let logger = Logger(subsystem: "com.cinemax", category: "Seerr")

/// The arrival message: after the Seerr session's reload that follows every
/// `refreshCurrentUser` (launch, return to the foreground, sign-in, switch),
/// a request of MINE that became available since the last check says so — one
/// title ⇒ « Dune est disponible » + « Regarder », several ⇒ « 3 demandes sont
/// disponibles » + « Voir » (Réglages → Demandes). The buttons are iOS only:
/// the toast window takes no input on tvOS, where the arrived title waits at
/// the top of Mes demandes.
///
/// Never for an account Seerr is not visible for (capped, disabled, no Pro,
/// offline, not connected); always `requestedBy=<my Seerr id>` — a manager's
/// unfiltered list holds the whole household's requests. What was already
/// found available is remembered per account on this device
/// (`SettingsKey.seerrArrivalsSeen`): the first check there seeds it in
/// silence, so a new device never announces a backlog.
@MainActor
enum SeerrArrivalWatcher {
    /// One page, the most recently modified first: what arrived lately.
    nonisolated static let pageSize = 20
    /// How many request ids are remembered per account — the newest kept.
    nonisolated static let maxSeen = 200

    // MARK: Pure

    /// What to announce among `available`, and what is seen afterwards.
    /// `seen == nil` is the first check on this device: everything is seeded,
    /// nothing announced. A title requested twice (two requests of the same
    /// series) is announced once.
    nonisolated static func newArrivals(
        available: [SeerrRequest], seen: Set<Int>?
    ) -> (toAnnounce: [SeerrRequest], seen: Set<Int>) {
        let ids = Set(available.map(\.id))
        guard let seen else { return ([], ids) }
        var titles = Set<String>()
        let fresh = available.filter { request in
            !seen.contains(request.id) && titles.insert("\(request.kind.rawValue)-\(request.media.tmdbId)").inserted
        }
        return (fresh, seen.union(ids))
    }

    /// The ids as stored: what is available NOW first, then the ones seen
    /// before, at most `maxSeen` — so the cap drops the oldest, never one
    /// still on the page (it would be announced again).
    nonisolated static func stored(available: [SeerrRequest], previous: [Int]) -> [Int] {
        var known = Set<Int>()
        let ordered = (available.map(\.id) + previous).filter { known.insert($0).inserted }
        return Array(ordered.prefix(maxSeen))
    }

    // MARK: The check

    /// What to say, if anything — the caller shows it (`ToastCenter.show`).
    /// `openRequests` = « Voir »: Réglages → Demandes, wired by `AppNavigation`
    /// (which owns the Settings sub-navigation).
    static func check(
        session: SeerrSession, appState: AppState, defaults: UserDefaults,
        loc: LocalizationManager, openRequests: @escaping @MainActor () -> Void
    ) async -> Toast? {
        guard session.isVisible(proAllows: session.proAllowsProvider(), isOnline: appState.isOnlineProvider()),
              case .connected(let user) = session.connection,
              let snapshot = session.snapshot() else { return nil }
        let page: SeerrRequestPage
        do {
            page = try await session.perform { client, credential in
                try await client.requests(
                    filter: .available, take: pageSize, skip: 0, requestedBy: user.id, credential)
            }
        } catch {
            // A failure, or the account moved: the next check tries again.
            return nil
        }
        guard session.isCurrent(snapshot) else { return nil }
        // Read AFTER the fetch, written before any other await: two checks
        // running together (a foreground + a `UserUpdated` frame) cannot both
        // announce the same arrival.
        let key = SettingsKey.seerrArrivalsSeen(accountKey: snapshot.accountKey)
        let previous = defaults.array(forKey: key) as? [Int]
        let arrivals = newArrivals(available: page.results, seen: previous.map(Set.init))
        defaults.set(stored(available: page.results, previous: previous ?? []), forKey: key)
        guard !arrivals.toAnnounce.isEmpty else { return nil }
        logger.notice("Seerr ▸ \(arrivals.toAnnounce.count, privacy: .public) request(s) arrived")

        let view = ToastAction(title: loc.localized("seerr.arrival.view")) {
            guard session.isCurrent(snapshot) else { return }
            openRequests()
        }
        guard arrivals.toAnnounce.count == 1, let request = arrivals.toAnnounce.first else {
            return toast(loc.counted("seerr.arrival.several", arrivals.toAnnounce.count), action: view)
        }
        let title = await title(of: request, session: session, appState: appState)
        guard session.isCurrent(snapshot) else { return nil }
        let watch = SeerrMyRequestsModel.watchTarget(request).map { _ in
            ToastAction(title: loc.localized("seerr.myRequests.watch")) {
                guard session.isCurrent(snapshot) else { return }
                SeerrMyRequestsModel.watch(request, appState: appState)
            }
        }
        return toast(
            title.map { loc.localized("seerr.arrival.title", $0) } ?? loc.counted("seerr.arrival.several", 1),
            action: watch ?? view)
    }

    /// An info toast left up long enough to be read at launch.
    private static func toast(_ title: String, action: ToastAction) -> Toast {
        Toast(level: .info, title: title, message: nil, duration: 5, action: action)
    }

    /// The name Jellyfin gives it (it is in the library now), else Seerr's
    /// `/movie` or `/tv` title, else `nil`.
    private static func title(of request: SeerrRequest, session: SeerrSession, appState: AppState) async -> String? {
        if let id = request.media.jellyfinMediaId, AppState.isValidItemId(id), let userId = appState.currentUserId,
           let name = try? await appState.apiClient.getItem(userId: userId, itemId: id).name, !name.isEmpty {
            return name
        }
        var found: String?
        await SeerrRequestTitles.load([request], session: session) { _, lookup in found = lookup?.title }
        return found
    }

    /// « Voir »: the Settings tab, on Réglages → Demandes — any deeper
    /// Settings page closed first.
    static func openRequests(appState: AppState, settingsNav: SettingsNavCoordinator) {
        settingsNav.selectedInterfaceSub = nil
        settingsNav.showsAppIconPage = false
        settingsNav.requestsUserId = nil
        settingsNav.requestsPage = nil
        settingsNav.selectedCategory = .requests
        appState.pendingDeepLinkTabId = MenuEntry.settingsID
    }
}

/// Holds the arrival message until the launch knows who is watching.
///
/// On an Apple TV opening on « Qui regarde ? », the session restored is the
/// PREVIOUS profile's: checking it would toast that profile's arrival over the
/// picker and spend its seen set before anyone chose. So the gate is held
/// from the start of the process; `AppNavigation` releases it right after
/// `restoreSession` when no picker shows (every iOS launch), else when the
/// picker closes. A check that came while held is not lost: `release` says
/// to run ONE then (a profile kept, or the restored one with no picker). A
/// profile switched to from the picker runs its own check through
/// `refreshCurrentUser` anyway — the seen set keeps the two from announcing
/// twice.
@MainActor
final class SeerrArrivalGate {
    private(set) var isHeld = true
    private var missedWhileHeld = false

    /// A check is due: `true` = run it now; `false` = held (and remembered).
    func admit() -> Bool {
        guard isHeld else { return true }
        missedWhileHeld = true
        return false
    }

    /// The launch decided: `true` = a check was held back, run one now.
    /// Only the first release counts.
    func release() -> Bool {
        guard isHeld else { return false }
        isHeld = false
        defer { missedWhileHeld = false }
        return missedWhileHeld
    }
}
