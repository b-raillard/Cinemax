import SwiftUI
import NukeUI

struct HeroSection: View {
    let title: String
    var subtitle: String? = nil
    var metadata: String? = nil
    let backdropURL: URL?
    var onPlay: (() -> Void)? = nil
    var onMoreInfo: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Backdrop image
            LazyImage(url: backdropURL) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(CinemaColor.surfaceContainerLow)
                }
            }
            .overlay(CinemaGradient.heroOverlay)

            // Content overlay
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                Text(title)
                    .font(CinemaFont.display(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .tracking(-1)

                if let subtitle {
                    Text(subtitle)
                        .font(CinemaFont.bodyLarge)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(3)
                }

                if let metadata {
                    Text(metadata)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.outline)
                }

                if onPlay != nil || onMoreInfo != nil {
                    HStack(spacing: CinemaSpacing.spacing3) {
                        if let onPlay {
                            CinemaButton(
                                title: "Play",
                                style: .primary,
                                icon: "play.fill",
                                action: onPlay
                            )
                            .frame(width: 200)
                        }

                        if let onMoreInfo {
                            CinemaButton(
                                title: "More Info",
                                style: .ghost,
                                icon: "info.circle",
                                action: onMoreInfo
                            )
                            .frame(width: 200)
                        }
                    }
                }
            }
            .padding(CinemaSpacing.spacing20)
            .padding(.bottom, CinemaSpacing.spacing6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 600)
        .clipped()
    }
}
