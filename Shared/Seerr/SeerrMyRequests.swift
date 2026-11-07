import Foundation
import Observation
import CinemaxKit

/// One line of « Mes demandes » or « À valider ». Its title and poster come
/// from `SeerrRequestTitles`, after the list is already on screen.
struct SeerrRequestRow: Identifiable, Equatable, Sendable {
    let request: SeerrRequest
    var title: String?
    var posterPath: String?
    /// The title lookup has not answered yet; once it has, a `nil` title
    /// reads « Titre indisponible ».
    var isTitlePending = true

    var id: Int { request.id }
}

/// One `GET /request` listing as the server pages it — shared by « Mes
/// demandes » and « À valider ».
struct SeerrRequestPages {
    private(set) var rows: [SeerrRequestRow] = []
    /// What the server has sent so far — the next page's `skip`. Not
    /// `rows.count`: a request modified between two pages comes back twice
    /// (`sort=modified`) and is listed once (the `PaginatedLoader` RULE).
    private(set) var loadedCount = 0
    /// The last page's `pageInfo.results`, less the requests that left the
    /// listing since (`remove`).
    private(set) var total = 0
    /// An empty page ends paging whatever the total claims.
    private var reachedEnd = false

    var canLoadMore: Bool { !reachedEnd && loadedCount < total }

    /// Adds the page's requests not listed yet; returns them.
    mutating func append(_ page: SeerrRequestPage) -> [SeerrRequest] {
        loadedCount += page.results.count
        total = page.total
        if page.results.isEmpty { reachedEnd = true }
        var known = Set(rows.map(\.id))
        let fresh = page.results.filter { known.insert($0.id).inserted }
        rows.append(contentsOf: fresh.map { SeerrRequestRow(request: $0) })
        return fresh
    }

    /// The row's title lookup answered — `nil` = « Titre indisponible ».
    mutating func setTitle(_ found: SeerrRequestTitles.Lookup?, for id: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].title = found?.title
        rows[index].posterPath = found?.posterPath
        rows[index].isTitlePending = false
    }

    /// A request that LEFT the server's listing (approved, declined): the
    /// listing is one shorter, so the next page starts one earlier — keeping
    /// `skip` would pass over a request nobody has seen.
    mutating func remove(_ id: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows.remove(at: index)
        loadedCount = max(0, loadedCount - 1)
        total = max(0, total - 1)
    }
}

/// `GET /request` carries no title (spec, § Spike findings 6): each row's
/// title and poster come from its own `/movie/{id}` or `/tv/{id}`, after the
/// list is already on screen.
@MainActor
enum SeerrRequestTitles {
    struct Lookup: Sendable, Equatable {
        let title: String
        let posterPath: String?
    }

    /// One lookup per request, concurrently (at most a page's 20). `apply`
    /// gets each answer on the main actor as it lands — `nil` = unavailable:
    /// a failure costs that row its title, never the list. A lookup cancelled
    /// (the page was left, a newer load) is not reported: it is not a failure.
    static func load(_ requests: [SeerrRequest], session: SeerrSession, apply: (Int, Lookup?) -> Void) async {
        guard !requests.isEmpty else { return }
        await withTaskGroup(of: (Int, Lookup?).self) { group in
            for request in requests {
                let id = request.id
                let kind = request.kind
                let tmdbId = request.media.tmdbId
                group.addTask {
                    let found = try? await session.perform { client, credential in
                        try await Self.lookUp(kind: kind, tmdbId: tmdbId, client: client, credential: credential)
                    }
                    return (id, found)
                }
            }
            for await (id, found) in group {
                if found == nil, Task.isCancelled { continue }
                apply(id, found)
            }
        }
    }

    nonisolated private static func lookUp(
        kind: SeerrMediaKind, tmdbId: Int, client: SeerrClient, credential: SeerrCredential
    ) async throws -> Lookup? {
        let title: String
        let posterPath: String?
        switch kind {
        case .movie:
            let movie = try await client.movie(tmdbId: tmdbId, credential)
            title = movie.title
            posterPath = movie.posterPath
        case .tv:
            let series = try await client.tv(tmdbId: tmdbId, credential)
            title = series.name
            posterPath = series.posterPath
        }
        guard !title.isEmpty else { return nil }
        return Lookup(title: title, posterPath: posterPath)
    }
}

