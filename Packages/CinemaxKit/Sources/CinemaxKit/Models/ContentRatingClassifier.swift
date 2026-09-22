import Foundation

/// Maps Jellyfin's free-form `officialRating` strings onto a numeric age threshold.
///
/// Jellyfin stores per-item ratings as the raw code published by each region's
/// board (MPAA, TV, BBFC, CSA, …). The Privacy & Security screen expresses the
/// user's choice as a **maximum** content age (10+, 12+, 14+, 16+, 18+) — items
/// rated *at or below* that age pass; more mature titles are hidden. We need
/// a map from rating code → age to both:
///   - pick the single `maxOfficialRating` string to send to `/Items` queries
///     that support server-side filtering,
///   - and filter items client-side for endpoints that don't (`/Users/{id}/Resume`,
///     `/Users/{id}/Items/Latest`, similar, next-up, episodes, search).
///
/// Items whose rating is unknown or missing pass through — episode DTOs
/// frequently inherit their rating from the series and arrive `nil`, so
/// filtering on missing data would wipe most catalogues.
public enum ContentRatingClassifier {

    /// Canonical age-for-rating table. Covers MPAA, US TV, UK BBFC, French CSA,
    /// and a few common aliases. Lookup is case-insensitive.
    private static let ageMap: [String: Int] = [
        // MPAA (US film)
        "G": 0, "PG": 10, "PG-13": 13, "R": 17, "NC-17": 18,
        // US TV
        "TV-Y": 0, "TV-Y7": 7, "TV-G": 0, "TV-PG": 10, "TV-14": 14, "TV-MA": 17,
        // UK BBFC
        "U": 0, "12": 12, "12A": 12, "15": 15, "18": 18,
        // French CSA
        "-10": 10, "-12": 12, "-16": 16, "-18": 18,
        "TOUS PUBLICS": 0,
        // German FSK (common)
        "FSK-0": 0, "FSK-6": 6, "FSK-12": 12, "FSK-16": 16, "FSK-18": 18,
    ]

    /// Returns the age threshold carried by the given Jellyfin `officialRating`
    /// string. Falls back to `0` (= permissive) for unknown codes — see the
    /// type-level doc for why unrated content is not hidden by default.
    public static func age(forRating rating: String?) -> Int {
        guard let rating else { return 0 }
        let key = rating.trimmingCharacters(in: .whitespaces).uppercased()
        return ageMap[key] ?? 0
    }

    /// Returns `true` when `rating`'s age is at or below `maxAge`. `maxAge == 0`
    /// disables filtering (everything passes). Unrated items also pass — see
    /// the type-level doc for why.
    public static func passes(rating: String?, maxAge: Int) -> Bool {
        guard maxAge > 0 else { return true }
        return age(forRating: rating) <= maxAge
    }

    /// The `maxOfficialRating` to send on server-side `/Items` queries for a
    /// user-selected maximum content age: **the age itself, as an integer
    /// string** (`"12"`), or `nil` when `maxAge <= 0` (no filter).
    ///
    /// Every supported server (10.9, 10.10, 10.11, 12.0 — verified in
    /// `LocalizationManager.GetRatingLevel` / `GetRatingScore`) parses an
    /// integer rating straight into that age before any country table is
    /// consulted, so this is exact everywhere. The US codes this used to send
    /// were not: 12 → `PG-13` and 16 → `TV-MA` score 13 and 17 on 10.10+, so an
    /// over-the-ceiling title reached the library, search and Siri while Home
    /// (filtered locally) hid it; and on 10.9, whose table scores `TV-PG` at
    /// 13, even the 10+ ceiling let 13-rated titles through.
    public static func maxOfficialRatingCode(forAge maxAge: Int) -> String? {
        maxAge > 0 ? String(maxAge) : nil
    }
}
