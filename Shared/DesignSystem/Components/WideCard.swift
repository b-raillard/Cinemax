import SwiftUI
import NukeUI

struct WideCard: View {
    @Environment(ThemeManager.self) private var themeManager
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
                    LazyImage(url: imageURL) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .scaledToFill()
                        } else {
                            Rectangle()
                                .fill(CinemaColor.surfaceContainerHigh)
                                .overlay {
                                    Image(systemName: "play.rectangle")
                                        .font(.largeTitle)
                                        .foregroundStyle(CinemaColor.outlineVariant)
                                }
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 {
                        GeometryReader { geo in
                            VStack {
                                Spacer()
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(CinemaColor.surfaceContainerHighest)
                                        .frame(height: 4)
                                    Capsule()
                                        .fill(themeManager.accent)
                                        .frame(width: geo.size.width * progress, height: 4)
                                }
                                .padding(.horizontal, 8)
                                .padding(.bottom, 8)
                            }
                        }
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
