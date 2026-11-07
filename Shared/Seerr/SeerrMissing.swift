import Foundation
import CinemaxKit
import JellyfinAPI

/// What a « missing » title or season offers: ask for it, or where the
/// request stands.
enum SeerrBadge: Equatable, Sendable {
    case request, pending, processing, declined
}

/// TMDb movie and TV ids overlap: ownership is per kind.
struct SeerrOwnedKey: Hashable, Sendable {
    let kind: SeerrMediaKind
    let tmdbId: Int
}

struct SeerrMissingTitle: Identifiable, Equatable, Sendable {
    let title: SeerrTitle
    let badge: SeerrBadge
    var id: String { "\(title.kind.rawValue)-\(title.tmdbId)" }
}

struct SeerrMissingSeason: Identifiable, Equatable, Sendable {
    let seriesTmdbId: Int
    let seasonNumber: Int
    let badge: SeerrBadge
    var id: String { "tv-\(seriesTmdbId)-s\(seasonNumber)" }
}

/// A Seerr section of a browse surface. `loaded([])` renders NOTHING, like
/// `hidden`; `loading` is the skeleton, bounded by `loadSection`'s deadline.
enum MissingSection<Element: Equatable & Sendable>: Equatable {
    case hidden, loading, loaded([Element])

    /// Draws nothing at all: hidden, or an empty answer.
    var drawsNothing: Bool {
        switch self {
        case .hidden: true
        case .loading: false
        case .loaded(let elements): elements.isEmpty
        }
    }
}

enum SeerrImages {
    /// Seerr's image proxy (sub-path kept) when `cacheImages`, TMDb otherwise.
    static func posterURL(path: String?, seerrBase: URL, cacheImages: Bool) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        if cacheImages {
            return SeerrAddress.endpoint("/imageproxy/tmdb/t/p/w300" + suffix, on: seerrBase)
        }
        return URL(string: "https://image.tmdb.org/t/p/w300" + suffix)
    }
}

/// Pure: what the Jellyfin library lacks, and how each missing item stands.
enum SeerrMissing {
    /// The owned (kind, TMDb id) pairs: movies and series only; provider key
    /// matched case-insensitively, non-numeric values ignored.
    static func ownedTmdbIds(_ items: [BaseItemDto]) -> Set<SeerrOwnedKey> {
        var ids = Set<SeerrOwnedKey>()
        for item in items {
            let kind: SeerrMediaKind
            switch item.type {
            case .movie: kind = .movie
            case .series: kind = .tv
            default: continue
            }
            guard let id = tmdbId(of: item) else { continue }
            ids.insert(SeerrOwnedKey(kind: kind, tmdbId: id))
        }
        return ids
    }

    /// The item's TMDb id: provider key matched case-insensitively, a
    /// non-numeric value ignored.
    static func tmdbId(of item: BaseItemDto) -> Int? {
        item.providerIDs?.first { $0.key.lowercased() == "tmdb" }.flatMap { Int($0.value) }
    }

    /// Candidates minus what Jellyfin owns and what Seerr has (partially)
    /// available or blocklisted; deleted stays missing. Seerr's order kept.
    static func titles(_ candidates: [SeerrTitle], owned: Set<SeerrOwnedKey>) -> [SeerrMissingTitle] {
        var seen = Set<String>()
        var result: [SeerrMissingTitle] = []
        for candidate in candidates {
            guard !owned.contains(SeerrOwnedKey(kind: candidate.kind, tmdbId: candidate.tmdbId)) else { continue }
            switch candidate.mediaInfo?.status {
            case .partiallyAvailable, .available, .blocklisted: continue
            default: break
            }
            let entry = SeerrMissingTitle(title: candidate, badge: badge(candidate.mediaInfo))
            if seen.insert(entry.id).inserted { result.append(entry) }
        }
        return result
    }

    /// Deleted media shows « Demander » even if it still holds a pending
    /// request (Seerr would answer 409; rare).
    static func badge(_ info: SeerrMediaInfo?) -> SeerrBadge {
        guard let info, info.status != .deleted else { return .request }
        if let badge = badge(for: info.requests) { return badge }
        switch info.status {
        case .processing: return .processing
        case .pending: return .pending
        default: return .request
        }
    }

    /// Seasons the series lacks, each with its own badge. Season 0 only when
    /// `includeSpecials`. A season Seerr has available or partially is dropped.
    static func seasons(
        _ tv: SeerrTVDetails, ownedSeasonNumbers: Set<Int>, includeSpecials: Bool
    ) -> [SeerrMissingSeason] {
        let info = tv.mediaInfo
        var seen = Set<Int>()
        var result: [SeerrMissingSeason] = []
        for season in tv.seasons {
            let number = season.seasonNumber
            guard includeSpecials || number != 0,
                  !ownedSeasonNumbers.contains(number),
                  seen.insert(number).inserted else { continue }
            let seerrStatus = info?.seasons.first { $0.seasonNumber == number }?.status
            if seerrStatus == .available || seerrStatus == .partiallyAvailable { continue }
            let badge = info.flatMap { seasonBadge(for: $0.requests.filter { $0.seasons.contains(number) }) }
                ?? (seerrStatus == .processing ? .processing : .request)
            result.append(SeerrMissingSeason(seriesTmdbId: tv.tmdbId, seasonNumber: number, badge: badge))
        }
        return result
    }

    /// Per season: the latest request over all of them decides, and a COMPLETED one
    /// means no badge (Seerr completes approved and failed requests when a
    /// season becomes deleted, and accepts a new one); a FAILED latest request reads as processing (Seerr refuses a new
    /// request for it with 202).
    private static func seasonBadge(for requests: [SeerrRequestSummary]) -> SeerrBadge? {
        guard let latest = requests.max(by: { $0.id < $1.id }) else { return nil }
        switch latest.status {
        case .completed: return nil
        case .failed: return .processing
        default: return badge(for: [latest])
        }
    }

    /// The most recent request decides; a failed one says nothing.
    private static func badge(for requests: [SeerrRequestSummary]) -> SeerrBadge? {
        guard let latest = requests.max(by: { $0.id < $1.id }) else { return nil }
        switch latest.status {
        case .declined: return .declined
        case .pending: return .pending
        case .approved, .completed: return .processing
        case .failed: return nil
        }
    }
}
