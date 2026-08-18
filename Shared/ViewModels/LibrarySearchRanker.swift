import Foundation
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Turns raw user input into a ranked set of library items.
///
/// Extracted out of `SearchViewModel` so the search screen and the App Intents
/// entity query score candidates through the *same* path. That shared path is
/// what makes resolving a spoken title viable without a local index: the
/// normalization below folds diacritics and collapses punctuation, which is
/// precisely what dictation drops — "Mission Impossible" has to reach
/// "Mission : Impossible", and "Amelie" has to reach "Amélie".
///
/// Pure and non-isolated throughout, so the per-word fetches run concurrently
/// off the main actor and every primitive is directly unit-testable.
enum LibrarySearchRanker {

    // MARK: Input hygiene

    /// Defensive cap on search input — anything beyond this is almost
    /// certainly noise (paste accident, malformed dictation), and Jellyfin's
    /// search endpoint doesn't benefit from longer terms. Also bounds the
    /// payload sent in the URL.
    static let maxQueryLength = 200

    /// Person search asks the server wide and filters locally, but the row only
    /// shows the best few — it's a secondary affordance next to the title grid,
    /// not the main answer.
    static let personFetchLimit = 30
    static let personRowLimit = 10

    /// FR/EN articles & conjunctions excluded from per-word search fetches and
    /// word-presence scoring (they'd match nearly everything).
    static let stopWords: Set<String> = [
        "the", "a", "an", "of", "and", "or", "to", "in", "on",
        "le", "la", "les", "un", "une", "des", "du", "de", "et", "ou", "au", "aux"
    ]

