import SwiftUI

/// Accent-filled capsule progress bar.
/// Fills its container width via `GeometryReader`; height is configurable.
struct ProgressBarView: View {
    /// Progress value in the range 0.0–1.0.
    let progress: Double
    var height: CGFloat = 4
    var trackColor: Color = CinemaColor.surfaceContainerHighest

    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                    .frame(height: height)
                Capsule()
                    .fill(themeManager.accent)
                    .frame(width: geo.size.width * max(0, min(1, progress)), height: height)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: height)
    }
}
