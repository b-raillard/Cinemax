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

    func present(_ draft: SeerrRequestDraft) { self.draft = draft }

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
    static func seasonsActionTitle(_ seasons: [Int], loc: LocalizationManager) -> String {
        if seasons.count == 1, let only = seasons.first {
            return loc.localized("seerr.request.action.season", only)
        }
        if let first = seasons.first, let last = seasons.last, seasons.count > 1,
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
        var error: Error?
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
        var permissions = SeerrPermissions()
        if case .connected(let user) = session.connection { permissions = user.permissions }

        // Films 2…n must never go out under another account.
        let account = session.activeAccountKeyProvider()
        var outcomes: [Result] = []
        for job in jobs {
            guard session.activeAccountKeyProvider() == account else { return }
            let request = job.request
            do {
                _ = try await session.perform { client, credential in
                    try await client.createRequest(request, credential)
                }
                outcomes.append(Result(job: job, outcome: .sent))
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
                mark(result.job, as: permissions.autoApproves(result.job.kind) ? .processing : .pending)
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

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.confirmationDialog(
            dialogTitle,
            isPresented: Binding(get: { presenter.draft != nil }, set: { if !$0 { presenter.draft = nil } }),
            titleVisibility: .visible,
            presenting: presenter.draft
        ) { draft in
            let partial = session.publicSettings?.partialRequestsEnabled ?? true
            let selection = SeerrRequestPresenter.effectiveSelection(
                draft, draft.defaultSelection(partial: partial), partial: partial)
            Button(SeerrRequestPresenter.actionTitle(for: draft, selection: selection, loc: loc)) {
                Task { await presenter.submit(draft, selection: selection, session: session, loc: loc, toasts: toasts) }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        }
        #else
        content.sheet(item: Binding(get: { presenter.draft }, set: { presenter.draft = $0 })) { draft in
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

    @ViewBuilder
    private func poster(for title: SeerrTitle) -> some View {
        if let base = session.client?.baseURL {
            CinemaLazyImage(
                url: SeerrImages.posterURL(
                    path: title.posterPath, seerrBase: base,
                    cacheImages: session.publicSettings?.cacheImages ?? false))
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
                        tickRow(number, label: loc.localized("seerr.request.seasonRow", number))
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
