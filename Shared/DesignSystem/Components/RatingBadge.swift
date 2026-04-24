import SwiftUI

/// Official content rating badge (e.g. "PG-13", "TV-MA").
/// Renders as a small pill with white-tinted background, uppercase text.
struct RatingBadge: View {
    let rating: String

    private var fontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(12)
        #else
        CinemaScale.pt(10)
        #endif
    }

    var body: some View {
        Text(rating)
            .font(.system(size: fontSize, weight: .bold))
            .tracking(1)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.small))
    }
}

#if DEBUG
#Preview("RatingBadge") {
    HStack(spacing: CinemaSpacing.spacing2) {
        RatingBadge(rating: "PG-13")
        RatingBadge(rating: "TV-MA")
        RatingBadge(rating: "R")
        RatingBadge(rating: "NC-17")
    }
    .padding(CinemaSpacing.spacing4)
    .background(CinemaColor.surfaceContainerLowest)
}
#endif