/// Réglages → Demandes → « Mes demandes »: every request of the signed-in
/// Seerr user, most recently changed first, 20 at a time.
///
/// Always `requestedBy=<my Seerr id>` — without it a manager's list would
/// hold the whole household's requests. Every answer is checked against the
/// session snapshot it was asked for, and against `generation` (a newer
/// first page owns the rows): a stale one is dropped, never applied.
@MainActor @Observable
final class SeerrMyRequestsModel {
    enum Phase: Equatable { case idle, loading, loaded, failed }

    nonisolated static let pageSize = 20

    private(set) var phase: Phase = .idle
    private(set) var isLoadingMore = false
    private var pages = SeerrRequestPages()

    var rows: [SeerrRequestRow] { pages.rows }
    var canLoadMore: Bool { pages.canLoadMore }

    @ObservationIgnored private var snapshot: SeerrSession.Snapshot?
    @ObservationIgnored private var userId: SeerrUserID?
    @ObservationIgnored private var generation = 0

    // MARK: Loading

    /// The first page, replacing whatever was listed. The rows are published
    /// as soon as the list answers; their titles follow (awaited here, so a
    /// caller — or a test — knows when everything has landed).
    func loadFirstPage(session: SeerrSession) async {
        guard case .connected(let user) = session.connection, let snap = session.snapshot() else { return }
        generation &+= 1
        let pass = generation
        snapshot = snap
        userId = user.id
        pages = SeerrRequestPages()
        isLoadingMore = false
        phase = .loading

        let page: SeerrRequestPage
        do {
            page = try await Self.fetchPage(session: session, user: user.id, skip: 0)
        } catch {
            // A newer load, or a cancelled task, owns the state.
            guard pass == generation, !Task.isCancelled, session.isCurrent(snap) else { return }
            phase = .failed
            return
        }
        guard pass == generation, session.isCurrent(snap) else { return }
        let fresh = pages.append(page)
        phase = .loaded
        await loadTitles(of: fresh, session: session, snapshot: snap, pass: pass)
    }

    /// « Afficher plus »: the next 20, while the total is not reached. A
    /// failure leaves the button in place for another try.
    func loadNextPage(session: SeerrSession) async {
        guard canLoadMore, !isLoadingMore, phase == .loaded, let snap = snapshot, let userId,
              session.isCurrent(snap) else { return }
        let pass = generation
        isLoadingMore = true
        let page: SeerrRequestPage
        do {
            page = try await Self.fetchPage(session: session, user: userId, skip: pages.loadedCount)
        } catch {
            if pass == generation { isLoadingMore = false }
            return
        }
        guard pass == generation, session.isCurrent(snap) else { return }
        isLoadingMore = false
        let fresh = pages.append(page)
        await loadTitles(of: fresh, session: session, snapshot: snap, pass: pass)
    }

    private static func fetchPage(session: SeerrSession, user: SeerrUserID, skip: Int) async throws -> SeerrRequestPage {
        try await session.perform { client, credential in
            try await client.requests(filter: .all, take: pageSize, skip: skip, requestedBy: user, credential)
        }
    }

    private func loadTitles(
        of requests: [SeerrRequest], session: SeerrSession, snapshot snap: SeerrSession.Snapshot, pass: Int
    ) async {
        await SeerrRequestTitles.load(requests, session: session) { id, found in
            guard pass == generation, session.isCurrent(snap) else { return }
            pages.setTitle(found, for: id)
        }
    }

    // MARK: Status line (pure)

    /// The status line's key. Arrived first (the media is in the library,
    /// whoever's request brought it, or Seerr closed this request as
    /// fulfilled), then refused, then waiting for an admin; anything else is
    /// approved and on its way — including a request whose hand-off to the
    /// downloader FAILED: it was approved, the admin retries it in Seerr, and
    /// « Refusée » would be false.
    static func statusKey(_ request: SeerrRequest) -> String {
        if request.media.status == .available || request.status == .completed {
            return "seerr.myRequests.status.available"
        }
        switch request.status {
        case .declined: return "seerr.myRequests.status.declined"
        case .pending: return "seerr.myRequests.status.pending"
        case .approved, .failed, .completed: return "seerr.myRequests.status.approved"
        }
    }

