import SwiftUI
import CinemaxKit

/// Painted in place of a backdrop when Jellyfin has no `Backdrop` image for the
/// item. A single large `film` SF Symbol centered on `surfaceContainerLow`, with
/// a soft accent radial wash from the top-trailing corner. Designed to sit
/// underneath `CinemaGradient.heroOverlay` (the bottom fade keeps title/buttons
/// legible — same visual contract as a real backdrop).
struct BackdropFallbackView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                CinemaColor.surfaceContainerLow

                RadialGradient(
                    colors: [themeManager.accent.opacity(accentOpacity), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.9
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)

                // Center the glyph in the *visible* area (above title/buttons),
                // not the backdrop's geometric center. The bottom ~30% is reserved
                // for the title VStack + heroOverlay's opaque surface fade, so
                // anchoring at 35% of the height puts the icon in the upper-middle
                // of what the user actually sees on every form factor.
                Image(systemName: "film")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(iconColor)
                    .opacity(iconOpacity)
                    .frame(
                        width: min(proxy.size.width, proxy.size.height) * 0.42,
                        height: min(proxy.size.width, proxy.size.height) * 0.42
                    )
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.35)
            }
        }
        .accessibilityHidden(true)
    }

    private var iconColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var iconOpacity: Double {
        colorScheme == .dark ? 0.10 : 0.09
    }

    private var accentOpacity: Double {
        colorScheme == .dark ? 0.16 : 0.10
    }
}
