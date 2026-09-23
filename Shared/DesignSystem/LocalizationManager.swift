import SwiftUI
import JellyfinAPI

@MainActor @Observable
final class LocalizationManager {

    @ObservationIgnored
    @AppStorage(SettingsKey.appLanguage) private var _languageCode: String = SettingsKey.Default.appLanguage

    private var _revision: Int = 0

    var languageCode: String {
        get {
            _ = _revision
            return _languageCode
        }
        set {
            _languageCode = newValue
            _bundle = nil
            _revision += 1
        }
    }

    // MARK: - Bundle

    private var _bundle: Bundle?

    var bundle: Bundle {
        _ = _revision
        if let cached = _bundle { return cached }
        let resolved = Bundle.localizedBundle(for: _languageCode)
        _bundle = resolved
        return resolved
    }

    // MARK: - Locale

    /// The APP's language as a `Locale`, keeping the device's region (so a
    /// French app on a Belgian phone still formats like Belgium). Injected at
    /// the root as SwiftUI's `\.locale`, and handed to every `FormatStyle`
    /// the app builds itself: dates, relative times and decimals followed the
    /// DEVICE language before, so an English phone printed « Sep 22 » and
    /// « 7.5 » inside a French app (audit 2026-09-22, Q7).
    var locale: Locale {
        _ = _revision
        return Self.locale(languageCode: _languageCode, region: Locale.current.region?.identifier)
    }

    nonisolated static func locale(languageCode: String, region: String?) -> Locale {
        guard let region, !region.isEmpty else { return Locale(identifier: languageCode) }
        return Locale(identifier: "\(languageCode)_\(region)")
    }

    /// A rating or any one-decimal figure, with the app language's decimal
    /// separator (« 7,5 » in French) — `String(format: "%.1f")` always wrote a
    /// dot. Keyed on the LANGUAGE alone, not on `locale`: with the device's
    /// region attached, a French app on a US-region phone (`fr_US`) still
    /// printed « 5.9 » (recette 2026-09-23). Dates keep `locale`, where the
    /// region legitimately decides the order of day and month.
    func decimal<T: BinaryFloatingPoint>(_ value: T, fractionDigits: Int = 1) -> String {
        Self.decimal(Double(value), languageCode: languageCode, fractionDigits: fractionDigits)
    }

