import SwiftUI

// MARK: - Glass Panel

struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat

    /// Accessibility → Display: the two settings the glass look must yield to
    /// (audit §5, lot 9 — the app honoured neither).
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .background {
                if reduceTransparency {
                    // Opaque: nothing of the backdrop shows through the text.
                    shape.fill(CinemaColor.surfaceContainerHigh)
                } else {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(shape.fill(CinemaColor.surfaceVariant.opacity(0.6)))
                }
            }
            // « No borders » is the design's rule, not the user's: with
            // Increase Contrast on, panels get the edge they otherwise lack.
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(CinemaColor.onSurfaceVariant.opacity(0.6), lineWidth: 1)
                }
            }
    }
}

// MARK: - View Extensions

extension View {
    func glassPanel(cornerRadius: CGFloat = CinemaRadius.extraLarge) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius))
    }
}
