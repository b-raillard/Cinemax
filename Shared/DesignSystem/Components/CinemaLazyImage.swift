import SwiftUI
import NukeUI

/// Standard lazy-loading image with configurable fallback.
///
/// - `fallbackIcon`: SF Symbol name shown when the image fails or is absent.
///   Pass `nil` to show only the background color with no icon.
/// - `fallbackBackground`: Background color for the loading and error states.
/// - `showLoadingIndicator`: When `true`, a `ProgressView` is shown while the
///   image is downloading. Suitable for small cards; skip for large backdrops.
/// - `contentMode`: `.fill` for artwork that must cover its box (posters,
///   backdrops, stills — the default, and what every card relies on). `.fit`
///   for artwork whose own shape matters, such as a title logo, which must not
///   be cropped and whose aspect ratio varies from one title to the next.
/// - `fadesIn`: the image fades in when it arrives from the network or the
///   disk cache (`CinemaMotion.imageFade`, gated by Motion Effects). An image
///   already in Nuke's MEMORY cache is set synchronously, outside the
///   transaction, so scrolling back through a grid never re-fades. Pass `false`
///   where another animation owns the moment (the heroes' crossfade, the fiche
///   backdrop under the card → fiche zoom).
struct CinemaLazyImage: View {
    let url: URL?
    var fallbackIcon: String? = "photo"
    var fallbackBackground: Color = CinemaColor.surfaceContainerHigh
    var showLoadingIndicator: Bool = false
    var contentMode: ContentMode = .fill
    var fadesIn: Bool = true

    @Environment(\.motionEffectsEnabled) private var motionEnabled

    var body: some View {
        LazyImage(url: url, transaction: Transaction(animation: fadesIn
            ? CinemaMotion.gated(CinemaMotion.imageFade, enabled: motionEnabled)
            : nil)) { state in
            if let image = state.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
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
