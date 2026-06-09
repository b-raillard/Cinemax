import SwiftUI

/// Custom toggle capsule used on both iOS and tvOS to ensure visual consistency.
/// Renders a pill-shaped track that fills with `accent` when on, with a white
/// sliding knob. Interaction is handled by the parent row / button — the indicator
/// itself is purely visual so the row can remain a single focusable unit on tvOS.
struct CinemaToggleIndicator: View {
    let isOn: Bool
    let accent: Color
    /// Extra opt-out for call sites that never want the slide (the global
    /// Motion Effects setting is enforced here regardless, so callers don't
    /// need to thread `motionEffectsEnabled` through — same pattern as
    /// `TVButtonStyles` / `CinemaFocusModifier`).
    var animated: Bool = true

    @Environment(\.motionEffectsEnabled) private var motionEffects

    var body: some View {
        Capsule()
            .fill(isOn ? accent : CinemaColor.surfaceContainerHighest)
            .frame(width: 52, height: 32)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 26, height: 26)
                    .padding(3)
            }
            .animation(animated && motionEffects ? .easeInOut(duration: 0.15) : nil, value: isOn)
    }
}

#if DEBUG
#Preview("CinemaToggleIndicator — states") {
    let accent = Color.green
    return HStack(spacing: CinemaSpacing.spacing3) {
        CinemaToggleIndicator(isOn: true, accent: accent)
        CinemaToggleIndicator(isOn: false, accent: accent)
    }
    .padding(CinemaSpacing.spacing4)
    .background(CinemaColor.surfaceContainerLowest)
}
#endif
