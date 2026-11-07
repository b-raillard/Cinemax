import SwiftUI
import CinemaxKit

/// What a request is about to ask for. For `.series`, `seasons` is the
/// requestable (missing) season numbers in ascending order; `preselected` is
/// what the gesture that raised the draft already points at (empty ⇒ all).
enum SeerrRequestDraft: Identifiable, Equatable {
    case movie(SeerrTitle)
    case series(SeerrTitle, seasons: [Int], preselected: Set<Int>)
    case films([SeerrTitle])

    var id: String {
        switch self {
        case .movie(let title): "movie-\(title.tmdbId)"
        case .series(let title, _, _): "tv-\(title.tmdbId)"
        case .films(let titles): "films-" + titles.map { String($0.tmdbId) }.joined(separator: ",")
        }
    }

    /// The numbers the sheet ticks by default: every season / film.
    /// Without partial requests Seerr takes the whole series: all seasons.
    func defaultSelection(partial: Bool) -> Set<Int> {
        switch self {
        case .movie: return []
        case .series(_, let seasons, let preselected):
            return preselected.isEmpty || !partial ? Set(seasons) : preselected.intersection(seasons)
        case .films(let titles): return Set(titles.map(\.tmdbId))
        }
    }
}

/// Root-hosted raiser of the request flow, and the owner of the badge
/// overrides: once a request is sent, the card that offered it reads the new
/// state from here without reloading its section.
@MainActor
@Observable
final class SeerrRequestPresenter {
    var draft: SeerrRequestDraft?
    /// Keyed by `SeerrMissingTitle.id` (`"tv-90228"`) or, for a season,
    /// `"tv-90228-s4"`.
    private(set) var overrides: [String: SeerrBadge] = [:]
    /// Series whose seasons are being looked up (`SeerrMissingTitle.id`):
    /// repeated taps do not fire repeated `/tv/{id}` calls.
    @ObservationIgnored private var lookingUp: Set<String> = []
    /// Bounds a series card's `/tv/{id}` lookup like a section load (6 s):
    /// past it, the same quiet toast as a failure. Injectable for tests.
    @ObservationIgnored private let lookupDeadline: @Sendable () async throws -> Void

