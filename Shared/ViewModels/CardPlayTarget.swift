import Foundation
import OSLog
import CinemaxKit
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "CardPlayTarget")

/// What a card needs to know to start playback: what to open, under what
/// title, and at what second to resume.
struct CardPlayTarget: Sendable, Equatable {
    let itemId: String
    let title: String
    /// `nil` ⇒ play from the beginning.
    let startSeconds: Double?
}

/// A card menu's optimistic mirror of a server-side flag (watched, favourite).
///
/// Lives here, next to `isResumable`, because the watched override *modifies*
/// that rule: the menu's play group has to see the toggle the user just made,
/// and deriving the label from the override while deriving the play entries
/// from the raw snapshot is exactly the drift `CardPlayTargetResolver` exists
/// to prevent.
///
/// It carries the server value it was derived from **and** the instant it was
/// set, and surrenders on either. The `base` check alone was not enough: on a
/// surface that never refreshes its DTOs (Search observes none of the three
/// refresh notifications), a server value that returns to `base` — which is
/// what a playback stop does to a just-marked-watched item — left the override
/// standing for the lifetime of the view's identity.
struct OptimisticFlag: Equatable {
    /// How long an optimistic value outranks the snapshot. It only has to
    /// bridge the gap until the menu is dismissed and real data arrives; past
    /// that, server truth is the better answer even on a surface that never
    /// refreshes.
    static let lifetime: TimeInterval = 20

    let base: Bool
    let value: Bool
    let setAt: Date

    init(base: Bool, value: Bool, setAt: Date = Date()) {
        self.base = base
        self.value = value
        self.setAt = setAt
    }

    /// The override, or `nil` once it has expired or the server value it was
    /// derived from has moved on — in which case the caller falls back to
    /// server truth.
    func resolved(against serverValue: Bool, now: Date = Date()) -> Bool? {
        guard now.timeIntervalSince(setAt) < Self.lifetime else { return nil }
        return base == serverValue ? value : nil
    }
}

/// Resolves the play target for a poster card.
///
/// **What this resolver deliberately does NOT do**: pick the episode of a
/// series when that information is missing. `getPlaybackInfo` already
/// resolves Series/Season → Episode server-side in CinemaxKit
/// (`resolvePlayableEpisode` — next-up first, else the first episode of the
/// first season), and duplicating that decision would create two authorities
/// that can diverge. It exists only to fetch **the resume position**, plus
/// the episode id when the next-up probe hands one over — in which case the
/// target points at the episode directly, so the offset and the item always
/// describe the same media.
///
/// Deliberately `nonisolated` and parameterized by **scalars**: passing a
/// `BaseItemDto` (non-`Sendable`) into a nonisolated async call from the
/// `@MainActor` would be a region transfer of a value the main actor still
/// holds. The caller extracts the fields on the main actor side.
///
/// **Sibling, not a duplicate, of `MediaDetailScreen.resolvedPlayTarget(for:)`**:
/// the detail screen's resolver additionally owns a version pick (its
/// "Version" row), which a card has no UI for and therefore cannot carry.
/// The two intentionally coexist — don't "unify" them, since doing so would
/// drag `mediaSourceId` onto cards that have no way to choose one.
enum CardPlayTargetResolver {

    /// How long to wait for the next-up probe before falling through to the
    /// series id itself (`getPlaybackInfo` resolves Series → Episode
    /// server-side anyway). The shared client timeout is 30s and this path
    /// has zero on-screen feedback while it waits.
    static let seriesProbeDeadline: Duration = .milliseconds(1500)