    nonisolated static func decimal(_ value: Double, languageCode: String, fractionDigits: Int = 1) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .locale(Locale(identifier: languageCode))
        )
    }

    // MARK: - Helpers

    func localized(_ key: String) -> String {
        _ = _revision
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    func localized(_ key: String, _ args: CVarArg...) -> String {
        let format = localized(key)
        return String(format: format, arguments: args)
    }

    /// Maps a thrown error to a localized, user-meaningful message. Keeps the
    /// cryptic SDK descriptions (e.g. `unacceptableStatusCode(401)`) out of the
    /// UI — callers should still log `error` raw for diagnostics. Detection is
    /// string-match on the same markers `JellyfinAPIClient` uses for 401s,
    /// since `Get`/`URLError` are only transitive deps.
    func userFacingMessage(for error: Error) -> String {
        let raw = (error as NSError)
        if raw.domain == NSURLErrorDomain {
            switch raw.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorTimedOut,
                 NSURLErrorDNSLookupFailed:
                return localized("error.network")
            case NSURLErrorUserAuthenticationRequired:
                return localized("error.sessionExpired")
            default:
                return localized("error.generic")
            }
        }
        let desc = String(describing: error)
        if desc.contains("(401)") || desc.contains("Unauthorized") {
            return localized("error.sessionExpired")
        }
        return localized("error.generic")
    }

    // MARK: - Plurals
    //
    // Without a `.stringsdict` (a new resource file would need an xcodegen run),
    // every count goes through ONE rule and a `<key>.one` sibling of the plural
    // key. The rule is the one the two languages actually follow, which several
    // helpers below used to get wrong in French: 0 is SINGULAR there (« 0 film »,
    // « 0 résultat »), and only 1 is in English.

    /// Whether `count` takes the singular form in `languageCode`.
    nonisolated static func usesSingular(_ count: Int, languageCode: String) -> Bool {
        languageCode.hasPrefix("fr") ? abs(count) < 2 : abs(count) == 1
    }

    /// The `<key>.one` sibling when `count` is singular here, else `key`.
    func pluralKey(_ key: String, _ count: Int) -> String {
        Self.usesSingular(count, languageCode: languageCode) ? key + ".one" : key
    }

    /// `localized(pluralKey(key, count), count)` — the common shape, a count
    /// as the string's only argument.
    func counted(_ key: String, _ count: Int) -> String {
        localized(pluralKey(key, count), count)
    }

    /// "1 élément" / "3 éléments" — the shared count for a folder's contents:
    /// a library view, a collection, a playlist. Replaced two strings that each
    /// got the singular wrong in their own way ("1 éléments" and "1 élément(s)").
    func itemCount(_ count: Int) -> String {
        counted("library.itemCount", count)
    }

    /// "1 titre" / "3 titres" — a collection can legitimately hold a single
    /// film, and the shared plural form would have read "1 titres".
    func collectionCount(_ count: Int) -> String {
        counted("detail.collection.count", count)
    }

    /// "1 résultat" / "12 résultats" — the search result count. Its own helper
    /// rather than `itemCount`: a search returns *results*, and French makes
    /// the two different words.
    func searchResultCount(_ count: Int) -> String {
        counted("search.resultCount", count)
    }

    /// Formats a remaining duration using the `home.remainingTime.*` keys.
    /// Centralises the `>= 60` branching so call sites don't reimplement it.
    /// The underlying `.strings` keep their current masculine-plural form on
    /// `fr`; when a third language is added, swap in a `.stringsdict` behind
    /// this helper without touching call sites.
    func remainingTime(minutes: Int) -> String {
        if minutes >= 60 {
            return localized("home.remainingTime.hours", minutes / 60, minutes % 60)
        }
        return counted("home.remainingTime.minutes", minutes)
    }

    /// "1 saison" / "3 saisons" — the fiche's metadata line printed
    /// « 1 saisons » while the library hero, two taps away, already said
    /// « 1 saison » through the `tvShows.season` key this reuses.
    func seasonCount(_ count: Int) -> String {
        Self.usesSingular(count, languageCode: languageCode)
            ? localized("tvShows.season", count)
            : localized("tvShows.seasonsPlural", count)
    }

    /// Human label for a Jellyfin item kind on a card subtitle (« Film »,
    /// « Série »…). Cards printed `BaseItemKind.rawValue`, i.e. the wire enum
    /// « Movie » / « Series » in English whatever the app language. A kind
    /// with no label of its own answers `nil` and is left out rather than
    /// printed raw.
    func itemKind(_ kind: BaseItemKind) -> String? {
        Self.itemKindKey(kind).map { localized($0) }
    }

    nonisolated static func itemKindKey(_ kind: BaseItemKind) -> String? {
        switch kind {
        case .movie: "item.kind.movie"
        case .series: "item.kind.series"
        case .episode: "item.kind.episode"
        case .season: "item.kind.season"
        case .boxSet: "item.kind.collection"
        case .playlist: "item.kind.playlist"
        case .video, .musicVideo: "item.kind.video"
        default: nil
        }
    }

    /// "1 essai" / "3 essais" left before the parental lock's next back-off
    /// window. Only called with `count > 0` — at zero the window is already open
    /// and `parentalLockThrottle` is what the user needs to read.
    func parentalLockAttemptsLeft(_ count: Int) -> String {
        count <= 1
            ? localized("privacy.lock.wrong.remainingOne")
            : localized("privacy.lock.wrong.remainingMany", count)
    }

    /// "Réessayez dans 30 s" / "… dans 5 min". Rounds minutes UP so the message
    /// never promises a retry that is still a few seconds away, and clamps to at
    /// least 1 s so a window closing this instant doesn't print "0 s".
    func parentalLockThrottle(secondsRemaining seconds: Int) -> String {
        if seconds >= 60 {
            return localized("privacy.lock.throttled.minutes", (seconds + 59) / 60)
        }
        return localized("privacy.lock.throttled.seconds", max(1, seconds))
    }
}

// MARK: - Bundle Extension

extension Bundle {
    static func localizedBundle(for languageCode: String) -> Bundle {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return Bundle.main
        }
        return bundle
    }
}

