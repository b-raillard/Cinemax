import SwiftUI

/// Full-area loading spinner.
/// Default tint matches the surface text color; pass `.white` for dark overlays.
struct LoadingStateView: View {
    var tint: Color = CinemaColor.onSurfaceVariant

    var body: some View {
        ProgressView()
            .tint(tint)
            .scaleEffect(1.5)
    }
}