    /// « 4, 5 » — a series' requested seasons, ascending, each once; `nil`
    /// for a film or a request naming none.
    static func seasonList(_ request: SeerrRequest) -> String? {
        guard request.kind == .tv else { return nil }
        let seasons = Set(request.seasons).sorted()
        guard !seasons.isEmpty else { return nil }
        return seasons.map(String.init).joined(separator: ", ")
    }

    /// « saisons 4, 5 » / « saison 4 », written after the title.
    static func seasonsSuffix(_ request: SeerrRequest, loc: LocalizationManager) -> String? {
        guard let list = seasonList(request) else { return nil }
        let count = Set(request.seasons).count
        return loc.localized(loc.pluralKey("seerr.myRequests.seasons", count), list)
    }

    // MARK: « Regarder » (pure + its one effect)

    /// The Jellyfin item an arrived request opens: only once the media is
    /// available AND Seerr knows its Jellyfin id.
    static func watchTarget(_ request: SeerrRequest) -> String? {
        guard request.media.status == .available, let id = request.media.jellyfinMediaId, !id.isEmpty else {
            return nil
        }
        return id
    }

    /// Opens the fiche through the app's one deep-link route
    /// (`MainTabView`: a modal over the tabs, whatever is open — Settings
    /// stays underneath). `false` = nothing to open.
    @discardableResult
    static func watch(_ request: SeerrRequest, appState: AppState) -> Bool {
        guard let id = watchTarget(request) else { return false }
        appState.pendingDeepLinkItemId = id
        return true
    }
}

/// Réglages → Demandes → « À valider (N) »: the household's PENDING requests,
/// for a Seerr user who may manage them, most recently changed first, 20 at
/// a time; « Approuver » / « Refuser » in one tap each, as on Seerr's own page.
///
/// Who sees it is SEERR's permission (`canManageRequests`, a Seerr admin
/// included), never the Jellyfin admin flag (spec call 11). Never
/// `requestedBy` — the queue is everyone's — and the count is this listing's
/// own `pageInfo.results`: `GET /request/count` counts every request of the
/// server, whatever its status or its asker (spec, § Spike findings 6).
@MainActor @Observable
final class SeerrPendingModel {
    typealias Phase = SeerrMyRequestsModel.Phase
    enum Action: Equatable, Sendable { case approve, decline }

    private(set) var phase: Phase = .idle
    private(set) var isLoadingMore = false
    /// The request each approval or refusal on its way is for: its row's
    /// buttons wait, a second press does nothing.
    private(set) var inFlight: [Int: Action] = [:]
    private var pages = SeerrRequestPages()

    var rows: [SeerrRequestRow] { pages.rows }
    var canLoadMore: Bool { pages.canLoadMore }
    /// How many requests wait, household-wide: the listing's total, less the
    /// ones settled here since.
    var count: Int { pages.total }

    @ObservationIgnored private var snapshot: SeerrSession.Snapshot?
    @ObservationIgnored private var generation = 0

    /// The section shows for a connected Seerr user who may manage requests.
    static func isShown(for connection: SeerrSession.Connection) -> Bool {
        guard case .connected(let user) = connection else { return false }
        return user.permissions.canManageRequests
    }

    // MARK: Loading

    /// The first page, replacing whatever was listed; nothing at all is asked
    /// for a user who may not manage requests.
    func load(session: SeerrSession) async {
        guard Self.isShown(for: session.connection), let snap = session.snapshot() else { return }
        generation &+= 1
        let pass = generation
        snapshot = snap
        pages = SeerrRequestPages()
        inFlight = [:]
        isLoadingMore = false
        phase = .loading

        let page: SeerrRequestPage
        do {
            page = try await Self.fetchPage(session: session, skip: 0)
        } catch {
            guard pass == generation, !Task.isCancelled, session.isCurrent(snap) else { return }
            phase = .failed
            return
        }
        guard pass == generation, session.isCurrent(snap) else { return }
        let fresh = pages.append(page)
        phase = .loaded
        await loadTitles(of: fresh, session: session, snapshot: snap, pass: pass)
    }

