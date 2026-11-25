import Foundation
import CinemaxKit

/// « À demander pour Noël » — a season's films the library does not have,
/// offered for request. Pure: who sees the row, what is asked, what is kept.
enum SeasonRequests {
    /// How many cards the Home row draws — and how many the FIRST pass reads
    /// pages for: a library that already holds most of the season's films
    /// keeps a handful per page of 20 (5 on the owner's server, 2026-11-21:
    /// « mets-en au moins 20 »). Its « Tout voir » pages on.
    static let rowLimit = 20
    /// Pages the first pass may read to fill the row (120 films before the
    /// filter): bounded, so a library holding nearly everything still answers.
    static let maxPagesFirstPass = 6
    /// Pages a later pass (the grid's load-more) asks in a row while each
    /// brings no NEW card (all horror, all owned, all seen): without it a page
    /// filtered to nothing would leave no card to appear, so the grid's
    /// load-more would never fire again.
    static let maxPagesPerPass = 3

    /// The row to load and draw, or `nil`: the resolved season has one, the
    /// season row's switch (`appearance.seasonalRow`) is on, and Seerr shows
    /// its browse surfaces to this account (`SeerrSession.isVisible`).
    static func row(season: SeasonalTheme?, rowSwitch: Bool, seerrVisible: Bool) -> SeasonRequestRow? {
        guard rowSwitch, seerrVisible else { return nil }
        return season?.requestRow
    }

    /// `today`: `SeerrMissing.today()` — Gregorian whatever the device's calendar.
    static func discovery(for row: SeasonRequestRow, page: Int, today: String) -> SeerrKeywordDiscovery {
        SeerrKeywordDiscovery(
            keywordId: row.keywordId, minimumVotes: row.minimumVotes, releasedOnOrBefore: today, page: page)
    }

    /// One page's cards, in Seerr's order: films only, none of the excluded
    /// genres, nothing the library already has (Seerr's own status — an
    /// available title goes; a requested one stays, with its badge).
    static func titles(_ candidates: [SeerrTitle], row: SeasonRequestRow) -> [SeerrMissingTitle] {
        let films = candidates.filter { $0.kind == .movie && row.excludedGenreIds.isDisjoint(with: $0.genreIds) }
        return SeerrMissing.titles(films, owned: [])
    }

    /// The card with the title, poster and synopsis of the app's language,
    /// once its `/movie/{id}` answered; an empty answer keeps what the list gave.
    static func localized(_ missing: SeerrMissingTitle, with lookup: SeerrRequestTitles.Lookup) -> SeerrMissingTitle {
        let old = missing.title
        let title = SeerrTitle(
            kind: old.kind, tmdbId: old.tmdbId,
            title: lookup.title.isEmpty ? old.title : lookup.title,
            year: old.year, overview: lookup.overview.flatMap { $0.isEmpty ? nil : $0 } ?? old.overview,
            posterPath: lookup.posterPath ?? old.posterPath,
            mediaInfo: old.mediaInfo, genreIds: old.genreIds)
        return SeerrMissingTitle(title: title, badge: missing.badge)
    }
}