    init(lookupDeadline: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(6)) }) {
        self.lookupDeadline = lookupDeadline
    }

    func present(_ draft: SeerrRequestDraft) { self.draft = draft }

    /// The draft as `host` should present it. While the deep-link modal is up
    /// it is the one presenter (the root cannot present over it); otherwise
    /// the root is.
    func draft(for host: PresentationHost) -> SeerrRequestDraft? {
        host == .modal || modalHosts == 0 ? draft : nil
    }

    /// Deep-link modals on screen (a counter: a new one may appear before
    /// the old one's disappear).
    private(set) var modalHosts = 0
    func modalHostAppeared() { modalHosts += 1 }
    /// The modal leaves with its request: the root never raises it afterwards.
    func modalHostDisappeared() {
        modalHosts = max(0, modalHosts - 1)
        draft = nil
    }

    /// A missing title's card was tapped (search, fiches, saga, actor page).
    /// Already asked for — the EFFECTIVE badge (`badge(for:default:)`) is
    /// pending or in preparation — ⇒ an info toast, nothing opens; declined or
    /// never asked ⇒ the request. A film opens it at once; a series first asks
    /// Seerr for its seasons — the library has none of them, so every season
    /// Seerr lacks is offered, all ticked — one lookup per series at a time,
    /// bounded by `lookupDeadline` (`loadSection`). A failed or expired lookup
    /// says so quietly, never naming Seerr; an account change on the way says
    /// nothing.
    func request(_ missing: SeerrMissingTitle, session: SeerrSession, loc: LocalizationManager, toasts: ToastCenter) async {
        guard !refusesAlreadyRequested(badge(for: missing.id, default: missing.badge), loc: loc, toasts: toasts) else {
            return
        }
        let title = missing.title
        guard title.kind == .tv else {
            present(.movie(title))
            return
        }
        guard lookingUp.insert(missing.id).inserted else { return }
        defer { lookingUp.remove(missing.id) }
        let tmdbId = title.tmdbId
        let details: SeerrTVDetails
        switch await session.loadSection(deadline: lookupDeadline, { client, credential in
            [try await client.tv(tmdbId: tmdbId, credential)]
        }) {
        case nil:
            return      // the account changed, or the tap's task was cancelled
        case .loaded(let found) where found.count == 1:
            details = found[0]
        case .hidden, .loading, .loaded:
            toasts.error(loc.localized("seerr.request.seasonsUnavailable"))
            return
        }
        let seasons = SeerrMissing.seasons(
            details, ownedSeasonNumbers: [],
            includeSpecials: session.publicSettings?.enableSpecialEpisodes ?? false
        ).map(\.seasonNumber).sorted()
        guard !seasons.isEmpty else {
            toasts.error(loc.localized("seerr.request.noSeasons"))
            return
        }
        present(.series(title, seasons: seasons, preselected: Set(seasons)))
    }

    /// A missing SEASON's card or pill was selected (series fiche). Same rule
    /// as a title, on the season's effective badge: already asked for ⇒ the
    /// info toast, nothing opens. Otherwise the season picker over every
    /// season still requestable, ascending, with this one ticked — the fiche
    /// already knows the seasons, so no lookup.
    func request(
        season: SeerrMissingSeason, among missing: [SeerrMissingSeason], of series: SeerrTitle,
        loc: LocalizationManager, toasts: ToastCenter
    ) {
        guard !refusesAlreadyRequested(badge(for: season.id, default: season.badge), loc: loc, toasts: toasts) else {
            return
        }
        let seasons = requestableSeasons(missing)
        guard seasons.contains(season.seasonNumber) else { return }
        present(.series(series, seasons: seasons, preselected: [season.seasonNumber]))
    }

    /// The row's « Demander les N »: every requestable season, all ticked.
    func requestAll(
        _ missing: [SeerrMissingSeason], of series: SeerrTitle, loc: LocalizationManager, toasts: ToastCenter
    ) {
        let seasons = requestableSeasons(missing)
        guard !seasons.isEmpty else {
            toasts.info(loc.localized("seerr.request.duplicate"))
            return
        }
        present(.series(series, seasons: seasons, preselected: Set(seasons)))
    }

    /// The season numbers that may still be asked for — never asked, or
    /// declined — by their EFFECTIVE badge, ascending.
    func requestableSeasons(_ missing: [SeerrMissingSeason]) -> [Int] {
        missing.filter { season in
            switch badge(for: season.id, default: season.badge) {
            case .request, .declined: true
            case .pending, .processing: false
            }
        }
        .map(\.seasonNumber).sorted()
    }

    /// A saga's « Demander les N » (BoxSet section, movie rows): every film
    /// still requestable, all ticked (`.films`); none left ⇒ « Déjà demandé ».
    func requestAll(films missing: [SeerrMissingTitle], loc: LocalizationManager, toasts: ToastCenter) {
        let films = requestableFilms(missing)
        guard !films.isEmpty else {
            toasts.info(loc.localized("seerr.request.duplicate"))
            return
        }
        present(.films(films.map(\.title)))
    }

    /// The films that may still be asked for — never asked, or declined — by
    /// their EFFECTIVE badge, in the section's order.
    func requestableFilms(_ missing: [SeerrMissingTitle]) -> [SeerrMissingTitle] {
        missing.filter { film in
            switch badge(for: film.id, default: film.badge) {
            case .request, .declined: true
            case .pending, .processing: false
            }
        }
    }

    /// Pending / in preparation ⇒ « Déjà demandé » and `true`: nothing opens.
    private func refusesAlreadyRequested(_ badge: SeerrBadge, loc: LocalizationManager, toasts: ToastCenter) -> Bool {
        switch badge {
        case .pending:
            toasts.info(loc.localized("seerr.request.duplicate"), message: loc.localized("seerr.request.already.pending"))
            return true
        case .processing:
            toasts.info(loc.localized("seerr.request.duplicate"), message: loc.localized("seerr.request.already.processing"))
            return true
        case .request, .declined:
            return false
        }
    }

    /// « Saison 4 », or « Épisodes spéciaux » for season 0.
    static func seasonName(_ number: Int, loc: LocalizationManager) -> String {
        number == 0 ? loc.localized("seerr.season.specials") : loc.localized("seerr.request.seasonRow", number)
    }

    /// The account changed: another profile's requests are not this one's.
    func reset() {
        overrides = [:]
        draft = nil
    }

    func badge(for id: String, default fallback: SeerrBadge) -> SeerrBadge {
        overrides[id] ?? fallback
    }

    /// « Le téléchargement démarre tout de suite » or « l'admin doit valider ».
    static func nextStepKey(permissions: SeerrPermissions, kind: SeerrMediaKind) -> String {
        permissions.autoApproves(kind) ? "seerr.request.next.auto" : "seerr.request.next.approval"
    }

    /// What `submit` will really send for `selection`: with partial requests
    /// off, every requestable season whatever was picked. Labels read this.
    static func effectiveSelection(_ draft: SeerrRequestDraft, _ selection: Set<Int>, partial: Bool) -> Set<Int> {
        if case .series(_, let seasons, _) = draft, !partial { return Set(seasons) }
        return selection
    }

    // MARK: Labels

    /// « Demander la saison 4 », « Demander les saisons 4 à 6 » (consecutive),
    /// « Demander 2 saisons » otherwise. `seasons` ascending.
    /// Season 0 is « les épisodes spéciaux », never « la saison 0 »: alone it
    /// has its own label, and a run starting at it takes the count.
    static func seasonsActionTitle(_ seasons: [Int], loc: LocalizationManager) -> String {
        if seasons.count == 1, let only = seasons.first {
            return only == 0
                ? loc.localized("seerr.request.action.specials")
                : loc.localized("seerr.request.action.season", only)
        }
        if let first = seasons.first, let last = seasons.last, seasons.count > 1, first != 0,
           last - first == seasons.count - 1 {
            return loc.localized("seerr.request.action.seasonRange", first, last)
        }
        return loc.counted("seerr.request.action.seasons", seasons.count)
    }

    /// The button of the iOS sheet / the confirming button on tvOS.
    static func actionTitle(for draft: SeerrRequestDraft, selection: Set<Int>, loc: LocalizationManager) -> String {
        switch draft {
        case .movie:
            return loc.localized("seerr.request.action.movie")
        case .series:
            #if os(tvOS)
            return seasonsActionTitle(selection.sorted(), loc: loc)
            #else
            guard case .series(_, let seasons, _) = draft else { return "" }
            if selection.count == seasons.count { return loc.localized("seerr.request.action.series") }
            return loc.counted("seerr.request.action.seasons", selection.count)
            #endif
        case .films:
            return loc.counted("seerr.request.action.films", selection.count)
        }
    }

    // MARK: Sending

    private struct Job {
        let request: SeerrNewRequest
        let kind: SeerrMediaKind
        let tmdbId: Int
        let seasons: [Int]
        let title: String
    }

    private enum Outcome { case sent, duplicate, noSeasons, forbidden, failed }

    private struct Result {
        let job: Job
        let outcome: Outcome
        /// `.sent`: what the created request's status says (`badge(afterCreating:)`).
        var sentBadge: SeerrBadge?
        var error: Error?
    }

    /// The badge a card takes once its request is created — from the status
    /// Seerr ANSWERED, never guessed from the permissions (an admin's
    /// auto-approval rule, a quota, a per-user override all decide on the
    /// server): pending ⇒ « En attente », declined ⇒ declined, anything else
    /// (approved, and `failed` / `completed` — approved, then handed off) ⇒
    /// in preparation. The permissions only phrase the sheet's « what
    /// happens next » line (`nextStepKey`).
    static func badge(afterCreating status: SeerrRequestStatus) -> SeerrBadge {
        switch status {
        case .pending: .pending
        case .declined: .declined
        case .approved, .failed, .completed: .processing
        }
    }

    /// Sends the draft. `.films` sends one request per selected film, in
    /// order; the outcome is reported in ONE toast. A draft left empty by the
    /// selection sends nothing.
    func submit(
        _ draft: SeerrRequestDraft, selection: Set<Int>,
        session: SeerrSession, loc: LocalizationManager, toasts: ToastCenter
    ) async {
        let jobs = Self.jobs(for: draft, selection: selection, partial: session.publicSettings?.partialRequestsEnabled ?? true)
        guard !jobs.isEmpty else { return }

        // Films 2…n must never go out under another account.
        let account = session.activeAccountKeyProvider()
        var outcomes: [Result] = []
        for job in jobs {
            guard session.activeAccountKeyProvider() == account else { return }
            let request = job.request
            do {
                let created = try await session.perform { client, credential in
                    try await client.createRequest(request, credential)
                }
                outcomes.append(Result(job: job, outcome: .sent, sentBadge: Self.badge(afterCreating: created.status)))
            } catch is CancellationError {
                return   // the account changed: nobody's to show
            } catch SeerrError.duplicate {
                outcomes.append(Result(job: job, outcome: .duplicate))
            } catch SeerrError.noSeasonsAvailable {
                outcomes.append(Result(job: job, outcome: .noSeasons))
            } catch SeerrError.forbidden {
                outcomes.append(Result(job: job, outcome: .forbidden))
            } catch {
                outcomes.append(Result(job: job, outcome: .failed, error: error))
            }
        }

        for result in outcomes {
            switch result.outcome {
            case .sent:
                mark(result.job, as: result.sentBadge ?? .pending)
            case .duplicate:
                mark(result.job, as: .pending)
            default:
                break
            }
        }
        report(outcomes, loc: loc, toasts: toasts)
        if self.draft?.id == draft.id { self.draft = nil }
    }

    private static func jobs(for draft: SeerrRequestDraft, selection: Set<Int>, partial: Bool) -> [Job] {
        switch draft {
        case .movie(let title):
            return [Job(request: .movie(tmdbId: title.tmdbId), kind: .movie, tmdbId: title.tmdbId, seasons: [], title: title.title)]
        case .series(let title, let seasons, _):
            let sent = partial ? seasons.filter(selection.contains) : seasons
            guard !sent.isEmpty else { return [] }
            return [Job(request: .tv(tmdbId: title.tmdbId, seasons: sent), kind: .tv, tmdbId: title.tmdbId, seasons: sent, title: title.title)]
        case .films(let titles):
            return titles.filter { selection.contains($0.tmdbId) }.map {
                Job(request: .movie(tmdbId: $0.tmdbId), kind: .movie, tmdbId: $0.tmdbId, seasons: [], title: $0.title)
            }
        }
    }

    private func mark(_ job: Job, as badge: SeerrBadge) {
        overrides["\(job.kind.rawValue)-\(job.tmdbId)"] = badge
        for season in job.seasons { overrides["tv-\(job.tmdbId)-s\(season)"] = badge }
    }

    private func report(_ outcomes: [Result], loc: LocalizationManager, toasts: ToastCenter) {
        let sent = outcomes.filter { $0.outcome == .sent }
        let duplicates = outcomes.filter { $0.outcome == .duplicate }
        let failures = outcomes.filter { $0.outcome != .sent && $0.outcome != .duplicate }

        if !sent.isEmpty {
            let title = outcomes.count == 1
                ? loc.localized("seerr.request.sent", sent[0].job.title)
                : loc.counted("seerr.request.sentFilms", sent.count)
            toasts.success(title, message: failures.isEmpty ? nil : loc.counted("seerr.request.refusedCount", failures.count))
        } else if let first = failures.first {
            switch first.outcome {
            case .forbidden:
                toasts.error(loc.localized("seerr.request.forbidden.title"), message: loc.localized("seerr.request.forbidden.fix"))
            case .noSeasons:
                toasts.error(loc.localized("seerr.request.noSeasons"))
            default:
                toasts.error(
                    loc.localized("seerr.request.failed"),
                    message: first.error.map { loc.userFacingMessage(for: $0) })
            }
        } else if !duplicates.isEmpty {
            toasts.info(loc.localized("seerr.request.duplicate"))
        }
    }
}