    static func resolve(
        itemId: String,
        type: BaseItemKind?,
        title: String,
        positionTicks: Int,
        api: any LibraryAPI,
        userId: String,
        probeDeadline: Duration = seriesProbeDeadline
    ) async -> CardPlayTarget {
        guard type == .series else {
            return CardPlayTarget(
                itemId: itemId,
                title: title,
                startSeconds: resumeSeconds(positionTicks: positionTicks)
            )
        }

        // A series card doesn't carry its next-up episode's userData: this is
        // the only case that costs a round-trip. The call is cached client-side
        // for 10s (prefix `nextup-`), so it is most often served locally right
        // after a detail-screen view — but from a library grid / Home genre
        // row / search it is cold every time, and the menu offers no loading
        // affordance while this awaits. Race it against `probeDeadline`: on
        // timeout, fall through to the series id with no resume offset —
        // `getPlaybackInfo` resolves the episode server-side regardless, so
        // the only thing lost is the resume position on a slow server.
        // **Deliberately NOT a `withTaskGroup`.** A group awaits every remaining
        // child after its body returns, so `group.next()` + `cancelAll()` yields
        // the deadline's *decision* immediately but only *returns* once the probe
        // has actually finished — the deadline was advisory, not enforced. Two
        // unstructured tasks racing onto one single-resume continuation is the
        // shape that actually bounds the wait.
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<ProbeOutcome, Never>) in
            let race = ProbeRace(continuation)
            // The loser is **not** cancelled, on purpose: `getNextUp` populates
            // its 10s `nextup-` cache only once the response lands, so cancelling
            // threw away exactly what would make the next tap on this card fast —
            // turning a one-off timeout into a repeated one, in the situation
            // where the resume offset is most wanted. It finishes unobserved.
            Task {
                race.resume(await probeNextUp(itemId: itemId, api: api, userId: userId))
            }
            Task {
                try? await Task.sleep(for: probeDeadline)
                race.resume(.timedOut)
            }
        }

        switch outcome {
        case .episode(let result):
            return CardPlayTarget(
                itemId: result.episodeId,
                title: result.title ?? title,
                startSeconds: resumeSeconds(positionTicks: result.positionTicks)
            )
        case .noNextUp, .failed:
            return CardPlayTarget(itemId: itemId, title: title, startSeconds: nil)
        case .timedOut:
            logger.debug("Card next-up probe timed out for series \(itemId, privacy: .public) — falling back to the series id")
            return CardPlayTarget(itemId: itemId, title: title, startSeconds: nil)
        }
    }

    /// Whether a stored position counts as a resume point: any position at all.
    ///
    /// **`isPlayed` is deliberately NOT an input.** Jellyfin never leaves a
    /// position on an item it marks played: a playback that reaches the end
    /// (`UpdatePlayState`, past `MaxResumePct`) and both watched toggles
    /// (`POST` / `DELETE /UserPlayedItems`, i.e. `MarkPlayed(resetPosition:
    /// true)` and `MarkUnplayed`) all write 0 — read in the 10.9 and 12.0
    /// sources. So a position on a played item is a REWATCH stopped part-way,
    /// which the server lists in its resume rail. The app used to add
    /// `&& !isPlayed`, and measured on 2026-10-05 that started such a card — Arrow
    /// S02E11, played, stopped again at 36:33, drawn with its progress bar in
    /// « Reprendre » — from 0:00. Exposed rather than private because the
    /// context menu needs the *predicate* (its "Resume" label, "Play from
    /// beginning") while the resolver needs the *offset*.
    static func isResumable(positionTicks: Int) -> Bool {
        positionTicks > 0
    }

    /// The position a card menu must reason about: the snapshot's, unless a
    /// watched toggle made in that menu is still in force — the server has then
    /// reset the position to 0, in EITHER direction (see `isResumable`), while
    /// the snapshot still carries the old one.
    ///
    /// The menu used to derive its watched *label* from the override and its
    /// *play group* from the raw snapshot, so marking an item watched left
    /// "Resume" on offer — and it really did open the film mid-way, on an item
    /// the app had just marked fully played. One rule, one input.
    static func effectivePositionTicks(
        _ positionTicks: Int, isPlayed: Bool,
        playedOverride: OptimisticFlag?, now: Date = Date()
    ) -> Int {
        playedOverride?.resolved(against: isPlayed, now: now) == nil ? positionTicks : 0
    }

    /// `isResumable` as the card menu must apply it, through
    /// `effectivePositionTicks`.
    static func isResumable(
        positionTicks: Int, isPlayed: Bool,
        playedOverride: OptimisticFlag?, now: Date = Date()
    ) -> Bool {
        isResumable(positionTicks: effectivePositionTicks(
            positionTicks, isPlayed: isPlayed, playedOverride: playedOverride, now: now))
    }

    /// The source a first open asks for. An explicit one (the fiche's
    /// « Version » row) wins; otherwise a RESUME opens the item's own source —
    /// the one whose id is the item's, which owns the position — and a start
    /// from 0 leaves the pick to `MediaSourceQuality`.
    ///
    /// Without this, a two-version title resumed from a card opened the
    /// higher-ranked 4K at the 1080p's position, reported its progress there,
    /// and the title dropped out of « Reprendre » after a relaunch (recette
    /// 2026-10-08, M2-15: Sintel, resume on the 1080p, card opened the 4K). An
    /// id matching no source (a series, resolved to an episode server-side)
    /// falls back to the ranked pick in `MediaSourceQuality.resolve`.
    nonisolated static func sourceToOpen(
        itemId: String, explicitSourceId: String?, startTime: Double?
    ) -> String? {
        if let explicitSourceId { return explicitSourceId }
        guard let startTime, startTime > 0 else { return nil }
        return itemId
    }

    /// The resume offset in seconds, or `nil` to play from the beginning.
    ///
    /// Exposed for the same reason as `isResumable`: Home's hero, its Continue
    /// Watching rail and the library hero each hand a `startTime` to
    /// `PlayLink`, and one rule must decide all of them and the menus.
    static func resumeSeconds(positionTicks: Int) -> Double? {
        guard isResumable(positionTicks: positionTicks) else { return nil }
        return positionTicks.jellyfinSeconds
    }

    /// The next-up lookup, as a value. Split out of the race so the racing code
    /// reads as a race and this reads as a fetch.
    private static func probeNextUp(
        itemId: String, api: any LibraryAPI, userId: String
    ) async -> ProbeOutcome {
        do {
            guard let episode = try await api.getNextUp(seriesId: itemId, userId: userId),
                  let episodeId = episode.id else {
                return .noNextUp
            }
            return .episode(NextUpProbeResult(
                episodeId: episodeId,
                title: episode.name,
                positionTicks: episode.userData?.playbackPositionTicks ?? 0
            ))
        } catch {
            // No `Task.isCancelled` special-case any more: nothing cancels this
            // probe, so every error reaching here is a genuine failure.
            logger.debug("Card next-up probe failed for series \(itemId, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failed
        }
    }


    /// Only the scalars pulled off the next-up episode inside the probing
    /// task — never the `BaseItemDto` itself, which is not `Sendable`
    /// and cannot cross the task boundary.
    private struct NextUpProbeResult: Sendable {
        let episodeId: String
        let title: String?
        let positionTicks: Int
    }

    private enum ProbeOutcome: Sendable {
        case episode(NextUpProbeResult)
        case noNextUp
        case failed
        case timedOut
    }
}

