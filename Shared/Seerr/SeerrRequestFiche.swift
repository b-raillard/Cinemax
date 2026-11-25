import Foundation
import CinemaxKit

/// The request fiche (« mini-fiche », owner's choice B, 2026-11-22): what its
/// hero, rating line and « Infos » grid print, from the card's `SeerrTitle`
/// and — once its lookup answered — the title's `SeerrTitleDetails`. Pure
/// apart from the localization reads; platform-neutral, so both test
/// bundles compile it.
enum SeerrRequestFiche {
    struct Fact: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// The genres the hero line names, at most.
    static let heroGenreLimit = 2

    /// « 2026 · 1h 49m · Romance, Comédie »: whatever is known, in that order.
    @MainActor
    static func heroLine(year: Int?, details: SeerrTitleDetails?, loc: LocalizationManager) -> String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let minutes = details?.runtimeMinutes { parts.append(loc.runtime(minutes: minutes)) }
        let genres = (details?.genres ?? []).prefix(heroGenreLimit)
        if !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// « 7,0 » and « TMDb · 81 votes », or nil without a rating.
    @MainActor
    static func rating(_ details: SeerrTitleDetails?, loc: LocalizationManager) -> (score: String, votes: String)? {
        guard let details, let average = details.voteAverage, let count = details.voteCount else { return nil }
        let votes = loc.localized(
            loc.pluralKey("seerr.fiche.votes", count), count.formatted(.number.locale(loc.locale)))
        return (loc.decimal(average), votes)
    }

    /// The « Infos » grid: who made it, when, how long, in what language,
    /// under what original title, and on which subscription service here.
    @MainActor
    static func facts(
        title: SeerrTitle, details: SeerrTitleDetails, streamingRegion: String?, loc: LocalizationManager
    ) -> [Fact] {
        let isMovie = title.kind == .movie
        var facts: [Fact] = []
        if !details.creators.isEmpty {
            facts.append(Fact(
                label: loc.localized(isMovie ? "seerr.fiche.directedBy" : "seerr.fiche.createdBy"),
                value: details.creators.prefix(2).joined(separator: ", ")))
        }
        if let date = releaseDate(details.releaseDate) {
            facts.append(Fact(
                label: loc.localized(isMovie ? "seerr.fiche.release" : "seerr.fiche.firstAired"),
                value: date.formatted(.dateTime.day().month(.abbreviated).year().locale(loc.locale))))
        }
        if let minutes = details.runtimeMinutes {
            facts.append(Fact(
                label: loc.localized(isMovie ? "seerr.fiche.runtime" : "seerr.fiche.episodeRuntime"),
                value: loc.runtime(minutes: minutes)))
        }
        if let code = details.originalLanguage,
           let name = loc.locale.localizedString(forLanguageCode: code), !name.isEmpty {
            facts.append(Fact(label: loc.localized("seerr.fiche.originalLanguage"), value: name.capitalized(with: loc.locale)))
        }
        if let original = details.originalTitle, original.compare(title.title, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
            facts.append(Fact(label: loc.localized("seerr.fiche.originalTitle"), value: original))
        }
        let services = providers(details, region: region(seerr: streamingRegion, device: loc.locale.region?.identifier))
        if !services.isEmpty {
            facts.append(Fact(label: loc.localized("seerr.fiche.streaming"), value: services.joined(separator: ", ")))
        }
        return facts
    }

    /// Seerr's own « streaming region » when its admin set one, else the device's.
    nonisolated static func region(seerr: String?, device: String?) -> String? {
        if let seerr, !seerr.isEmpty { return seerr.uppercased() }
        if let device, !device.isEmpty { return device.uppercased() }
        return nil
    }

    /// The region's subscription services, a plan of a service already named
    /// folded into it (« Netflix Standard with Ads » under « Netflix »), at most three.
    nonisolated static func providers(_ details: SeerrTitleDetails, region: String?) -> [String] {
        guard let region, let names = details.streamingProviders[region] else { return [] }
        var kept: [String] = []
        for name in names where !kept.contains(where: { name == $0 || name.hasPrefix($0 + " ") }) {
            kept.append(name)
        }
        return Array(kept.prefix(3))
    }

    /// The fiche's one read per opening — the title's `/movie` or `/tv` whole —,
    /// shared by the iOS sheet and the tvOS fiche. Never automatic
    /// (`isAutomatic: false`: a fiche the user opened asks even a Seerr that
    /// just failed). A failure, the deadline or an account change answer nil,
    /// and the fiche then shows what the card knew.
    @MainActor
    static func loadDetails(of title: SeerrTitle, session: SeerrSession) async -> SeerrTitleDetails? {
        let kind = title.kind
        let tmdbId = title.tmdbId
        let answer = await session.loadSection(isAutomatic: false) { client, credential in
            [try await client.titleDetails(kind: kind, tmdbId: tmdbId, credential)]
        }
        if case .loaded(let found)? = answer { return found.first }
        return nil
    }

    /// A TMDb image path through `SeerrImages` (Seerr's proxy when it caches
    /// images), nil without a signed-in Seerr.
    @MainActor
    static func imageURL(
        _ path: String?, _ build: (String?, URL, Bool) -> URL?, session: SeerrSession
    ) -> URL? {
        guard let base = session.client?.baseURL else { return nil }
        return build(path, base, session.publicSettings?.cacheImages ?? false)
    }

    /// `yyyy-MM-dd`, read in UTC — the day TMDb gives, whatever the time zone.
    nonisolated static func releaseDate(_ text: String?) -> Date? {
        guard let text, text.count == 10 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}
