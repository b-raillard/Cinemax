import SwiftUI
import JellyfinAPI
import CinemaxKit

@MainActor @Observable
final class LocalizationManager {

    @ObservationIgnored
    @AppStorage(SettingsKey.appLanguage) private var _languageCode: String = AppLanguage.deviceDefault

    private var _revision: Int = 0

    var languageCode: String {
        get {
            _ = _revision
            return _languageCode
        }
        set {
            _languageCode = newValue
            AppLanguage.recordUserChoice(newValue)
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

    /// The Apple TV variant of a key whose wording is about TOUCH (« tirez
    /// pour actualiser », « touchez le cœur »): `<key>.tv` on tvOS, the key
    /// itself elsewhere. Both tables carry both variants (audit §5, lot 9).
    nonisolated static func platformVariant(_ key: String) -> String {
        #if os(tvOS)
        key + ".tv"
        #else
        key
        #endif
    }

    /// Maps a thrown error to a localized, user-meaningful message. Keeps the
    /// cryptic SDK descriptions (e.g. `unacceptableStatusCode(401)`) out of the
    /// UI — callers should still log `error` raw for diagnostics. Detection is
    /// string-match on the same markers `JellyfinAPIClient` uses for 401s,
    /// since `Get`/`URLError` are only transitive deps.
    func userFacingMessage(for error: Error) -> String {
        if case JellyfinError.contentRestricted = error {
            return localized("detail.restricted.subtitle")
        }
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
    /// A work's running time: « 1h 33m » / « 1 Std. 33 Min. », « 30m » / « 30 Min. ».
    /// One source for the heroes AND the fiche — the heroes built « 1h 33m »
    /// by hand, so a German fiche read « 1 Std. 33 Min. » under a hero saying
    /// « 1h 33m » for the same film (recette 2026-10-02).
    func runtime(minutes: Int) -> String {
        minutes > 60
            ? localized("detail.runtime.hours", minutes / 60, minutes % 60)
            : localized("detail.runtime.minutes", minutes)
    }

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

// MARK: - App languages

/// The languages the app ships, in picker order, and the one an install
/// speaks. **Settled once, at the first launch of 2.3.1 or later**
/// (`settleStoredLanguage`), then always read from `SettingsKey.appLanguage`:
/// - a FRESH install starts in the device's first preferred language the app
///   ships, English when it ships none of them — until 2.3.1 every install
///   started in French, so a German- or English-speaking phone met a French
///   app and had to find the switch;
/// - an install UPGRADING from an earlier version keeps the French it has been
///   reading (it never stored a choice, French was the default) — it is
///   offered its device's language once, in « Quoi de neuf », rather than
///   switched under its feet.
enum AppLanguage {
    nonisolated static let supported = ["fr", "en", "de"]

    /// The first of `preferredLanguages` (BCP-47 tags, `"de-CH"`, `"en-US"`…)
    /// whose language the app ships, or `nil` when it ships none of them.
    nonisolated static func devicePreferred(preferredLanguages: [String]) -> String? {
        for tag in preferredLanguages {
            let code = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
            if supported.contains(code) { return code }
        }
        return nil
    }

    /// `devicePreferred`, English when the device speaks none of ours.
    nonisolated static func resolve(preferredLanguages: [String]) -> String {
        devicePreferred(preferredLanguages: preferredLanguages) ?? "en"
    }

    /// The device's default, read now — the fallback for an unset key.
    nonisolated static var deviceDefault: String {
        resolve(preferredLanguages: Locale.preferredLanguages)
    }

    /// What to write into an UNSET `appLanguage`, or `nil` to leave it alone.
    /// `isExistingInstall`: the install ran an earlier version (it has a
    /// « Quoi de neuf » stamp or finished the onboarding) — it has been reading
    /// French, the old default, and keeps it.
    nonisolated static func languageToSettle(
        stored: String?, isExistingInstall: Bool, preferredLanguages: [String]
    ) -> String? {
        guard stored == nil else { return nil }
        return isExistingInstall ? "fr" : resolve(preferredLanguages: preferredLanguages)
    }

    /// Writes the install's language once, BEFORE anything renders — called
    /// from `AppNavigation.init`. Writing it (rather than reading the device
    /// at every launch) is what makes the second launch of a fresh install
    /// indistinguishable from the first: by then it carries a « Quoi de neuf »
    /// stamp and would otherwise be taken for an upgrade. Then follows a
    /// language the SYSTEM changed since the last launch (`languageToAdopt`).
    ///
    /// Last, an app speaking another language than the system asks for gets
    /// that language written as its OWN (`ownLanguages == nil`: an upgrade
    /// kept French on an English device). Without it Réglages › JellyGlass ›
    /// Langue showed « English » checked while the app spoke French, and
    /// picking English there changed nothing (recette 2026-10-02). From then
    /// on iOS's per-app language prevails over the device's, as it does for
    /// any app with one: a device-language change no longer moves the app.
    nonisolated static func settleStoredLanguage(
        defaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages,
        ownLanguages: [String]? = Self.ownLanguages()
    ) {
        let lastSeen = defaults.string(forKey: SettingsKey.whatsNewLastSeenVersion) ?? ""
        let settled = languageToSettle(
            stored: defaults.string(forKey: SettingsKey.appLanguage),
            isExistingInstall: !lastSeen.isEmpty || defaults.bool(forKey: SettingsKey.onboardingSeen),
            preferredLanguages: preferredLanguages
        )
        if let settled { defaults.set(settled, forKey: SettingsKey.appLanguage) }

        let systemNow = devicePreferred(preferredLanguages: preferredLanguages)
        if let adopted = languageToAdopt(
            stored: defaults.string(forKey: SettingsKey.appLanguage),
            systemSeen: defaults.string(forKey: SettingsKey.appLanguageSystemSeen),
            systemNow: systemNow
        ) {
            defaults.set(adopted, forKey: SettingsKey.appLanguage)
        }
        defaults.set(systemNow ?? "", forKey: SettingsKey.appLanguageSystemSeen)

        if ownLanguages == nil, let stored = defaults.string(forKey: SettingsKey.appLanguage), stored != systemNow {
            recordUserChoice(stored, defaults: defaults)
        }
    }

    /// This app's OWN language list — Réglages › JellyGlass › Langue, which
    /// iOS stores as `AppleLanguages` in the app's domain — or `nil` when it
    /// has none and follows the device. Read from the app's persistent domain
    /// alone: `UserDefaults.object(forKey:)` would fall through to the
    /// device's global list and never answer `nil`.
    nonisolated static func ownLanguages(defaults: UserDefaults = .standard) -> [String]? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return defaults.persistentDomain(forName: bundleID)?[appleLanguagesKey] as? [String]
    }

    /// The DEVICE's language list, without this app's own — what « Quoi de
    /// neuf » offers. `Locale.preferredLanguages` starts with the app's own
    /// language once one is set (`settleStoredLanguage` mirrors it), which
    /// would hide the device's language from the offer. Measured in the
    /// simulator with an own `["fr"]`: `CopyAppValue(AnyApplication)` answers
    /// the device's `["en-US", "fr-US", "it-CH"]`; `CFPreferencesCopyValue`
    /// (any host), the global `persistentDomain` and a global-domain suite
    /// all answer `nil` from the sandbox.
    nonisolated static func deviceLanguages() -> [String] {
        CFPreferencesCopyAppValue(appleLanguagesKey as CFString, kCFPreferencesAnyApplication) as? [String]
            ?? Locale.preferredLanguages
    }

    /// The language the system started asking for since the last launch — the
    /// app's own page in the iOS Settings (Réglages → JellyGlass → Langue,
    /// which iOS stores as this app's `AppleLanguages`) or the device's
    /// language — or `nil` to keep the stored one. `systemSeen` is what the
    /// system asked for at the previous launch (`""` = none of ours); `nil`
    /// (never recorded: the first launch of 2.3.2+) only records, so an
    /// upgrade is never switched behind its back — « Quoi de neuf » offers it.
    nonisolated static func languageToAdopt(stored: String?, systemSeen: String?, systemNow: String?) -> String? {
        guard let systemSeen, let systemNow, systemNow != systemSeen, systemNow != stored else { return nil }
        return systemNow
    }

    /// A language picked IN the app is mirrored into the system's per-app
    /// language, so Réglages → JellyGlass → Langue shows it (and the system's
    /// own prompts follow from the next launch), and recorded as seen, so the
    /// next launch does not read it as a system change.
    nonisolated static func recordUserChoice(_ code: String, defaults: UserDefaults = .standard) {
        defaults.set([code], forKey: appleLanguagesKey)
        defaults.set(code, forKey: SettingsKey.appLanguageSystemSeen)
    }

    /// The system's own key for an app's language list.
    nonisolated static let appleLanguagesKey = "AppleLanguages"

    /// The device language worth OFFERING: shipped, and not the one the app
    /// already speaks. `nil` = nothing to offer.
    nonisolated static func offer(current: String, preferredLanguages: [String]) -> String? {
        guard let device = devicePreferred(preferredLanguages: preferredLanguages), device != current else { return nil }
        return device
    }

    /// The language's own name, as the pickers print it (« Deutsch »).
    nonisolated static func nameKey(_ code: String) -> String {
        switch code {
        case "fr": "settings.language.french"
        case "de": "settings.language.german"
        default: "settings.language.english"
        }
    }

    /// The next language in picker order, wrapping — the tvOS row's press.
    nonisolated static func next(after code: String, step: Int = 1) -> String {
        let index = supported.firstIndex(of: code) ?? 0
        let count = supported.count
        return supported[((index + step) % count + count) % count]
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