/// The season's request row and its « Tout voir » grid: ONE list, read page
/// by page (Seerr's `page` / `totalPages`, 20 films each). Decorative: an
/// error, the deadline or an account that moved leave it EMPTY — the row is
/// then simply absent, with no retry and no message.
///
/// Its own tasks, not a view's `.task` (cancelled when a fiche covers Home).
@MainActor
@Observable
final class SeasonRequestsModel {
    /// The active account's Seerr, set by the screen. `nil` ⇒ nothing asked.
    @ObservationIgnored var seerr: SeerrSession?
    /// Whether the row may load — `SeerrSession.isVisible` with the screen's
    /// Pro gate and network, wired by the screen.
    @ObservationIgnored var allowsSeerr: @MainActor () -> Bool = { false }
    /// `SeerrSession.loadSection`'s deadline — injectable for the tests.
    @ObservationIgnored var deadline: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(6)) }
    @ObservationIgnored var today: @MainActor () -> String = { SeerrMissing.today() }

    /// Read through `titles(for:)`, which hides another account's.
    private(set) var titles: [SeerrMissingTitle] = []
    /// A further page is being read (the grid's footer).
    private(set) var isLoadingMore = false

    /// The page pass in flight, and the title lookups behind the pages
    /// already shown. Internal so a test can await them (`settle`).
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var titleTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var row: SeasonRequestRow?
    /// The Seerr account and generation `titles` was loaded for.
    @ObservationIgnored private var snapshot: SeerrSession.Snapshot?
    /// Bumped by every `load`: a pass compares it with its own.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextPage = 1
    @ObservationIgnored private var totalPages = 1

    /// The cards to draw for the account Seerr serves right now: another
    /// profile's never show.
    func titles(for current: SeerrSession.Snapshot?) -> [SeerrMissingTitle] {
        // Read FIRST, whatever the guard says: the view must observe it.
        let titles = self.titles
        guard let current, current == snapshot else { return [] }
        return titles
    }

    private var hasMore: Bool { nextPage <= totalPages }

    /// Starts over for `row` — `nil` (out of season, switch off, Seerr not
    /// visible) empties the list and asks NOTHING. The SAME row for the same
    /// Seerr account (a pull-to-refresh) keeps what is on screen until the
    /// new first page lands — and for good if that read fails.
    func load(_ row: SeasonRequestRow?) {
        pageTask?.cancel()
        titleTasks.forEach { $0.cancel() }
        titleTasks = []
        generation += 1
        let isRefresh = row != nil && row == self.row && snapshot != nil && seerr?.snapshot() == snapshot
        self.row = row
        nextPage = 1
        totalPages = 1
        if isLoadingMore { isLoadingMore = false }
        if !isRefresh {
            snapshot = nil
            if !titles.isEmpty { titles = [] }
        }
        guard row != nil else {
            pageTask = nil
            return
        }
        let pass = generation
        pageTask = Task { await readPages(pass: pass, isFirst: true) }
    }

    /// The grid: the card `id` appeared. Asks the next page once the last
    /// cards are reached, one pass at a time.
    func loadMoreIfNeeded(onAppearOf id: String) {
        guard hasMore, !isLoadingMore, row != nil, titles.suffix(6).contains(where: { $0.id == id }) else { return }
        isLoadingMore = true
        let pass = generation
        pageTask = Task { await readPages(pass: pass, isFirst: false) }
    }

    /// Everything in flight has landed (tests).
    func settle() async {
        await pageTask?.value
        for task in titleTasks { await task.value }
    }

    /// Reads pages until the row is full (`rowLimit` cards, first pass) or a
    /// page brought a new card (load-more), the list ends, or the pass's page
    /// budget is spent (`maxPagesFirstPass` / `maxPagesPerPass`). Each page's
    /// cards are published as they land. A failure ends the pass: the first one
    /// leaves the row absent, a later one leaves the grid as it is (the next
    /// card to appear asks again — at once `.hidden` while Seerr is down).
    private func readPages(pass: Int, isFirst: Bool) async {
        guard !Task.isCancelled, generation == pass else { return }
        guard let row, allowsSeerr(), let seerr, let current = isFirst ? seerr.snapshot() : snapshot,
              seerr.isCurrent(current) else {
            isLoadingMore = false
            return
        }
        if isFirst { snapshot = current }
        // A refresh: the cards on screen stay until the first answer.
        var replaces = isFirst && !titles.isEmpty
        var asked = 0
        let budget = isFirst ? SeasonRequests.maxPagesFirstPass : SeasonRequests.maxPagesPerPass
        // The first pass fills the row; a load-more stops at its first new card.
        let wanted = isFirst ? SeasonRequests.rowLimit : titles.count + 1
        while asked < budget, hasMore {
            let page = nextPage
            let discovery = SeasonRequests.discovery(for: row, page: page, today: today())
            let answer = await seerr.loadSection(deadline: deadline) { client, credential in
                [try await client.discoverMovies(discovery, credential)]
            }
            guard !Task.isCancelled, generation == pass else { return }
            guard case .loaded(let pages)? = answer, let result = pages.first else { break }
            asked += 1
            nextPage = page + 1
            // An empty page is the end, whatever `totalPages` promised.
            totalPages = result.results.isEmpty ? page : result.totalPages
            if replaces {
                replaces = false
                titles = []
            }
            var known = Set(titles.map(\.id))
            let fresh = SeasonRequests.titles(result.results, row: row)
                .filter { known.insert($0.id).inserted }
                .map { card in
                    // A title already looked up this session is drawn localised at once.
                    seerr.rememberedTitle(kind: card.title.kind, tmdbId: card.title.tmdbId)
                        .map { SeasonRequests.localized(card, with: $0) } ?? card
                }
            guard !fresh.isEmpty else { continue }
            titles.append(contentsOf: fresh)
            localize(fresh, seerr: seerr, pass: pass)
            if titles.count >= wanted { break }
        }
        isLoadingMore = false
    }

    /// The list comes in the Seerr user's own language (`discoverMovies`
    /// cannot be localised): each card's title and poster in the APP's
    /// language come from its `/movie/{id}`, six at a time, remembered by the
    /// session — after the cards are on screen, never before.
    private func localize(_ cards: [SeerrMissingTitle], seerr: SeerrSession, pass: Int) {
        let targets = cards.map {
            SeerrRequestTitles.Target(rowId: $0.title.tmdbId, kind: $0.title.kind, tmdbId: $0.title.tmdbId)
        }
        titleTasks.append(Task { [weak self] in
            await SeerrRequestTitles.load(targets, session: seerr) { tmdbId, lookup in
                guard let self, let lookup, self.generation == pass,
                      let index = self.titles.firstIndex(where: { $0.title.tmdbId == tmdbId }) else { return }
                let localized = SeasonRequests.localized(self.titles[index], with: lookup)
                if localized != self.titles[index] { self.titles[index] = localized }
            }
        })
    }
}
