import SwiftUI
import CinemaxKit
import JellyfinAPI

struct HomeScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State private var viewModel = HomeViewModel()

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            if viewModel.isLoading {
                LoadingStateView()
            } else {
                content
            }
        }
        #if os(iOS)
        .navigationTitle(loc.localized("tab.home"))
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await viewModel.load(using: appState)
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                // Hero
                if let hero = viewModel.heroItem {
                    heroSection(hero)
                }

                // Continue Watching
                if !viewModel.resumeItems.isEmpty {
                    continueWatchingRow
                }

                // Recently Added
                if !viewModel.latestItems.isEmpty {
                    recentlyAddedRow
                }

                Spacer(minLength: 80)
            }
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(_ item: BaseItemDto) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Backdrop — episodes/seasons don't have their own backdrop; use the parent (series)
            if let backdropId = item.parentBackdropItemID ?? item.seriesID ?? item.id {
                CinemaLazyImage(
                    url: appState.imageBuilder.imageURL(itemId: backdropId, imageType: .backdrop, maxWidth: 1920),
                    fallbackIcon: nil,
                    fallbackBackground: CinemaColor.surfaceContainerLow
                )
            }

            // Gradient overlays
            CinemaGradient.heroOverlay

            // Content
            VStack(alignment: .leading, spacing: heroPadding > 60 ? 16 : 10) {
                // Badges
                HStack(spacing: 8) {
                    if let rating = item.officialRating {
                        RatingBadge(rating: rating)
                    }

                    metadataText(for: item)
                }
                .foregroundStyle(CinemaColor.onSurfaceVariant)

                // Title
                Text(item.name ?? "")
                    .font(.system(size: heroTitleSize, weight: .black))
                    .tracking(-1.5)
                    .foregroundStyle(.white)
                    .textCase(.uppercase)
                    .lineLimit(2)

                // Overview — hidden on iOS to keep hero compact
                #if os(tvOS)
                if let overview = item.overview {
                    Text(overview)
                        .font(.system(size: overviewFontSize))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(3)
                        .frame(maxWidth: maxOverviewWidth, alignment: .leading)
                }
                #endif

                // Action buttons
                HStack(spacing: 12) {
                    if let id = item.id {
                        let heroNav = viewModel.resumeNavigation[id]
                        let heroStart: Double? = {
                            guard let ticks = item.userData?.playbackPositionTicks, ticks > 0 else { return nil }
                            return Double(ticks) / 10_000_000
                        }()
                        PlayLink(
                            itemId: id, title: item.name ?? "",
                            startTime: heroStart,
                            previousEpisode: heroNav?.previous, nextEpisode: heroNav?.next,
                            episodeNavigator: heroNav?.navigator
                        ) {
                            HStack(spacing: CinemaSpacing.spacing2) {
                                Text(loc.localized("action.play"))
                                    .font(.system(size: heroPadding > 60 ? 28 : 18, weight: .bold))
                                Image(systemName: "play.fill")
                                    .font(.system(size: heroPadding > 60 ? 26 : 16, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, heroPadding > 60 ? CinemaSpacing.spacing4 : CinemaSpacing.spacing2)
                            .padding(.horizontal, CinemaSpacing.spacing4)
                            #if os(iOS)
                            .background(themeManager.accentContainer)
                            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                            #endif
                        }
                        #if os(tvOS)
                        .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .accent))
                        #else
                        .buttonStyle(.plain)
                        #endif
                        .frame(width: playButtonWidth)

                        NavigationLink {
                            MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
                        } label: {
                            HStack(spacing: CinemaSpacing.spacing2) {
                                Text(loc.localized("action.moreInfo"))
                                    .font(.system(size: heroPadding > 60 ? 28 : 18, weight: .bold))
                                    .lineLimit(1)
                                Image(systemName: "info.circle")
                                    .font(.system(size: heroPadding > 60 ? 26 : 16, weight: .bold))
                            }
                            .foregroundStyle(CinemaColor.onSurface)
                            .padding(.vertical, heroPadding > 60 ? CinemaSpacing.spacing4 : CinemaSpacing.spacing2)
                            .padding(.horizontal, CinemaSpacing.spacing4)
                            #if os(iOS)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                            #endif
                        }
                        #if os(tvOS)
                        .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .ghost))
                        #else
                        .buttonStyle(.plain)
                        #endif
                        .fixedSize()
                    }
                }
            }
            .padding(.horizontal, heroPadding)
            .padding(.top, heroPadding)
            .padding(.bottom, heroPadding + CinemaSpacing.spacing6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .clipped()
    }

    // MARK: - Continue Watching

    private var continueWatchingRow: some View {
        ContentRow(title: loc.localized("home.continueWatching")) {
            ForEach(viewModel.resumeItems, id: \.id) { item in
                if let id = item.id {
                    let nav = viewModel.resumeNavigation[id]
                    let startSeconds: Double? = {
                        guard let ticks = item.userData?.playbackPositionTicks, ticks > 0 else { return nil }
                        return Double(ticks) / 10_000_000
                    }()
                    PlayLink(
                        itemId: id, title: item.name ?? "",
                        startTime: startSeconds,
                        previousEpisode: nav?.previous, nextEpisode: nav?.next,
                        episodeNavigator: nav?.navigator
                    ) {
                        continueWatchingCard(item)
                            .frame(width: wideCardWidth)
                    }
                    #if os(tvOS)
                    .buttonStyle(CinemaTVCardButtonStyle())
                    #else
                    .buttonStyle(.plain)
                    #endif
                }
            }
        }
    }

    @ViewBuilder
    private func continueWatchingCard(_ item: BaseItemDto) -> some View {
        let progress: Double = {
            guard let position = item.userData?.playbackPositionTicks,
                  let total = item.runTimeTicks,
                  total > 0 else { return 0 }
            return Double(position) / Double(total)
        }()

        let isEpisode = item.type == .episode

        let cardTitle: String = isEpisode
            ? (item.seriesName ?? item.name ?? "")
            : (item.name ?? "")

        let cardSubtitle: String? = {
            if isEpisode {
                var label = ""
                if let season = item.parentIndexNumber, let ep = item.indexNumber {
                    label = "S\(season):E\(ep)"
                }
                if let name = item.name, !name.isEmpty {
                    label = label.isEmpty ? name : "\(label) - \(name)"
                }
                return label.isEmpty ? nil : label
            } else {
                guard let position = item.userData?.playbackPositionTicks,
                      let total = item.runTimeTicks else { return nil }
                let remainingTicks = total - position
                let minutes = remainingTicks.jellyfinMinutes
                if minutes > 60 {
                    return loc.localized("home.remainingTime.hours", minutes / 60, minutes % 60)
                }
                return loc.localized("home.remainingTime.minutes", minutes)
            }
        }()

        WideCard(
            title: cardTitle,
            imageURL: (item.parentBackdropItemID ?? item.seriesID ?? item.id).map { appState.imageBuilder.imageURL(itemId: $0, imageType: .backdrop, maxWidth: 600) },
            progress: progress,
            subtitle: cardSubtitle
        )
    }

    // MARK: - Recently Added

    private var recentlyAddedRow: some View {
        ContentRow(title: loc.localized("home.recentlyAdded")) {
            ForEach(viewModel.latestItems, id: \.id) { item in
                recentlyAddedCard(item)
                    .frame(width: posterCardWidth)
            }
        }
    }

    @ViewBuilder
    private func recentlyAddedCard(_ item: BaseItemDto) -> some View {
        let subtitle: String = {
            var parts: [String] = []
            if let year = item.productionYear { parts.append(String(year)) }
            if let type = item.type { parts.append(type.rawValue) }
            return parts.joined(separator: " · ")
        }()

        NavigationLink {
            if let id = item.id {
                MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
            }
        } label: {
            PosterCard(
                title: item.name ?? "",
                imageURL: item.id.map { appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300) },
                subtitle: subtitle
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel([item.name, subtitle.isEmpty ? nil : subtitle].compactMap { $0 }.joined(separator: ", "))
    }

    // MARK: - Helpers

    private func metadataText(for item: BaseItemDto) -> some View {
        let parts: [String] = [
            item.productionYear.map(String.init),
            item.formattedRuntime,
            item.genres?.first
        ].compactMap { $0 }

        return Text(parts.joined(separator: " · "))
            .font(.system(size: metadataFontSize, weight: .medium))
    }

    // MARK: - Adaptive Sizing

    private var heroHeight: CGFloat {
        #if os(tvOS)
        820
        #else
        360
        #endif
    }

    private var heroTitleSize: CGFloat {
        #if os(tvOS)
        72
        #else
        20
        #endif
    }

    private var overviewFontSize: CGFloat {
        #if os(tvOS)
        18
        #else
        14
        #endif
    }

    private var heroPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing20
        #else
        CinemaSpacing.spacing4
        #endif
    }

    private var maxOverviewWidth: CGFloat {
        #if os(tvOS)
        600
        #else
        300
        #endif
    }

    private var playButtonWidth: CGFloat {
        #if os(tvOS)
        220
        #else
        160
        #endif
    }

    private var wideCardWidth: CGFloat {
        #if os(tvOS)
        400
        #else
        280
        #endif
    }

    private var posterCardWidth: CGFloat {
        #if os(tvOS)
        200
        #else
        140
        #endif
    }

    private var metadataFontSize: CGFloat {
        #if os(tvOS)
        16
        #else
        13
        #endif
    }
}
