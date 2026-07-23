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
}
#endif
