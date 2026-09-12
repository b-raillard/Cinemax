import Foundation

/// Shared HH:MM:SS / M:SS formatter for the VLC player — used by
/// `VLCStreamPresenter`.
enum PlayerTimeFormat {
    static func ms(_ ms: Int32) -> String {
        let total = Int(max(0, ms) / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// A duration in WORDS, for VoiceOver — « 1 heure, 2 minutes, 3 secondes ».
    ///
    /// The clock string above is unusable as an `accessibilityValue`: VoiceOver
    /// reads `12:04` as a time of day, and `1:05:30` as something close to
    /// nonsense. `.dropLeading` keeps the smallest unit when the larger ones are
    /// zero, so a position of 0 still says "0 seconds" instead of nothing.
    static func spoken(_ ms: Int32, using formatter: DateComponentsFormatter) -> String {
        let seconds = max(0, Int(ms) / 1000)
        return formatter.string(from: TimeInterval(seconds)) ?? String(seconds)
    }

    /// The formatter `spoken(_:using:)` takes.
    ///
    /// Built once per player and injected, for two reasons:
    /// `DateComponentsFormatter` is expensive to create and this is read on a
    /// 1 s tick, and it is not `Sendable`. Its language is the APP's
    /// (`LocalizationManager`), never the device's — same rule as every other
    /// string the app shows, and the reason the calendar's locale is set rather
    /// than left to default.
    static func makeSpokenFormatter(languageCode: String) -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropLeading
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: languageCode)
        formatter.calendar = calendar
        return formatter
    }
}
