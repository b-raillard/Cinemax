#if os(iOS)
import Foundation

/// Shared factory for the admin screens' hoisted `RelativeDateTimeFormatter`s.
/// Each screen keeps its own `nonisolated(unsafe) static let` (to avoid
/// allocating a formatter on every row render), but the only thing that
/// differed between them was `unitsStyle` — this collapses that 5× duplication
/// while preserving each screen's chosen style.
enum AdminRelativeFormatter {
    static func make(_ style: RelativeDateTimeFormatter.UnitsStyle = .full) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = style
        return formatter
    }

    /// Formats `date` relative to now in the APP's language. A formatter left
    /// on its default locale follows the DEVICE language, so an English phone
    /// printed « 5 hr. ago » over a French app (same lesson as the system
    /// `EditButton` — the app's language is its own setting). The locale is
    /// re-applied on each call so a language switch takes effect at once.
    @MainActor
    static func string(for date: Date, with formatter: RelativeDateTimeFormatter, languageCode: String) -> String {
        let locale = Locale(identifier: languageCode)
        if formatter.locale.identifier != locale.identifier {
            formatter.locale = locale
        }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
#endif
