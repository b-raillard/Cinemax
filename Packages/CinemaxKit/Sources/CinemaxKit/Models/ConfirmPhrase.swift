import Foundation

/// Comparison rule for the type-to-confirm phrase guarding irreversible admin
/// actions (`DestructiveConfirmSheet` — delete an item, delete a user).
///
/// **Why this is not a `caseInsensitiveCompare`.** iOS rewrites the straight
/// apostrophe the user presses into a typographic one as they type (`'` → `’`,
/// the keyboard's smart-punctuation substitution, which `.autocorrectionDisabled()`
/// does **not** turn off). So a title the server spells `L'Odyssée` is typed as
/// `L’Odyssée`, the raw compare fails, and the confirm button stays disabled for
/// ever — with nothing on screen to say why, and the two apostrophes a few
/// pixels apart. Every title carrying an apostrophe was undeletable, which in a
/// French library is a large share of them.
///
/// The hazard runs in both directions (a title stored *with* a typographic
/// apostrophe can only be typed with a straight one) and is not limited to
/// quotes: French metadata routinely carries a narrow no-break space before a
/// colon — « Mission : Impossible » — which no keyboard produces.
///
/// So both sides are folded before comparison: quote and dash forms normalised
/// to their ASCII spelling, whitespace runs collapsed to a single space, then
/// compared case- and diacritic-insensitively. The friction the sheet exists to
/// create is untouched — the user still has to type the whole title out. What
/// it no longer demands is that they reproduce punctuation they cannot see and,
/// on a keyboard layout that does not offer it, cannot enter.
public enum ConfirmPhrase {

    /// True when `typed` confirms `required`.
    ///
    /// A `required` phrase that normalises to nothing (an untitled item) can
    /// never be confirmed: accepting an empty field as assent to an
    /// irreversible action is the one outcome worse than refusing a legitimate
    /// delete.
    public static func matches(typed: String, required: String) -> Bool {
        let target = normalize(required)
        guard !target.isEmpty else { return false }
        return normalize(typed).compare(
            target,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        ) == .orderedSame
    }

    /// Folds the punctuation and whitespace forms that a metadata provider, a
    /// keyboard and a user can each spell differently for the same character.
    /// Case and diacritics are deliberately left alone here — `matches` folds
    /// those through `compare(options:)`, which knows the Unicode rules.
    public static func normalize(_ raw: String) -> String {
        var folded = ""
        folded.reserveCapacity(raw.count)
        // Held back rather than appended, so a leading run is dropped and a
        // trailing one is never emitted at all.
        var pendingSpace = false

        for character in raw {
            if character.isWhitespace {
                pendingSpace = !folded.isEmpty
                continue
            }
            if pendingSpace {
                folded.append(" ")
                pendingSpace = false
            }
            folded.append(equivalents[character] ?? character)
        }
        return folded
    }

    /// Typographic forms mapped onto the ASCII character a keyboard produces.
    /// Scoped to quotes and dashes on purpose: those are the ones a provider
    /// and a keyboard disagree about. Anything else is left as written.
    private static let equivalents: [Character: Character] = [
        // Single quotes / apostrophes
        "\u{2018}": "'",  // ' left single quotation mark
        "\u{2019}": "'",  // ' right single quotation mark — the smart-quote culprit
        "\u{201A}": "'",  // ‚ single low-9 quotation mark
        "\u{201B}": "'",  // ‛ single high-reversed-9 quotation mark
        "\u{2032}": "'",  // ′ prime
        "\u{00B4}": "'",  // ´ acute accent used as an apostrophe
        "\u{0060}": "'",  // ` grave accent used as an apostrophe
        "\u{FF07}": "'",  // ＇ fullwidth apostrophe
        // Double quotes
        "\u{201C}": "\"", // " left double quotation mark
        "\u{201D}": "\"", // " right double quotation mark
        "\u{201E}": "\"", // „ double low-9 quotation mark
        "\u{201F}": "\"", // ‟ double high-reversed-9 quotation mark
        "\u{2033}": "\"", // ″ double prime
        "\u{FF02}": "\"", // ＂ fullwidth quotation mark
        // Dashes
        "\u{2010}": "-",  // ‐ hyphen
        "\u{2011}": "-",  // ‑ non-breaking hyphen
        "\u{2012}": "-",  // ‒ figure dash
        "\u{2013}": "-",  // – en dash
        "\u{2014}": "-",  // — em dash
        "\u{2015}": "-",  // ― horizontal bar
        "\u{2212}": "-",  // − minus sign
        "\u{FF0D}": "-"   // － fullwidth hyphen-minus
    ]
}
