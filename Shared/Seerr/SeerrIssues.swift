import Foundation
import Observation
import CinemaxKit

/// One line of « Signalements ». Its title and poster come from
/// `SeerrRequestTitles`, after the list is already on screen.
struct SeerrIssueRow: SeerrTitledRow {
    let issue: SeerrIssue
    var title: String?
    var posterPath: String?
    var isTitlePending = true

    var id: Int { issue.id }

    init(item: SeerrIssue) { issue = item }
}

/// What a report's text says, read back: the episode numbers our own report
/// of missing episodes lists on its first line, then the user's own word.
struct SeerrIssueText: Equatable, Sendable {
    /// Ascending, each once; empty for any other report.
    let missingEpisodes: [Int]
    /// What the reporter wrote themselves — `nil` when nothing.
    let note: String?

    /// Our report reads « <words>: 4, 5 » then, on the next line, the user's
    /// word (`SeerrEpisodeReportDraft.message`) — in the REPORTER's language,
    /// which may not be the viewer's: the numbers are read from whatever
    /// follows the first line's last colon, never from a localized prefix.
    /// Only for a series report of type « other » (ours); a report written
    /// anywhere else is the user's word as a whole.
    static func parse(_ message: String?, kind: SeerrIssueKind, mediaKind: SeerrMediaKind) -> Self {
        let text = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Self(missingEpisodes: [], note: nil) }
        let lines = text.components(separatedBy: .newlines)
        if kind == .other, mediaKind == .tv, let first = lines.first, let numbers = episodeList(first) {
            let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return Self(missingEpisodes: numbers, note: rest.isEmpty ? nil : rest)
        }
        return Self(missingEpisodes: [], note: text)
    }

    /// « Épisodes manquants : 4, 5 » ⇒ [4, 5]; `nil` unless everything after
    /// the last colon is a list of positive numbers.
    private static func episodeList(_ line: String) -> [Int]? {
        guard let colon = line.lastIndex(of: ":") else { return nil }
        let parts = line[line.index(after: colon)...].split(separator: ",", omittingEmptySubsequences: false)
        var numbers: Set<Int> = []
        for part in parts {
            guard let number = Int(part.trimmingCharacters(in: .whitespaces)), number > 0 else { return nil }
            numbers.insert(number)
        }
        return numbers.isEmpty ? nil : numbers.sorted()
    }
}

/// Réglages → Seerr → « Signalements »: the household's OPEN problem reports,
/// newest first, 20 at a time, for a Seerr user who may MANAGE them
/// (`canManageIssues`, a Seerr admin included) — never the Jellyfin admin
/// flag. « Marquer comme résolu » in one tap, « Voir la fiche » when Seerr
/// knows the title's Jellyfin id. Built on « À valider »'s model: the count is
/// this listing's own `pageInfo.results`, never `/issue/count`.
@MainActor @Observable
final class SeerrIssuesModel {
    typealias Phase = SeerrMyRequestsModel.Phase

    nonisolated static let pageSize = 20

    private(set) var phase: Phase = .idle
    private(set) var isLoadingMore = false
    /// The reports whose resolution is on its way: their row waits, a second
    /// press does nothing.
    private(set) var resolving: Set<Int> = []
    private var pages = SeerrListPages<SeerrIssueRow>()

    var rows: [SeerrIssueRow] { pages.rows }
    var canLoadMore: Bool { pages.canLoadMore }
    /// How many reports are open, household-wide: the listing's total, less
    /// the ones resolved here since.
    var count: Int { pages.total }

    @ObservationIgnored private var snapshot: SeerrSession.Snapshot?
    @ObservationIgnored private var generation = 0

    /// The page shows for a connected Seerr user who may manage reports.
    static func isShown(for connection: SeerrSession.Connection) -> Bool {
        guard case .connected(let user) = connection else { return false }
        return user.permissions.canManageIssues
    }

