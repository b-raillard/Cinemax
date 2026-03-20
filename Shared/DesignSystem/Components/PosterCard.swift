import SwiftUI
import NukeUI

struct PosterCard: View {
    let title: String
    let imageURL: URL?
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            LazyImage(url: imageURL) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(2/3, contentMode: .fill)
                } else if state.isLoading {
                    Rectangle()
                        .fill(CinemaColor.surfaceContainerHigh)
                        .aspectRatio(2/3, contentMode: .fill)
                        .overlay {
                            ProgressView()
                                .tint(CinemaColor.onSurfaceVariant)
                        }
                } else {
                    Rectangle()
                        .fill(CinemaColor.surfaceContainerHigh)
                        .aspectRatio(2/3, contentMode: .fill)
                        .overlay {
                            Image(systemName: "film")
                                .font(.largeTitle)
                                .foregroundStyle(CinemaColor.outlineVariant)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
            .cinemaFocus()

            Text(title)
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .lineLimit(2)

            if let subtitle {
                Text(subtitle)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.outline)
                    .lineLimit(1)
            }
        }
    }
}
