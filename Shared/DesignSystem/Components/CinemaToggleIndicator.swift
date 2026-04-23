import SwiftUI

/// Custom toggle capsule used on both iOS and tvOS to ensure visual consistency.
/// Renders a pill-shaped track that fills with `accent` when on, with a white
/// sliding knob. Interaction is handled by the parent row / button — the indicator
/// itself is purely visual so the row can remain a single focusable unit on tvOS.
struct CinemaToggleIndicator: View {
    let isOn: Bool
    let accent: Color
    var animated: Bool = true

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
            .animation(animated ? .easeInOut(duration: 0.15) : nil, value: isOn)
    }
}
