import Foundation
import Observation
import CinemaxKit

/// One line of « Mes demandes ». `GET /request` carries no title (spec,
/// § Spike findings 6): each row's title and poster come from its own
/// `/movie/{id}` or `/tv/{id}`, after the list is already on screen.
struct SeerrRequestRow: Identifiable, Equatable, Sendable {
    let request: SeerrRequest
    var title: String?
    var posterPath: String?
    /// The title lookup has not answered yet; once it has, a `nil` title
    /// reads « Titre indisponible ».
    var isTitlePending = true

    var id: Int { request.id }
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

    private(set) var rows: [SeerrRequestRow] = []
    private(set) var canLoadMore = false
    private(set) var phase: Phase = .idle
    private(set) var isLoadingMore = false

    /// What the server has sent so far — the next page's `skip`. Not
    /// `rows.count`: a request modified between two pages comes back twice
    /// (`sort=modified`) and is listed once (the `PaginatedLoader` RULE).
    @ObservationIgnored private var loadedCount = 0
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
        rows = []
        loadedCount = 0
        canLoadMore = false
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
        let fresh = append(page)
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
            page = try await Self.fetchPage(session: session, user: userId, skip: loadedCount)
        } catch {
            if pass == generation { isLoadingMore = false }
            return
        }
        guard pass == generation, session.isCurrent(snap) else { return }
        isLoadingMore = false
        let fresh = append(page)
        await loadTitles(of: fresh, session: session, snapshot: snap, pass: pass)
    }

    private static func fetchPage(session: SeerrSession, user: SeerrUserID, skip: Int) async throws -> SeerrRequestPage {
        try await session.perform { client, credential in
            try await client.requests(filter: .all, take: pageSize, skip: skip, requestedBy: user, credential)
        }
    }

    /// Adds the page's requests not listed yet; returns them.
    private func append(_ page: SeerrRequestPage) -> [SeerrRequest] {
        loadedCount += page.results.count
        var known = Set(rows.map(\.id))
        let fresh = page.results.filter { known.insert($0.id).inserted }
        rows.append(contentsOf: fresh.map { SeerrRequestRow(request: $0) })
        // An empty page ends paging whatever the total claims.
        canLoadMore = !page.results.isEmpty && loadedCount < page.total
        return fresh
    }

    // MARK: Titles

    private struct TitleLookup: Sendable {
        let title: String
        let posterPath: String?
    }

    /// One lookup per row, concurrently (at most a page's 20). A failure costs
    /// that row its title — never the list.
    private func loadTitles(
        of requests: [SeerrRequest], session: SeerrSession, snapshot snap: SeerrSession.Snapshot, pass: Int
    ) async {
        guard !requests.isEmpty else { return }
        await withTaskGroup(of: (Int, TitleLookup?).self) { group in
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
                guard pass == generation, session.isCurrent(snap) else { continue }
                // Cancelled (the page was left, or a newer load): not a failure.
                if found == nil, Task.isCancelled { continue }
                guard let index = rows.firstIndex(where: { $0.id == id }) else { continue }
                rows[index].title = found?.title
                rows[index].posterPath = found?.posterPath
                rows[index].isTitlePending = false
            }
        }
    }

    nonisolated private static func lookUp(
        kind: SeerrMediaKind, tmdbId: Int, client: SeerrClient, credential: SeerrCredential
    ) async throws -> TitleLookup? {
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
        return TitleLookup(title: title, posterPath: posterPath)
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
