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
                            .fill(CinemaColor.surfaceVariant.opacity(0.6))
                    )
            )
    }
}

// MARK: - View Extensions

extension View {
    func glassPanel(cornerRadius: CGFloat = CinemaRadius.extraLarge) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius))
    }
}
