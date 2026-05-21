import Foundation

/// Shared HH:MM:SS / M:SS formatter for the VLC player — used by
/// `VLCStreamPresenter` in both its stream and offline modes.
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
}
