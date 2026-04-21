import SwiftUI

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

    // MARK: - Helpers

    func localized(_ key: String) -> String {
        _ = _revision
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    func localized(_ key: String, _ args: CVarArg...) -> String {
        let format = localized(key)
        return String(format: format, arguments: args)
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
        return localized("home.remainingTime.minutes", minutes)
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

