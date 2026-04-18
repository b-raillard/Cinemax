import SwiftUI

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
                    // No loading indicator — rendering 6+ simultaneous ProgressViews
                    // in a dense grid is visual noise and costs layout. The fallback
                    // background shows during the brief load window.
                    CinemaLazyImage(url: imageURL, fallbackIcon: "film")
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                .cinemaFocus()

            Text("M\nM")
                .font(CinemaFont.label(.large))
                .lineLimit(2)
                .hidden()
                .accessibilityHidden(true)
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
