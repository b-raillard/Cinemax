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
    /// The season's own poster (Seerr's `/tv/{id}`); nil ⇒ the bare outline.
    var posterPath: String?
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

extension SeerrSession {
    /// A TMDb poster path as an image URL on this session's Seerr — its image
    /// proxy when Seerr caches images; nil without a client or a path.
    func posterURL(_ path: String?) -> URL? {
        guard let base = client?.baseURL else { return nil }
        return SeerrImages.posterURL(path: path, seerrBase: base, cacheImages: publicSettings?.cacheImages ?? false)
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

    /// The TMDb collection (saga) the item names: `TmdbCollection` — a film's
    /// saga, or the BoxSet built from it — matched case-insensitively. On a
    /// BoxSet only, `Tmdb` counts too: a box set's TMDb id can only be a
    /// collection's, whereas a film's `Tmdb` is the FILM. Non-numeric ⇒ ignored.
    static func tmdbCollectionId(of item: BaseItemDto) -> Int? {
        func provider(_ key: String) -> Int? {
            item.providerIDs?.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }.flatMap { Int($0.value) }
        }
        if let id = provider("TmdbCollection") { return id }
        return item.type == .boxSet ? provider("Tmdb") : nil
    }

    /// The saga's films the library lacks (`titles`), in release order — the
    /// one order a saga has, the owned row's too; same year ⇒ Seerr's order.
    static func saga(_ collection: SeerrCollection, owned: Set<SeerrOwnedKey>) -> [SeerrMissingTitle] {
        titles(collection.parts, owned: owned).enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element.title.year ?? .max, rhs.element.title.year ?? .max)
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The person's TMDb credits an actor page offers: the cast, and the crew
    /// too only when the person is KNOWN to be primarily crew
    /// (`knownForDepartment` present, non-empty, other than « Acting »; an
    /// unknown department ⇒ cast only, fail closed). One entry per title —
    /// kind and id, a film and a series may share a number — in Seerr's order.
    static func creditTitles(_ credits: SeerrCombinedCredits, person: SeerrPerson) -> [SeerrTitle] {
        let department = person.knownForDepartment ?? ""
        let primarilyCrew = !department.isEmpty && department != "Acting"
        let candidates = primarilyCrew ? credits.cast + credits.crew : credits.cast
        var seen = Set<SeerrOwnedKey>()
        return candidates.filter { seen.insert(SeerrOwnedKey(kind: $0.kind, tmdbId: $0.tmdbId)).inserted }
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
            result.append(SeerrMissingSeason(
                seriesTmdbId: tv.tmdbId, seasonNumber: number, badge: badge, posterPath: season.posterPath))
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
