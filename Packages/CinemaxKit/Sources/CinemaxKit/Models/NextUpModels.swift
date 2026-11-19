import Foundation
import JellyfinAPI

/// The order a series' episodes are chained in — the SSOT behind episode
/// navigation (`PlayLink.swift`) and the next-up correction below.
public enum SeriesEpisodeOrder {
    /// Regular seasons in season-number order, keeping the server's order
    /// inside a season (the sort is made stable by the original offset);
    /// `specials: true` yields season 0 instead, a chain of its own.
    public static func chain(_ all: [EpisodeReference], specials: Bool) -> [EpisodeReference] {
        all.enumerated()
            .filter { ($0.element.season == 0) == specials }
            .sorted { lhs, rhs in
                let left = lhs.element.season ?? .max
                let right = rhs.element.season ?? .max
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    /// The episode that follows `episodeId` in the regular chain. `nil` for
    /// the last episode, for a special, and for an id the list does not know.
    public static func successor(of episodeId: String, in all: [EpisodeReference]) -> EpisodeReference? {
        let regular = chain(all, specials: false)
        guard let index = regular.firstIndex(where: { $0.id == episodeId }), index + 1 < regular.count else {
            return nil
        }
        return regular[index + 1]
    }
}

/// One played episode, as the next-up correction reads it.
public struct RecentPlay: Sendable, Equatable {
    public let seriesId: String
    public let episodeId: String
    public let playedAt: Date

    public init(seriesId: String, episodeId: String, playedAt: Date) {
        self.seriesId = seriesId
        self.episodeId = episodeId
        self.playedAt = playedAt
    }
}

/// « À suivre » as the owner reads it: the episode after the one watched most
/// RECENTLY, whatever its own watched state.
///
/// The server reads it as the first unplayed episode after the HIGHEST one
/// ever played, so a series replayed out of order has nothing next up
/// (measured on 12.4, 2026-11-19: *Arrow*, seasons 4–8 seen, S02E19–22 played
/// that week → nothing, where S02E23 was expected). Its `enableRewatching`
/// flag is not the answer either: it returns the next already-PLAYED episode
/// (S03E13 on the same data).
///
/// The correction only ever fires on out-of-order viewing: for a series
/// watched in order the two readings name the same episode.
public enum NextUpCorrection {
    /// A play older than this no longer moves « À suivre » (owner's choice,
    /// 2026-11-19).
    public static let window: TimeInterval = 30 * 24 * 3600
    /// How many played episodes the rail's correction reads, and how many
    /// series it will then look up.
    public static let recentPlayLimit = 100
    public static let maxSeries = 12

    /// The most recent play of each series, inside the window, most recent
    /// first. `plays` is expected most-recent-first, ties broken towards the
    /// HIGHER episode (the query's secondary sort): a season marked watched in
    /// one tap carries one timestamp, and must read as "reached its end".
    public static func lastPlays(_ plays: [RecentPlay], now: Date) -> [RecentPlay] {
        var seen = Set<String>()
        var result: [RecentPlay] = []
        for play in plays where now.timeIntervalSince(play.playedAt) <= window {
            guard seen.insert(play.seriesId).inserted else { continue }
            result.append(play)
            if result.count == maxSeries { break }
        }
        return result
    }

    /// What the correction changes in a rail, as ids — the caller owns the
    /// items. `corrected` lists, most recent play first, the series whose
    /// next-up episode differs from the server's (or is missing from it).
    public struct Plan: Sendable, Equatable {
        public struct Entry: Sendable, Equatable {
            public let seriesId: String
            public let episodeId: String

            public init(seriesId: String, episodeId: String) {
                self.seriesId = seriesId
                self.episodeId = episodeId
            }
        }
        public let corrected: [Entry]
    }

    /// - Parameters:
    ///   - serverNextUp: series id → the server's next-up episode id.
    ///   - successors: series id → the episode after its most recent play
    ///     (absent when that play was the series' last episode, a special, or
    ///     the lookup failed — the server's answer then stands).
    public static func plan(
        lastPlays: [RecentPlay],
        successors: [String: String],
        serverNextUp: [String: String]
    ) -> Plan {
        Plan(corrected: lastPlays.compactMap { play in
            guard let next = successors[play.seriesId], serverNextUp[play.seriesId] != next else { return nil }
            return Plan.Entry(seriesId: play.seriesId, episodeId: next)
        })
    }
}

/// The series the user removed from « À suivre », as stored in the account's
/// display preferences: series id → the next-up episode that was showing.
///
/// Keyed on that EPISODE so the series comes back by itself: once another
/// episode is watched, next-up names a different one and the entry no longer
/// matches.
public struct NextUpHiddenList: Sendable, Equatable {
    /// Its own DisplayPreferences entity: a write replaces the whole entity,
    /// and sharing Seerr's would make two writers race over one document.
    public static let preferencesId = "jellyglass-nextup"
    public static let client = "jellyglass"
    public static let preferenceKey = "hidden"
    /// Entries kept; the oldest insertions go first when the list is full.
    public static let capacity = 60

    public private(set) var entries: [String: String]
    private var order: [String]

    public init() {
        entries = [:]
        order = []
    }

    /// Decodes the stored value; anything unreadable is an empty list.
    public init(storedValue: String?) {
        self.init()
        guard let data = storedValue?.data(using: .utf8),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data) else { return }
        for pair in pairs where pair.count == 2 {
            hide(seriesId: pair[0], episodeId: pair[1])
        }
    }

    public init(_ dto: DisplayPreferencesDto?) {
        self.init(storedValue: dto?.customPrefs?[Self.preferenceKey])
    }

    /// `dto` with this list written in, every other key kept.
    public func merged(into dto: DisplayPreferencesDto?) -> DisplayPreferencesDto {
        var result = dto ?? DisplayPreferencesDto()
        var prefs = result.customPrefs ?? [:]
        prefs[Self.preferenceKey] = storedValue
        result.customPrefs = prefs
        result.id = Self.preferencesId
        result.client = Self.client
        return result
    }

    public var storedValue: String {
        let pairs = order.compactMap { id in entries[id].map { [id, $0] } }
        guard let data = try? JSONEncoder().encode(pairs) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    public func hides(seriesId: String?, episodeId: String?) -> Bool {
        guard let seriesId, let episodeId else { return false }
        return entries[seriesId] == episodeId
    }

    public mutating func hide(seriesId: String, episodeId: String) {
        order.removeAll { $0 == seriesId }
        order.append(seriesId)
        entries[seriesId] = episodeId
        while order.count > Self.capacity {
            entries[order.removeFirst()] = nil
        }
    }

    public mutating func unhide(seriesId: String) {
        order.removeAll { $0 == seriesId }
        entries[seriesId] = nil
    }
}
