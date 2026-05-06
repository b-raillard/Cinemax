import SwiftUI
import CinemaxKit
import JellyfinAPI

// MARK: - tvOS Episode Row

#if os(tvOS)

/// tvOS unified card with two focusable zones: a play zone (40%, thumbnail +
/// title) and a synopsis zone (60%, opens overview sheet on press). Equatable
/// so unrelated parent re-renders skip this row when the episode payload is
/// unchanged.
struct MediaDetailEpisodeRow: View, Equatable {
    let episode: BaseItemDto
    let epPrev: EpisodeRef?
    let epNext: EpisodeRef?
    let epNavigator: EpisodeNavigator?
    let episodeThumbnailWidth: CGFloat
    let episodeTitleFontSize: CGFloat
    let onSelectOverview: (EpisodeOverviewItem) -> Void

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

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
                && lhs.episodeThumbnailWidth == rhs.episodeThumbnailWidth
                && lhs.episodeTitleFontSize == rhs.episodeTitleFontSize
        }
    }

    var body: some View {
        if let id = episode.id {
            let epLabel: String = {
                var parts: [String] = []
                if let num = episode.indexNumber { parts.append(loc.localized("detail.episode", num)) }
                if let name = episode.name { parts.append(name) }
                return parts.joined(separator: ", ")
            }()
            let overview = episode.overview.flatMap { $0.isEmpty ? nil : $0 }
            let epProgress: Double? = {
                guard let ticks = episode.userData?.playbackPositionTicks,
                      let total = episode.runTimeTicks,
                      ticks > 0, total > 0,
                      !(episode.userData?.isPlayed ?? false)
                else { return nil }
                return min(1.0, Double(ticks) / Double(total))
            }()

            // One shared card background, two independent focusable zones inside
            HStack(alignment: .top, spacing: 0) {

                // Zone 1 — 40% width, plays the episode
                PlayLink(
                    itemId: id, title: episode.name ?? "",
                    previousEpisode: epPrev, nextEpisode: epNext,
                    episodeNavigator: epNavigator
                ) {
                    HStack(spacing: 12) {
                        CinemaLazyImage(url: appState.imageBuilder.imageURL(itemId: id, imageType: .primary, maxWidth: 300), fallbackIcon: "play.circle")
                            .frame(width: episodeThumbnailWidth, height: episodeThumbnailWidth * 9 / 16)
                            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
                            .overlay(alignment: .bottom) {
                                if let p = epProgress {
                                    ProgressBarView(progress: p, height: 3, trackColor: CinemaColor.onSurface.opacity(0.25))
                                        .padding(.horizontal, 6).padding(.bottom, 6)
                                }
                            }
                        VStack(alignment: .leading, spacing: 4) {
                            if let num = episode.indexNumber {
                                Text(loc.localized("detail.episode", num))
                                    .font(CinemaFont.label(.medium))
                                    .foregroundStyle(themeManager.accent)
                            }
                            Text(episode.name ?? "")
                                .font(.system(size: episodeTitleFontSize, weight: .semibold))
                                .foregroundStyle(CinemaColor.onSurface)
                                .lineLimit(2)
                            MediaDetailEpisodeMetadataLine(episode: episode)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .buttonStyle(TVEpisodeZoneButtonStyle(accent: themeManager.accent))
                // 40% of the full screen width — consistent across all rows
                .containerRelativeFrame(.horizontal, count: 5, span: 2, spacing: 0)
                .accessibilityLabel(epLabel)

                // Divider
                if overview != nil {
                    Rectangle()
                        .fill(CinemaColor.outline.opacity(0.2))
                        .frame(width: 1)
                        .padding(.vertical, 12)
                }

                // Zone 2 — fills rest, opens overview sheet
                if let ov = overview {
                    Button {
                        onSelectOverview(EpisodeOverviewItem(id: id, title: episode.name ?? "", overview: ov))
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(ov)
                                .font(CinemaFont.dynamicBody)
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                                .lineLimit(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Spacer(minLength: 0)
                            Text(loc.localized("detail.seeMore") + "...")
                                .font(CinemaFont.label(.medium))
                                .foregroundStyle(themeManager.accent)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .buttonStyle(TVEpisodeZoneButtonStyle(accent: themeManager.accent))
                    .frame(maxWidth: .infinity)
                }
            }
            .background(CinemaColor.surfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
            .frame(maxWidth: .infinity)
        }
    }
}

#endif
