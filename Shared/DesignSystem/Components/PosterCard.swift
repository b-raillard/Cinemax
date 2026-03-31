import SwiftUI
import NukeUI

struct PosterCard: View {
    let title: String
    let imageURL: URL?
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    LazyImage(url: imageURL) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .scaledToFill()
                        } else if state.isLoading {
                            Rectangle()
                                .fill(CinemaColor.surfaceContainerHigh)
                                .overlay {
                                    ProgressView()
                                        .tint(CinemaColor.onSurfaceVariant)
                                }
                        } else {
                            Rectangle()
                                .fill(CinemaColor.surfaceContainerHigh)
                                .overlay {
                                    Image(systemName: "film")
                                        .font(.largeTitle)
                                        .foregroundStyle(CinemaColor.outlineVariant)
                                }
                        }
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                .cinemaFocus()

            Text("M\nM")
                .font(CinemaFont.label(.large))
                .lineLimit(2)
                .hidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    Text(title)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(2)
                }

            if let subtitle {
                Text(subtitle)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.outline)
                    .lineLimit(1)
            }
        }
    }
}
