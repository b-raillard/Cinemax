import SwiftUI
import NukeUI

struct WideCard: View {
    let title: String
    let imageURL: URL?
    var progress: Double? = nil
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            ZStack(alignment: .bottom) {
                LazyImage(url: imageURL) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(16/9, contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(CinemaColor.surfaceContainerHigh)
                            .aspectRatio(16/9, contentMode: .fill)
                            .overlay {
                                Image(systemName: "play.rectangle")
                                    .font(.largeTitle)
                                    .foregroundStyle(CinemaColor.outlineVariant)
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))

                if let progress, progress > 0 {
                    GeometryReader { geo in
                        VStack {
                            Spacer()
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(CinemaColor.surfaceContainerHighest)
                                    .frame(height: 4)
                                Capsule()
                                    .fill(CinemaColor.tertiary)
                                    .frame(width: geo.size.width * progress, height: 4)
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                        }
                    }
                }
            }
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