/// Guards a continuation so exactly one of the two racers resumes it —
/// resuming a `CheckedContinuation` twice is a crash, and both racers can
/// land near-simultaneously on a deadline this short.
///
/// File-scope and generic because both card-menu resolvers need the same
/// bound: `CardPlayTargetResolver` races the next-up probe, and
/// `CardEpisodeNavigationResolver` races the season fetch. A second
/// hand-written `@unchecked Sendable` copy is exactly the kind of duplicate
/// whose two halves drift.
private final class ProbeRace<Outcome: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?

    init(_ continuation: CheckedContinuation<Outcome, Never>) {
        self.continuation = continuation
    }

    /// First caller wins; every later one is a no-op. The continuation is
    /// resumed OUTSIDE the lock so the awaiting task can't be scheduled while
    /// this thread still holds it.
    func resume(_ outcome: Outcome) {
        let pending: CheckedContinuation<Outcome, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: outcome)
    }
}

/// Resolves the prev/next episode graph a card-launched playback must carry.
///
/// Home's two rails hand both `PlayLink` and the card menu the trio they have
/// already built (`resumeNavigation` / `nextUpNavigation`). No other surface
/// can: `SearchScreen` and `WatchedHistoryScreen` draw EPISODE cards from a
/// flat query that never touched a season, so their menus passed `nil` — and a
/// nil navigator costs far more than two buttons. `handlePlaybackEnded` gates
/// autoplay on `nextEpisode != nil && episodeNavigator != nil`, and the
/// "you finished …" card on the navigator alone, so an episode started from
/// Search played to its end and closed in silence. Measured on device
/// 2026-08-21: the same episode of the same season drew **3** transport
/// buttons launched from Search and **5** launched from the series page.
/// Same defect, same cure, as the library hero's `loadHeroNavigation`.
///
/// Resolved HERE — once, at play time — and never per card. A `contextMenu`'s
/// content is built **synchronously** for every card a lazy container
/// instantiates, so probing per card would mean a season fetch per poster on
/// every grid fill. This runs only when the user actually starts something,
/// and rides the 10 s `episodes-` cache.
///
/// `nonisolated`, scalars in and `Sendable` values out, same discipline as
/// `CardPlayTargetResolver` right above.
enum CardEpisodeNavigationResolver {

