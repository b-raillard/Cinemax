import SwiftUI

struct WideCard: View {
    let title: String
    let imageURL: URL?
    var progress: Double? = nil
    var subtitle: String? = nil
    /// Glyph drawn when there is no image to draw. `play.rectangle` reads as
    /// "a video whose artwork is missing", which is right for a media card and
    /// wrong for a Watch Together session — a group carries no item, so having
    /// no artwork is its ORDINARY state, not a failure.
    var fallbackIcon: String = "play.rectangle"
    /// A third, quieter line. Carried by the "En direct" row so a session's
    /// state and age can sit under the participants without crowding
    /// `subtitle`, which is `lineLimit(1)` and already spoken for.
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            Color.clear
                .aspectRatio(16/9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    CinemaLazyImage(url: imageURL, fallbackIcon: fallbackIcon)
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
                // Same reason as `PosterCard` — see the RULE there. Less acute
                // here (a backdrop usually matches this 16:9 box), but a source
                // that doesn't still overflows and stays hit-testable.
                .contentShape(Rectangle())
                .cinemaFocus()
                .accessibilityHidden(true)

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

            if let detail {
                Text(detail)
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.outlineVariant)
                    .lineLimit(1)
            }
        }
    }
}
