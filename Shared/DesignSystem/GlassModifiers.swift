import SwiftUI

// MARK: - Glass Panel

struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(Color(hex: 0x252626, alpha: 0.6))
                    )
            )
    }
}

// MARK: - Cinema Card

struct CinemaCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .fill(CinemaColor.surfaceContainerHigh)
            )
    }
}

// MARK: - View Extensions

extension View {
    func glassPanel(cornerRadius: CGFloat = CinemaRadius.extraLarge) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius))
    }

    func cinemaCard() -> some View {
        modifier(CinemaCardModifier())
    }
}