// MARK: - Presentation

/// Hosts the flow once, at the root (same reasons as `AddToPlaylistPresentation`:
/// the gesture comes from lazy grids and context menus). iOS: a sheet with the
/// poster and the ticks. tvOS: a confirmation dialog, nothing to type or tick.
struct SeerrRequestPresentation: ViewModifier {
    let presenter: SeerrRequestPresenter
    let session: SeerrSession
    let appState: AppState
    let themeManager: ThemeManager
    let loc: LocalizationManager
    let toasts: ToastCenter
    /// `.modal`: hosted inside the deep-link fiche (`MainTabView`), which
    /// then presents instead of the root — see `PresentationHost`.
    var host: PresentationHost = .root

    func body(content: Content) -> some View {
        presented(content)
            .onAppear { if host == .modal { presenter.modalHostAppeared() } }
            .onDisappear { if host == .modal { presenter.modalHostDisappeared() } }
    }

    @ViewBuilder
    private func presented(_ content: Content) -> some View {
        #if os(tvOS)
        content.confirmationDialog(
            dialogTitle,
            isPresented: Binding(get: { presenter.draft(for: host) != nil }, set: { if !$0 { presenter.draft = nil } }),
            titleVisibility: .visible,
            presenting: presenter.draft(for: host)
        ) { draft in
            let partial = session.publicSettings?.partialRequestsEnabled ?? true
            let selection = SeerrRequestPresenter.effectiveSelection(
                draft, draft.defaultSelection(partial: partial), partial: partial)
            Button(SeerrRequestPresenter.actionTitle(for: draft, selection: selection, loc: loc)) {
                Task { await presenter.submit(draft, selection: selection, session: session, loc: loc, toasts: toasts) }
            }
            // A season pill / card preselects its own season: with nothing to
            // tick on tvOS, the others are one more button (« Demander les
            // saisons 4 à 6 »).
            if case .series(_, let seasons, _) = draft, selection != Set(seasons) {
                Button(SeerrRequestPresenter.seasonsActionTitle(seasons, loc: loc)) {
                    Task { await presenter.submit(draft, selection: Set(seasons), session: session, loc: loc, toasts: toasts) }
                }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        }
        #else
        content.sheet(item: Binding(get: { presenter.draft(for: host) }, set: { presenter.draft = $0 })) { draft in
            SeerrRequestSheet(draft: draft)
                .environment(appState)
                .environment(themeManager)
                .environment(loc)
                .environment(toasts)
                .environment(session)
                .environment(presenter)
        }
        #endif
    }

    #if os(tvOS)
    private var dialogTitle: String {
        switch presenter.draft {
        case .movie(let title), .series(let title, _, _): title.title
        case .films(let titles): loc.counted("seerr.request.films.header", titles.count)
        case nil: ""
        }
    }
    #endif
}

#if os(iOS)
/// A standalone View with its own `@Environment` (root RULE: a presented
/// context does not see the parent's observation).
struct SeerrRequestSheet: View {
    let draft: SeerrRequestDraft

    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(SeerrSession.self) private var session
    @Environment(SeerrRequestPresenter.self) private var presenter

