import SwiftUI

struct WideCard: View {
    let title: String
    let imageURL: URL?
    var progress: Double? = nil
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            Color.clear
                .aspectRatio(16/9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    CinemaLazyImage(url: imageURL, fallbackIcon: "play.rectangle")
                }
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 {
                        ProgressBarView(progress: progress)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                .cinemaFocus()

            Text(title)
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.outline)
                    .lineLimit(1)
            }
        }
    }
}