    // MARK: Loading

    /// The first page, replacing whatever was listed; nothing at all is asked
    /// for a user who may not manage reports.
    func load(session: SeerrSession) async {
        guard Self.isShown(for: session.connection), let snap = session.snapshot() else { return }
        generation &+= 1
        let pass = generation
        snapshot = snap
        pages = SeerrListPages()
        resolving = []
        isLoadingMore = false
        phase = .loading

        let page: SeerrIssuePage
        do {
            page = try await Self.fetchPage(session: session, skip: 0)
        } catch {
            guard pass == generation, !Task.isCancelled, session.isCurrent(snap) else { return }
            phase = .failed
            return
        }
        guard pass == generation, session.isCurrent(snap) else { return }
        let fresh = pages.append(page.results, total: page.total, served: page.served)
        phase = .loaded
        session.noteIssueCount(count, for: snap)
        await loadTitles(of: fresh, session: session, snapshot: snap, pass: pass)
    }

    /// « Afficher plus », as in « À valider ».
    func loadNextPage(session: SeerrSession) async {
        guard canLoadMore, !isLoadingMore, phase == .loaded, let snap = snapshot, session.isCurrent(snap) else { return }
        let pass = generation
        isLoadingMore = true
        let page: SeerrIssuePage
        do {
            page = try await Self.fetchPage(session: session, skip: pages.loadedCount)
        } catch {
            if pass == generation { isLoadingMore = false }
            return
        }
        guard pass == generation, session.isCurrent(snap) else { return }
        isLoadingMore = false
        let fresh = pages.append(page.results, total: page.total, served: page.served)
        session.noteIssueCount(count, for: snap)
        await loadTitles(of: fresh, session: session, snapshot: snap, pass: pass)
    }

    private static func fetchPage(session: SeerrSession, skip: Int) async throws -> SeerrIssuePage {
        try await session.perform { client, credential in
            try await client.issues(filter: .open, take: pageSize, skip: skip, credential)
        }
    }

    private func loadTitles(
        of issues: [SeerrIssue], session: SeerrSession, snapshot snap: SeerrSession.Snapshot, pass: Int
    ) async {
        let targets = issues.map {
            SeerrRequestTitles.Target(rowId: $0.id, kind: $0.media.kind, tmdbId: $0.media.tmdbId)
        }
        await SeerrRequestTitles.load(targets, session: session) { id, found in
            guard pass == generation, session.isCurrent(snap) else { return }
            pages.setTitle(found, for: id)
        }
    }

    // MARK: « Marquer comme résolu »

    private enum Outcome { case done, alreadyGone, failed, cancelled }

    /// Done ⇒ the row leaves (it is no longer open), the count drops, a toast
    /// says so. Gone meanwhile (404 — or Seerr 3.5.1's 500 « Issue not
    /// found. », which the client maps to `.notFound`) ⇒ the row leaves the
    /// same way, with an info toast. Any other failure keeps the row for
    /// another try. An account change meanwhile writes and shows nothing.
    func resolve(_ id: Int, session: SeerrSession, toasts: ToastCenter, loc: LocalizationManager) async {
        guard !resolving.contains(id), phase == .loaded, rows.contains(where: { $0.id == id }),
              let snap = snapshot, session.isCurrent(snap) else { return }
        let pass = generation
        resolving.insert(id)
        let outcome: Outcome
        do {
            try await session.perform { client, credential in
                try await client.resolveIssue(issueId: id, credential)
            }
            outcome = .done
        } catch SeerrError.notFound {
            outcome = .alreadyGone
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failed
        }
        guard session.isCurrent(snap) else { return }
        // A newer listing owns the rows; the toast still answers the press.
        let ownsRows = pass == generation
        if ownsRows { resolving.remove(id) }
        switch outcome {
        case .done:
            if ownsRows { pages.remove(id); session.noteIssueCount(count, for: snap) }
            toasts.success(loc.localized("seerr.issues.resolved"))
        case .alreadyGone:
            if ownsRows { pages.remove(id); session.noteIssueCount(count, for: snap) }
            toasts.info(loc.localized("seerr.issues.alreadyHandled"))
        case .failed:
            toasts.error(loc.localized("seerr.issues.resolveFailed"))
        case .cancelled:
            break
        }
    }

