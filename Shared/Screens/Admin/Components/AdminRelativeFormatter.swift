#if os(iOS)
import Foundation

/// Relative dates for the admin screens (« il y a 5 minutes »), in the APP's
/// language rather than the device's.
///
/// It was a factory for five `nonisolated(unsafe) static let`
/// `RelativeDateTimeFormatter`s, which formatted in the DEVICE locale — an
/// English phone printed « 5 minutes ago » inside a French app (audit
/// 2026-09-22, Q7). `Date.RelativeFormatStyle` is a `Sendable` value that
/// carries its locale, so it needs neither the shared mutable formatter nor
/// the `nonisolated(unsafe)` that came with it.
enum AdminRelativeFormatter {
    enum Style {
        /// « il y a 5 minutes »
        case full
        /// « il y a 5 min »
        case short
    }

    static func string(for date: Date, style: Style = .full, locale: Locale) -> String {
        date.formatted(Date.RelativeFormatStyle(
            presentation: .numeric,
            unitsStyle: style == .full ? .wide : .abbreviated,
            locale: locale
        ))
    }
}
#endif
