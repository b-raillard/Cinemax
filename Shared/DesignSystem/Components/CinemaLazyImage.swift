import SwiftUI
import NukeUI

/// Standard lazy-loading image with configurable fallback.
///
/// - `fallbackIcon`: SF Symbol name shown when the image fails or is absent.
///   Pass `nil` to show only the background color with no icon.
/// - `fallbackBackground`: Background color for the loading and error states.
/// - `showLoadingIndicator`: When `true`, a `ProgressView` is shown while the
///   image is downloading. Suitable for small cards; skip for large backdrops.
struct CinemaLazyImage: View {
    let url: URL?
    var fallbackIcon: String? = "photo"
    var fallbackBackground: Color = CinemaColor.surfaceContainerHigh
    var showLoadingIndicator: Bool = false

    var body: some View {
        LazyImage(url: url) { state in
            if let image = state.image {
                image
                    .resizable()
                    .scaledToFill()
            } else if showLoadingIndicator && state.isLoading {
                fallbackBackground
                    .overlay {
                        ProgressView()
                            .tint(CinemaColor.onSurfaceVariant)
                    }
            } else {
                fallbackBackground
                    .overlay {
                        if let icon = fallbackIcon {
                            Image(systemName: icon)
                                .font(.system(size: CinemaScale.pt(28), weight: .regular))
                                .foregroundStyle(CinemaColor.outlineVariant)
                        }
                    }
            }
        }
    }
}

#if DEBUG
#Preview("CinemaLazyImage — fallback variants") {
    HStack(spacing: CinemaSpacing.spacing3) {
        // Nil URL → icon fallback
        CinemaLazyImage(url: nil, fallbackIcon: "film")
            .frame(width: 120, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
        // Nil URL, no icon → solid fallback
        CinemaLazyImage(url: nil, fallbackIcon: nil, fallbackBackground: CinemaColor.surfaceContainerHighest)
            .frame(width: 120, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
    }
    .padding(CinemaSpacing.spacing4)
    .background(CinemaColor.surfaceContainerLowest)
}
#endif