    /// The whole resolution is bounded, for the same reason the next-up probe
    /// is: the menu offers no loading affordance, and before this existed the
    /// tap opened the player at once. A slow server must cost the episode
    /// buttons — never turn "Lecture" into a button that looks dead.
    static let probeDeadline: Duration = .milliseconds(1500)

    /// `nil` when the target has no neighbours, when the season can't be
    /// resolved, or when the deadline expires first. Every one of those is an
    /// ordinary outcome that degrades to today's behaviour, so none of them
    /// is surfaced as an error over a playback that is otherwise fine.
    static func resolve(
        episodeId: String,
        seriesId: String?,
        seasonId: String?,
        api: any LibraryAPI,
        userId: String,
        probeDeadline: Duration = probeDeadline
    ) async -> CardPlaybackNavigation? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CardPlaybackNavigation?, Never>) in
            let race = ProbeRace(continuation)
            // The loser is deliberately NOT cancelled, same argument as the
            // next-up probe: `getEpisodeRefs` fills its 300 s `episoderefs-`
            // cache only once the response lands, so cancelling would throw
            // away precisely what makes the next play on this season instant.
            Task {
                race.resume(await probe(
                    episodeId: episodeId, seriesId: seriesId, seasonId: seasonId,
                    api: api, userId: userId
                ))
            }
            Task {
                try? await Task.sleep(for: probeDeadline)
                race.resume(nil)
            }
        }
    }

    private static func probe(
        episodeId: String, seriesId: String?, seasonId: String?,
        api: any LibraryAPI, userId: String
    ) async -> CardPlaybackNavigation? {
        var series = seriesId
        var season = seasonId
        // A search hit carries `seriesID`/`seasonID` already; a series card
        // whose next-up probe handed back an episode id carries neither, and
        // a season is what `getEpisodeRefs` is keyed on. One 10 s-cached,
        // single-flighted `getItem` closes the gap — and reports no season at
        // all when the target is still the series itself (the next-up probe
        // timed out), which is what makes that case a clean `nil`.
        if series == nil || season == nil {
            guard let item = try? await api.getItem(userId: userId, itemId: episodeId) else { return nil }
            series = series ?? item.seriesID
            season = season ?? item.seasonID
        }
        guard let series, let season else { return nil }
        // `getEpisodeRefs`: only prev/next is derived here, and that needs an
        // ordered list of ids and titles — nothing the full episode DTO adds.
        guard let episodes = try? await api.getEpisodeRefs(
            seriesId: series, seasonId: season, userId: userId
        ) else { return nil }

        let nav = buildEpisodeNavigation(for: episodeId, in: episodes)
        // A one-episode season yields no navigator; handing the player an
        // empty trio would behave exactly like `nil` while claiming navigation
        // exists where there is none.
        guard let navigator = nav.navigator else { return nil }
        return CardPlaybackNavigation(
            previous: nav.previous, next: nav.next, navigator: navigator
        )
    }
}

/// Where "Play all" starts inside a collection.
///
/// Extracted as a pure rule for the same reason as `CardPlayTargetResolver`:
/// it is a *policy*, and the project already carries three copies of the same
/// idea (the server's `resolvePlayableEpisode`, the library hero's next-up
/// probe, and this one). Keeping it here, testable and named, is what stops a
/// fourth reading of "where does this set resume" from drifting away.
enum CollectionPlayTarget {
    /// Index of the member to open: the first the user hasn't finished, else
    /// the first of all.
    ///
    /// A saga watched end to end replays from the beginning rather than
    /// refusing to play — the same fallback `resolvePlayableEpisode` applies
    /// to a series whose every episode is watched, which is precisely the case
    /// where `getNextUp` returns nothing.
    ///
    /// Takes the played flags rather than the items: the members are
    /// non-`Sendable` `BaseItemDto`s owned by the main actor, and the rule
    /// needs nothing else from them.
    static func startIndex(playedFlags: [Bool]) -> Int? {
        guard !playedFlags.isEmpty else { return nil }
        return playedFlags.firstIndex(of: false) ?? 0
    }
}