    /// Trims, strips control/illegal scalars, and caps length. Applies to typed
    /// input and to a dictated or Shortcuts-supplied term alike — both are
    /// untrusted.
    static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let stripped = trimmed.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(stripped))
        if cleaned.count > maxQueryLength {
            return String(cleaned.prefix(maxQueryLength))
        }
        return cleaned
    }

    // MARK: Matching primitives

    /// Lowercases, strips diacritics, and collapses any run of non-alphanumerics to
    /// a single space so punctuation can't block matches: "Mission : Impossible"
    /// and "mission impossible" normalize to the same string.
    static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        var out = ""
        out.reserveCapacity(folded.count)
        var lastWasSpace = true   // seeded true so leading separators are trimmed
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// The discriminating words of an **already-normalized** query: stop words and
    /// single characters dropped, original order preserved. Feeding these to the
    /// per-word fetches and to the word-presence tiers keeps both meaningful —
    /// otherwise "the"/"le"/"de" alone match hundreds of titles.
    static func significantWords(in normalizedQuery: String) -> [String] {
        normalizedQuery
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
    }

    /// Weighted relevance of one title against the query. 0 = no match (filtered out).
    /// `fullQuery` and `queryWords` are expected pre-normalized.
    static func score(title: String, fullQuery: String, queryWords: [String]) -> Double {
        let normalized = normalize(title)
        guard !normalized.isEmpty, !fullQuery.isEmpty else { return 0 }

        // Tier 1 — full query appears as a contiguous run.
        if normalized.contains(fullQuery) {
            var score = 1000.0
            if normalized == fullQuery { score += 500 }                 // exact title
            else if normalized.hasPrefix(fullQuery) { score += 250 }     // title starts with query
            return score - Double(normalized.count) * 0.5               // prefer tighter titles
        }

        guard !queryWords.isEmpty else { return 0 }
        // Substring test only: `normalized` is its own words joined by single
        // spaces, so a whole-word hit is *always* also a substring hit — a
        // word-set membership check could never accept anything this doesn't.
        // Building that set cost a split + a String allocation + a hash per
        // title word, on every candidate and for both title fields, i.e. the
        // per-keystroke bulk of ranking, for a branch that never changed the
        // answer.
        let present = queryWords.filter { normalized.contains($0) }
        guard !present.isEmpty else { return 0 }

        // Tier 2 — every query word present but separated; Tier 3 — only some.
        if present.count == queryWords.count {
            return 500 - Double(normalized.count) * 0.5
        }
        return 100 * (Double(present.count) / Double(queryWords.count))
    }

    // MARK: Ranked fetch

    /// Fetches a permissive candidate set and ranks it locally so punctuation and
    /// word order don't drop relevant items. Jellyfin's `searchTerm` is contiguous
    /// and punctuation-sensitive — e.g. "Mission Impossible" misses
    /// "Mission : Impossible". We query the full phrase AND each significant word,
    /// union the candidates, then score by:
    ///   • full query as a contiguous run in the title  (strongest)
    ///   • every query word present but separated / reordered
    ///   • only some query words present                (weakest)
    ///
    /// `failed` distinguishes "couldn't reach the server" from a legitimate
    /// zero-match, which callers need in order to say the right thing.
    static func rank(
        query: String,
        userId: String,
        includeItemTypes: [BaseItemKind],
        api: any LibraryAPI
    ) async -> (items: [BaseItemDto], failed: Bool) {
        let normalizedQuery = normalize(query)
        let words = significantWords(in: normalizedQuery)

        // Always fetch the full phrase, plus up to the first 4 significant words.
        // Each term is a separate concurrent server request, so an unbounded list
        // turns a long query into a fan-out spike (a 7-word title = 8 requests per
        // debounced keystroke). The leading words are the most distinctive, and
        // scoring below still ranks against the *full* `words` set — capping only
        // the fetch, not the relevance. 1 + 4 = 5 requests worst case.
        var terms: [String] = [query]
        if words.count > 1 { terms.append(contentsOf: words.prefix(4)) }
        let uniqueTerms = Array(Set(terms))

        // Each task returns nil when its fetch threw. If EVERY term fetch throws
        // (server unreachable / dropped mid-query) we surface a failure.
        var candidates: [String: BaseItemDto] = [:]
        var anySucceeded = false
        await withTaskGroup(of: [BaseItemDto]?.self) { group in
            for term in uniqueTerms {
                group.addTask {
                    try? await api.searchItems(userId: userId, searchTerm: term, includeItemTypes: includeItemTypes, limit: 30)
                }
            }
            for await result in group {
                guard let items = result else { continue }
                anySucceeded = true
                for item in items where item.id != nil {
                    candidates[item.id!] = item
                }
            }
        }

        let failed = !uniqueTerms.isEmpty && !anySucceeded

        let scored = candidates.values.compactMap { item -> (item: BaseItemDto, score: Double)? in
            // Score against the display title AND the original-language title,
            // keeping the better of the two — a French library holding an
            // English original (or the reverse) must match either spoken form.
            let best = max(
                Self.score(title: item.name ?? "", fullQuery: normalizedQuery, queryWords: words),
                Self.score(title: item.originalTitle ?? "", fullQuery: normalizedQuery, queryWords: words)
            )
            return best > 0 ? (item, best) : nil
        }
        return (scored.sorted { $0.score > $1.score }.map(\.item), failed)
    }

    /// Persons matching the query, ordered for display in the search screen's
    /// person row.
    ///
    /// Unlike `rank`, this issues a **single** server call. The per-word fan-out
    /// exists because Jellyfin's `searchTerm` is contiguous and
    /// punctuation-sensitive, which breaks titles ("Mission Impossible" misses
    /// "Mission : Impossible"). Person names don't have that problem — the
    /// server's `contains` already finds "Cillian Murphy" from "murphy" — so the
    /// local scoring here only decides the display order.
    ///
    /// A failure is swallowed and returns empty: an absent row IS the degraded
    /// mode, and the main result (the titles) must not suffer for it.
    static func rankPersons(
        query: String,
        userId: String,
        api: any LibraryAPI
    ) async -> [BaseItemDto] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }
        let words = significantWords(in: normalizedQuery)

        guard let people = try? await api.searchPersons(
            userId: userId, searchTerm: query, limit: personFetchLimit
        ) else { return [] }

        let scored = people.compactMap { person -> (item: BaseItemDto, score: Double)? in
            let value = Self.score(title: person.name ?? "", fullQuery: normalizedQuery, queryWords: words)
            return value > 0 ? (person, value) : nil
        }
        return scored
            .sorted { $0.score > $1.score }
            .prefix(personRowLimit)
            .map(\.item)
    }
}
