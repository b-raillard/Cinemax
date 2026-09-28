import SwiftUI
import UIKit

@MainActor
enum SeasonalTypography {
    /// The season's display face at a FIXED size (`fixedSize:`): heroes and row
    /// titles size through `CinemaScale.pt`, never Dynamic Type — see the
    /// Dynamic Type RULE. `nil` when no season, no font, or the font failed to
    /// register (the caller keeps its system font).
    static func titleFont(for theme: SeasonalTheme?, size: CGFloat) -> Font? {
        guard let name = theme?.titleFont?.postScriptName, UIFont(name: name, size: size) != nil else { return nil }
        return .custom(name, fixedSize: size)
    }
}

/// The hero title: black system caps, or the season's italic display face in
/// title case (the canvas's « Nosferatu »).
private struct HeroTitleStyle: ViewModifier {
    @Environment(\.seasonID) private var seasonID
    let size: CGFloat
    let uppercase: Bool

    func body(content: Content) -> some View {
        if let font = SeasonalTypography.titleFont(for: SeasonalThemeCatalogue.theme(id: seasonID), size: size) {
            content.font(font).tracking(-0.5)
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
