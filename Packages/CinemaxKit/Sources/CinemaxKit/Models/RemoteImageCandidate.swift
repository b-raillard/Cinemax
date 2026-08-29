import Foundation

/// One artwork option offered by a metadata provider (TMDb, Fanart…) for an
/// item, as surfaced by `GET /Items/{id}/RemoteImages`.
///
/// Deliberately a **scalars-only value type**, not the SDK's `RemoteImageInfo`:
/// the ranking below is `nonisolated` and the picker hands these across the
/// `@MainActor` boundary, which is the same discipline `CardPlayTarget` and
/// `LibraryAPI.fetchUserData` follow — a non-`Sendable` SDK type crossing that
/// boundary is a region transfer of a value the main actor still holds.
public struct RemoteImageCandidate: Sendable, Hashable, Identifiable {

    /// Full-size image URL on the provider's CDN. Doubles as the identity: the
    /// server addresses a download by this exact string
    /// (`downloadRemoteImage(imageURL:)`), so two entries sharing it are the
    /// same artwork however else they differ.
    public let url: String

    /// Smaller preview the grid actually loads. Absent on some providers, in
    /// which case the caller falls back to `url`.
    public let thumbnailURL: String?

    public let providerName: String?

    /// ISO-ish language code the artwork's text is in. `nil` or empty means
    /// **textless** — artwork with no burned-in title, which is the neutral
    /// choice rather than a missing value.
    public let language: String?

    public let width: Int?
    public let height: Int?
    public let communityRating: Double?
    public let voteCount: Int?

    public var id: String { url }

    public init(
        url: String,
        thumbnailURL: String? = nil,
        providerName: String? = nil,
        language: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        communityRating: Double? = nil,
        voteCount: Int? = nil
    ) {
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.providerName = providerName
        self.language = language
        self.width = width
        self.height = height
        self.communityRating = communityRating
        self.voteCount = voteCount
    }

    /// What the grid loads. Providers that omit a thumbnail still render.
    public var previewURL: String { thumbnailURL ?? url }

    /// `1920 × 1080`, or `nil` when the provider reported no dimensions.
    public var resolutionLabel: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width) × \(height)"
    }

    /// True when the artwork carries no burned-in text.
    public var isTextless: Bool {
        (language ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Ordering for the remote-artwork picker.
///
/// Pure and `nonisolated` so it is unit-testable without a server, mirroring
/// `MediaSourceQuality` — and like it, the order is **total** (it falls through
/// to `url`), so the grid can't reshuffle under the user's finger between two
/// loads of the same data.
public enum RemoteImageCatalog {

    /// Language tiers. The preferred language leads, textless art comes next —
    /// it is usable in any locale, which a third language is not — and
    /// everything else follows.
    private static func languageTier(_ candidate: RemoteImageCandidate, preferred: String?) -> Int {
        if candidate.isTextless { return 1 }
        guard let preferred = normalize(preferred), let language = normalize(candidate.language) else { return 2 }
        return language == preferred ? 0 : 2
    }

    /// Compares the primary subtag only, case-insensitively: providers report
    /// `fr`, `fr-FR` and `FR` for the same thing, and the app's own language is
    /// a bare `fr` / `en`.
    private static func normalize(_ code: String?) -> String? {
        guard let code else { return nil }
        let primary = code.split(separator: "-").first.map(String.init) ?? code
        let trimmed = primary.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func pixels(_ candidate: RemoteImageCandidate) -> Int {
        guard let width = candidate.width, let height = candidate.height else { return 0 }
        return max(0, width) * max(0, height)
    }

    /// De-duplicates by `url` (first occurrence wins) and orders by:
    /// language tier → community rating → vote count → resolution → url.
    ///
    /// Entries with a blank `url` are dropped: the download endpoint addresses
    /// artwork by that string, so one without it can never be applied and would
    /// be a tile that silently does nothing.
    public static func rank(
        _ candidates: [RemoteImageCandidate],
        preferredLanguage: String?
    ) -> [RemoteImageCandidate] {
        var seen = Set<String>()
        let usable = candidates.filter { candidate in
            let url = candidate.url.trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty else { return false }
            return seen.insert(candidate.url).inserted
        }

        return usable.sorted { lhs, rhs in
            let lhsTier = languageTier(lhs, preferred: preferredLanguage)
            let rhsTier = languageTier(rhs, preferred: preferredLanguage)
            if lhsTier != rhsTier { return lhsTier < rhsTier }

            let lhsRating = lhs.communityRating ?? -1
            let rhsRating = rhs.communityRating ?? -1
            if lhsRating != rhsRating { return lhsRating > rhsRating }

            let lhsVotes = lhs.voteCount ?? 0
            let rhsVotes = rhs.voteCount ?? 0
            if lhsVotes != rhsVotes { return lhsVotes > rhsVotes }

            let lhsPixels = pixels(lhs)
            let rhsPixels = pixels(rhs)
            if lhsPixels != rhsPixels { return lhsPixels > rhsPixels }

            return lhs.url < rhs.url
        }
    }
}
