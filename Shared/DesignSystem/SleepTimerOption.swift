import Foundation

/// User-selectable sleep timer duration. Stored as minutes via `@AppStorage("sleepTimerDefaultMinutes")`.
///
/// A value of `0` means disabled. Non-zero values schedule a timer at playback start that
/// pauses the player and prompts "Still watching?" when it fires.
enum SleepTimerOption: Int, CaseIterable, Identifiable {
    case disabled = 0
    case fifteen  = 15
    case thirty   = 30
    case fortyFive = 45
    case sixty    = 60
    case ninety   = 90

    var id: Int { rawValue }

    /// Duration in seconds. Zero for `.disabled`.
    var seconds: TimeInterval { TimeInterval(rawValue * 60) }

    /// Localization key for the picker row label.
    var localizationKey: String {
        switch self {
        case .disabled:  return "sleep.disabled"
        case .fifteen:   return "sleep.15"
        case .thirty:    return "sleep.30"
        case .fortyFive: return "sleep.45"
        case .sixty:     return "sleep.60"
        case .ninety:    return "sleep.90"
        }
    }

    /// Look up the user's default sleep-timer setting. Writes made via `@AppStorage` are reflected.
    static var currentDefault: SleepTimerOption {
        let raw = UserDefaults.standard.integer(forKey: SettingsKey.sleepTimerDefaultMinutes)
        return SleepTimerOption(rawValue: raw) ?? .disabled
    }

    /// Effective duration in seconds for the next playback session. Honors a
    /// developer override (`debug.fastSleepTimer` → 15 s) so the prompt can be
    /// triggered quickly during testing without rewriting every option.
    /// Returns `0` when the timer is disabled and no debug override is active.
    static var currentDefaultSeconds: TimeInterval {
        let fastDebug = UserDefaults.standard.bool(forKey: SettingsKey.debugFastSleepTimer)
        if fastDebug { return 15 }
        return currentDefault.seconds
    }
}