    /// What the resolve button says — on screen (tvOS) AND to VoiceOver.
    static func resolveTitleKey(isResolving: Bool) -> String {
        isResolving ? "seerr.issues.resolving" : "seerr.issues.resolve"
    }

    // MARK: « Voir la fiche » (pure + its one effect)

    /// The Jellyfin item a report opens: the series (or film) Seerr matched,
    /// whatever its availability — a series missing episodes is typically
    /// partly available, so « Regarder »'s `available` test does not apply.
    /// Seerr's word, hence `AppState.isValidItemId`.
    static func openTarget(_ issue: SeerrIssue) -> String? {
        guard let id = issue.media.jellyfinMediaId, AppState.isValidItemId(id) else { return nil }
        return id
    }

    /// Opens the fiche through the app's one deep-link route (a modal over
    /// the tabs, Settings stays underneath). `false` = nothing to open.
    @discardableResult
    static func open(_ issue: SeerrIssue, appState: AppState) -> Bool {
        guard let id = openTarget(issue) else { return false }
        appState.pendingDeepLinkItemId = id
        return true
    }

    // MARK: What the row says (pure)

    /// « Saison 2 · épisodes 4, 5 manquants » for our report of missing
    /// episodes; « Saison 2 » for another report of type « other » on a
    /// season; otherwise the kind (« Problème vidéo »), after the season and
    /// the episode it names.
    static func problemLine(_ issue: SeerrIssue, loc: LocalizationManager) -> String {
        let text = SeerrIssueText.parse(issue.message, kind: issue.kind, mediaKind: issue.media.kind)
        var parts: [String] = []
        if issue.problemSeason > 0 { parts.append(loc.localized("seerr.issues.season", issue.problemSeason)) }
        if !text.missingEpisodes.isEmpty {
            let list = text.missingEpisodes.map(String.init).joined(separator: ", ")
            parts.append(loc.localized(loc.pluralKey("seerr.issues.missingEpisodes", text.missingEpisodes.count), list))
        } else {
            if issue.problemEpisode > 0 { parts.append(loc.localized("seerr.issues.episode", issue.problemEpisode)) }
            if issue.kind != .other || parts.isEmpty { parts.append(loc.localized(kindKey(issue.kind))) }
        }
        let line = parts.joined(separator: " · ")
        // « épisodes 4, 5 manquants » may open the line (no season named).
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    static func kindKey(_ kind: SeerrIssueKind) -> String {
        switch kind {
        case .video: "seerr.issues.type.video"
        case .audio: "seerr.issues.type.audio"
        case .subtitles: "seerr.issues.type.subtitles"
        case .other: "seerr.issues.type.other"
        }
    }

    /// The reporter's own word, if any (never the episode list).
    static func note(_ issue: SeerrIssue) -> String? {
        SeerrIssueText.parse(issue.message, kind: issue.kind, mediaKind: issue.media.kind).note
    }

    /// « Signalé par Léa · il y a 2 h », in the app's language (`loc.locale`);
    /// « Signalé il y a 2 h » when Seerr names nobody.
    static func reportedLine(_ issue: SeerrIssue, loc: LocalizationManager) -> String {
        let when = issue.createdAt.formatted(SeerrPendingModel.relativeStyle(loc: loc))
        guard let name = issue.createdBy?.displayName, !name.isEmpty else {
            return loc.localized("seerr.issues.reportedAt", when)
        }
        return loc.localized("seerr.issues.reportedBy", name, when)
    }
}