    /// « Afficher plus », as in Mes demandes.
    func loadNextPage(session: SeerrSession) async {
        guard canLoadMore, !isLoadingMore, phase == .loaded, let snap = snapshot, session.isCurrent(snap) else { return }
        let pass = generation
        isLoadingMore = true
        let page: SeerrRequestPage
        do {
            page = try await Self.fetchPage(session: session, skip: pages.loadedCount)
        } catch {
            if pass == generation { isLoadingMore = false }
            return
        }
        guard pass == generation, session.isCurrent(snap) else { return }
        isLoadingMore = false
        let fresh = pages.append(page)
        await loadTitles(of: fresh, session: session, snapshot: snap, pass: pass)
    }

    private static func fetchPage(session: SeerrSession, skip: Int) async throws -> SeerrRequestPage {
        try await session.perform { client, credential in
            try await client.requests(
                filter: .pending, take: SeerrMyRequestsModel.pageSize, skip: skip, requestedBy: nil, credential)
        }
    }

    private func loadTitles(
        of requests: [SeerrRequest], session: SeerrSession, snapshot snap: SeerrSession.Snapshot, pass: Int
    ) async {
        await SeerrRequestTitles.load(requests, session: session) { id, found in
            guard pass == generation, session.isCurrent(snap) else { return }
            pages.setTitle(found, for: id)
        }
    }

    // MARK: Approve / refuse

    func approve(_ id: Int, session: SeerrSession, toasts: ToastCenter, loc: LocalizationManager) async {
        await settle(id, .approve, session: session, toasts: toasts, loc: loc)
    }

    func decline(_ id: Int, session: SeerrSession, toasts: ToastCenter, loc: LocalizationManager) async {
        await settle(id, .decline, session: session, toasts: toasts, loc: loc)
    }

    private enum Outcome { case done, alreadyHandled, failed, cancelled }

    /// Done ⇒ the row leaves (it is no longer pending), the count drops, a
    /// toast says so. 409 ⇒ someone settled it first (another manager, Seerr's
    /// own page): the row leaves the same way, with an info toast. Any other
    /// failure keeps the row for another try. An account change meanwhile
    /// (`perform` ⇒ `CancellationError`) writes and shows nothing.
    private func settle(
        _ id: Int, _ action: Action, session: SeerrSession, toasts: ToastCenter, loc: LocalizationManager
    ) async {
        guard inFlight[id] == nil, phase == .loaded, rows.contains(where: { $0.id == id }),
              let snap = snapshot, session.isCurrent(snap) else { return }
        let pass = generation
        inFlight[id] = action
        let outcome: Outcome
        do {
            try await session.perform { client, credential in
                switch action {
                case .approve: try await client.approve(requestId: id, credential)
                case .decline: try await client.decline(requestId: id, credential)
                }
            }
            outcome = .done
        } catch SeerrError.duplicate {
            // 409: the request is no longer pending.
            outcome = .alreadyHandled
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failed
        }
        guard session.isCurrent(snap) else { return }
        // A newer listing owns the rows; the toast still answers the press.
        let ownsRows = pass == generation
        if ownsRows { inFlight[id] = nil }
        switch outcome {
        case .done:
            if ownsRows { pages.remove(id) }
            toasts.success(loc.localized(action == .approve ? "seerr.pending.approved" : "seerr.pending.declined"))
        case .alreadyHandled:
            if ownsRows { pages.remove(id) }
            toasts.info(loc.localized("seerr.pending.alreadyHandled"))
        case .failed:
            toasts.error(loc.localized(action == .approve ? "seerr.pending.approveFailed" : "seerr.pending.declineFailed"))
        case .cancelled:
            break
        }
    }

    // MARK: Who and when (pure)

    /// « Demandé par Léa · il y a 2 h », in the app's language (`loc.locale`,
    /// root RULE); « Demandé il y a 2 h » when Seerr names nobody.
    static func requestedLine(_ request: SeerrRequest, loc: LocalizationManager) -> String {
        let when = request.createdAt.formatted(Self.relativeStyle(loc: loc))
        guard let name = request.requestedBy.displayName, !name.isEmpty else {
            return loc.localized("seerr.pending.requestedAt", when)
        }
        return loc.localized("seerr.pending.requestedBy", name, when)
    }

    static func relativeStyle(loc: LocalizationManager) -> Date.RelativeFormatStyle {
        Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .abbreviated, locale: loc.locale)
    }
}
