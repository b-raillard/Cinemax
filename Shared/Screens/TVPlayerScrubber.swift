#if os(tvOS)
import SwiftUI

// MARK: - Scrubber

/// Display-only. Focus management and onMoveCommand live in TVControlsOverlay
/// so the parent's @FocusState owns the binding and correctly restores focus
/// to any sibling button after a Menu is dismissed with the back button.
struct TVPlayerScrubber: View {
    let state: TVPlayerState
    let isFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .frame(height: isFocused ? 8 : 5)
                    Capsule()
                        .fill(.white)
                        .frame(width: geo.size.width * state.progress,
                               height: isFocused ? 8 : 5)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .animation(.easeInOut(duration: 0.15), value: isFocused)
            }
            .frame(height: 16)

            HStack {
                Text(state.formattedCurrentTime)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 1)
                Spacer()
                Text(state.formattedRemaining)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
                    .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 1)
            }
        }
    }
}
#endif
