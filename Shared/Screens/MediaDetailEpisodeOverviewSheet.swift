import SwiftUI

// MARK: - Episode Overview

/// Identifiable payload for the episode-overview `.sheet(item:)` on
/// `MediaDetailScreen`. Built by the iOS episode card and tvOS episode row when
/// the user taps "See more"; consumed by `EpisodeOverviewSheet` below.
struct EpisodeOverviewItem: Identifiable {
    let id: String
    let title: String
    let overview: String
}

/// Modal sheet showing the full episode overview text. Presented via
/// `.sheet(item: $episodeOverview)` on `MediaDetailScreen`.
struct EpisodeOverviewSheet: View {
    let item: EpisodeOverviewItem
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: CinemaScale.pt(14), weight: .bold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(themeManager.accentContainer)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc.localized("action.done"))

                Spacer()

                Text(item.title)
                    .font(.system(size: CinemaScale.pt(17), weight: .bold))
                    .foregroundStyle(CinemaColor.onSurface)
                    .multilineTextAlignment(.center)

                Spacer()

                Color.clear.frame(width: 36, height: 36)
            }

            ScrollView {
                Text(item.overview)
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .background(CinemaColor.surface.ignoresSafeArea())
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}
