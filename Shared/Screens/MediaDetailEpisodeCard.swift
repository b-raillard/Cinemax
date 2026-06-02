import SwiftUI
import CinemaxKit
import JellyfinAPI

// MARK: - iOS Episode Card

#if os(iOS)

/// iOS episode card used in the season's horizontal episode carousel.
/// Equatable so re-renders triggered by unrelated parent state (e.g.
/// season switching, similar-items load) skip this card when its episode
/// payload hasn't changed.
struct MediaDetailEpisodeCard: View, Equatable {
    let episode: BaseItemDto
    let epPrev: EpisodeRef?
    let epNext: EpisodeRef?
    let epNavigator: EpisodeNavigator?
    let episodeTitleFontSize: CGFloat
    let onSelectOverview: (EpisodeOverviewItem) -> Void

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    // Equatable ignores the navigator + onSelect closures — same prev/next id
    // and same payload should short-circuit re-render.
    //
    // `MainActor.assumeIsolated` because SwiftUI's view diff calls `==` on the
    // main actor; without it, reading the non-Sendable `BaseItemDto` payload
    // from a `nonisolated` context emits warnings.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.episode.id == rhs.episode.id
                && lhs.episode.name == rhs.episode.name
                && lhs.episode.overview == rhs.episode.overview
                && lhs.episode.indexNumber == rhs.episode.indexNumber
                && lhs.episode.runTimeTicks == rhs.episode.runTimeTicks
                && lhs.episode.userData?.playbackPositionTicks == rhs.episode.userData?.playbackPositionTicks
                && lhs.episode.userData?.isPlayed == rhs.episode.userData?.isPlayed
                && lhs.episode.premiereDate == rhs.episode.premiereDate
                && lhs.epPrev?.id == rhs.epPrev?.id
                && lhs.epNext?.id == rhs.epNext?.id
                && lhs.episodeTitleFontSize == rhs.episodeTitleFontSize
        }
    }

    var body: some View {
        if let id = episode.id {
            let overview = episode.overview.flatMap { $0.isEmpty ? nil : $0 }
            let isPlayed = episode.userData?.isPlayed ?? false
            let epProgress: Double? = {
                guard let ticks = episode.userData?.playbackPositionTicks,
                      let total = episode.runTimeTicks,
                      ticks > 0, total > 0, !isPlayed
                else { return nil }
                return min(1.0, Double(ticks) / Double(total))
            }()

            VStack(alignment: .leading, spacing: 8) {
                // Image + overlays
                PlayLink(
                    itemId: id, title: episode.name ?? "",
                    previousEpisode: epPrev, nextEpisode: epNext,
                    episodeNavigator: epNavigator
                ) {
                    Color.clear
                        .aspectRatio(16/9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            CinemaLazyImage(
                                url: appState.imageBuilder.imageURL(itemId: id, imageType: .primary, maxWidth: 600, tag: episode.primaryImageTagValue),
                                fallbackIcon: "play.circle"
                            )
                        }
                        .overlay(alignment: .bottom) {
                            if let p = epProgress {
                                ProgressBarView(progress: p, height: 3, trackColor: CinemaColor.onSurface.opacity(0.25))
                                    .padding(.horizontal, 6).padding(.bottom, 6)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if isPlayed {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: CinemaScale.pt(28), weight: .semibold))
                                    .foregroundStyle(.white, CinemaColor.surface.opacity(0.8))
                                    .padding(10)
                            }
                        }
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
                }
                .buttonStyle(.plain)

                // Info below image
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: CinemaSpacing.spacing2) {
                        if let num = episode.indexNumber {
                            Text(loc.localized("detail.episode", num))
                                .font(CinemaFont.label(.medium))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                        }
                        Spacer(minLength: 0)
                        DownloadButton(item: episode)
                    }
                    Text(episode.name ?? "")
                        .font(.system(size: episodeTitleFontSize, weight: .bold))
                        .foregroundStyle(CinemaColor.onSurface)
                        .lineLimit(2)

                    MediaDetailEpisodeMetadataLine(episode: episode)

                    if let ov = overview {
                        Text(ov)
                            .font(CinemaFont.dynamicBody)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .lineLimit(3)
                            .padding(.top, 2)
                        Button {
                            onSelectOverview(EpisodeOverviewItem(id: id, title: episode.name ?? "", overview: ov))
                        } label: {
                            Text(loc.localized("detail.seeMore"))
                                .font(CinemaFont.label(.medium))
                                .foregroundStyle(themeManager.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

#endif
