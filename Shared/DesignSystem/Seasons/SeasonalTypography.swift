import SwiftUI
import UIKit

@MainActor
enum SeasonalTypography {
    /// The season's display face at a FIXED size (`fixedSize:`): heroes and row
    /// titles size through `CinemaScale.pt`, never Dynamic Type — see the
    /// Dynamic Type RULE. `nil` when no season, no font, or the font failed to
    /// register (the caller keeps its system font).
    static func titleFont(for theme: SeasonalTheme?, size: CGFloat) -> Font? {
        guard let face = theme?.titleFont, UIFont(name: face.postScriptName, size: size) != nil else { return nil }
        return .custom(face.postScriptName, fixedSize: size * face.sizeScale)
    }
}

/// The hero title: black system caps, or the season's display face — in
/// title case (Halloween's italic « Nosferatu ») or in spaced capitals
/// (« Givre »), as its `SeasonFont` says.
private struct HeroTitleStyle: ViewModifier {
    @Environment(\.seasonID) private var seasonID
    let size: CGFloat
    let uppercase: Bool

    func body(content: Content) -> some View {
        let theme = SeasonalThemeCatalogue.theme(id: seasonID)
        if let font = SeasonalTypography.titleFont(for: theme, size: size), let face = theme?.titleFont {
            content
                .font(font)
                .tracking(face.tracking.map { size * $0 } ?? -0.5)
                .textCase(face.uppercase ? .uppercase : nil)
        } else {
            content
                .font(.system(size: size, weight: .black))
                .tracking(-1.5)
                .textCase(uppercase ? .uppercase : nil)
        }
    }
}

extension View {
    func heroTitleStyle(size: CGFloat, uppercase: Bool) -> some View {
        modifier(HeroTitleStyle(size: size, uppercase: uppercase))
    }
}