    @State private var selection: Set<Int>
    @State private var sending = false

    init(draft: SeerrRequestDraft) {
        self.draft = draft
        _selection = State(initialValue: draft.defaultSelection(partial: true))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    header
                    choices
                    nextStep
                    CinemaButton(
                        title: SeerrRequestPresenter.actionTitle(for: draft, selection: effective, loc: loc),
                        style: .accent, isLoading: sending
                    ) { send() }
                    .disabled(!canSend)
                }
                .padding(CinemaSpacing.spacing4)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.cancel")) { dismiss() }.tint(themeManager.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The ticks are hidden without partial requests: everything goes.
    private var effective: Set<Int> {
        SeerrRequestPresenter.effectiveSelection(
            draft, selection, partial: session.publicSettings?.partialRequestsEnabled ?? true)
    }

    private var canSend: Bool {
        if case .movie = draft { return !sending }
        return !effective.isEmpty && !sending
    }

    private var leadTitle: SeerrTitle? {
        switch draft {
        case .movie(let title), .series(let title, _, _): title
        case .films(let titles): titles.first
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
            if case .films = draft {} else if let leadTitle {
                poster(for: leadTitle)
            }
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                if case .films(let titles) = draft {
                    Text(loc.counted("seerr.request.films.header", titles.count))
                        .font(CinemaFont.headline(.small))
                        .foregroundStyle(CinemaColor.onSurface)
                } else if let leadTitle {
                    Text(leadTitle.title)
                        .font(CinemaFont.headline(.small))
                        .foregroundStyle(CinemaColor.onSurface)
                    Text(subtitle(leadTitle))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                    if let overview = leadTitle.overview, !overview.isEmpty {
                        Text(overview)
                            .font(CinemaFont.dynamicBody)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func subtitle(_ title: SeerrTitle) -> String {
        let kind = loc.localized(title.kind == .movie ? "seerr.request.kind.movie" : "seerr.request.kind.series")
        guard let year = title.year else { return kind }
        return "\(kind) · \(String(year))"
    }

    /// None without a poster path (a request raised from a series fiche,
    /// whose own poster the user just left): no empty placeholder box.
    @ViewBuilder
    private func poster(for title: SeerrTitle) -> some View {
        if let base = session.client?.baseURL,
           let url = SeerrImages.posterURL(
               path: title.posterPath, seerrBase: base, cacheImages: session.publicSettings?.cacheImages ?? false) {
            CinemaLazyImage(url: url)
                .frame(width: 84, height: 126)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var choices: some View {
        switch draft {
        case .movie:
            EmptyView()
        case .series(_, let seasons, _):
            if session.publicSettings?.partialRequestsEnabled ?? true {
                VStack(spacing: CinemaSpacing.spacing2) {
                    ForEach(seasons, id: \.self) { number in
                        tickRow(number, label: SeerrRequestPresenter.seasonName(number, loc: loc))
                    }
                }
            }
        case .films(let titles):
            VStack(spacing: CinemaSpacing.spacing2) {
                ForEach(titles, id: \.tmdbId) { film in
                    tickRow(film.tmdbId, label: film.year.map { "\(film.title) (\(String($0)))" } ?? film.title)
                }
            }
        }
    }

    private func tickRow(_ key: Int, label: String) -> some View {
        let isOn = selection.contains(key)
        return Button {
            if isOn { selection.remove(key) } else { selection.insert(key) }
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: CinemaScale.pt(22), weight: .semibold))
                    .foregroundStyle(isOn ? themeManager.accent : CinemaColor.onSurfaceMuted)
                    .accessibilityHidden(true)
                Text(label)
                    .font(CinemaFont.dynamicBody)
                    .foregroundStyle(CinemaColor.onSurface)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(CinemaSpacing.spacing3)
            .glassPanel()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ViewBuilder
    private var nextStep: some View {
        if case .connected(let user) = session.connection {
            let kind = leadTitle?.kind ?? .movie
            Text(loc.localized(SeerrRequestPresenter.nextStepKey(permissions: user.permissions, kind: kind)))
                .font(CinemaFont.label(.small))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
    }

    private func send() {
        sending = true
        let chosen = effective
        Task {
            await presenter.submit(draft, selection: chosen, session: session, loc: loc, toasts: toasts)
            sending = false
            dismiss()
        }
    }
}
#endif
