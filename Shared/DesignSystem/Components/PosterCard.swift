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
                // RULE — a clipped `CinemaLazyImage` MUST be followed by
                // `.contentShape(Rectangle())`. `CinemaLazyImage` scales to
                // FILL, so any source whose aspect ratio differs from the box
                // overflows it — a 16:9 episode still stands in this 2:3 poster
                // slot on the search and library grids, sticking out ~94 pt on
                // each side of a 112 pt card. `clipped()`/`clipShape()` clip the
                // DRAWING only; the overflow stays hit-testable, and the next
                // card in the grid — drawn after this one, hence on top — then
                // swallows long presses aimed at this one's right half and opens
                // ITS menu. Measured before the fix: a touch at x=96, inside the
                // card spanning x=16→128.7, built the menu of the card at
                // x=144.7. Applies to every card that clips a filled image.
                .contentShape(Rectangle())
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

#if DEBUG
#Preview("PosterCard — with + without subtitle") {
    HStack(spacing: CinemaSpacing.spacing3) {
        PosterCard(title: "The Long Movie Title That Wraps", imageURL: nil, subtitle: "2024")
        PosterCard(title: "Short", imageURL: nil)
    }
    .padding(CinemaSpacing.spacing4)
    .frame(width: 360)
    .background(CinemaColor.surfaceContainerLowest)
    .environment(ThemeManager())
}
#endif
