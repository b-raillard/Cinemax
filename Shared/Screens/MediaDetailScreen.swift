import SwiftUI
import CinemaxKit
import JellyfinAPI

struct MediaDetailScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    #if os(tvOS)
    @Environment(VideoPlayerCoordinator.self) private var coordinator
    #endif
    @State var viewModel: MediaDetailViewModel

    init(itemId: String, itemType: BaseItemKind = .movie) {
        _viewModel = State(initialValue: MediaDetailViewModel(itemId: itemId, itemType: itemType))
    }

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            if viewModel.isLoading {
                LoadingStateView()
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else if let item = viewModel.item {
                detailContent(item)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await viewModel.load(using: appState)
        }
        #if os(tvOS)
        .onChange(of: coordinator.lastDismissedAt) { _, _ in
            Task { await viewModel.load(using: appState) }
        }
        #endif
    }

    // MARK: - Detail Content

    private func detailContent(_ item: BaseItemDto) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Backdrop hero
                backdropSection(item)

                VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                    // Action buttons
                    actionButtons(item)

                    // Overview
                    if let overview = item.overview {
                        Text(overview)
                            .font(CinemaFont.body)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .padding(.horizontal, contentPadding)
                            #if os(tvOS)
                            .focusable()
                            #endif
                    }

                    // Cast
                    if let people = item.people, !people.isEmpty {
                        castSection(people)
                    }

                    // Seasons & Episodes (for series)
                    if viewModel.resolvedType == .series, !viewModel.seasons.isEmpty {
                        seasonsSection(item)
                    }

                    // Similar items
                    if !viewModel.similarItems.isEmpty {
                        similarSection
                    }

                    Spacer(minLength: 80)
                }
                .padding(.top, CinemaSpacing.spacing4)
            }
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
    }

    // MARK: - Backdrop

    @ViewBuilder
    private func backdropSection(_ item: BaseItemDto) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let backdropId = item.parentBackdropItemID ?? item.seriesID ?? item.id {
                CinemaLazyImage(
                    url: appState.imageBuilder.imageURL(itemId: backdropId, imageType: .backdrop, maxWidth: 1920),
                    fallbackIcon: nil,
                    fallbackBackground: CinemaColor.surfaceContainerLow
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            CinemaGradient.heroOverlay

            VStack(alignment: .leading, spacing: detailHeroSpacing) {
                // Badges
                HStack(spacing: 8) {
                    if let rating = item.officialRating {
                        RatingBadge(rating: rating)
                    }

                    metadataLine(item)
                }
                .foregroundStyle(CinemaColor.onSurfaceVariant)

                // Title
                Text(item.name ?? "")
                    .font(.system(size: detailTitleSize, weight: .black))
                    .tracking(-1.5)
                    .foregroundStyle(.white)
                    .lineLimit(2)

                // Genres
                if let genres = item.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: " · "))
                        .font(.system(size: genreFontSize, weight: .medium))
                        .foregroundStyle(themeManager.accent)
                }

                // Community rating
                if let rating = item.communityRating {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                        Text(String(format: "%.1f", rating))
                            .fontWeight(.bold)
                    }
                    .font(.system(size: ratingFontSize))
                    .foregroundStyle(CinemaColor.onSurface)
                }
            }
            .padding(.horizontal, contentPadding)
            .padding(.top, contentPadding)
            .padding(.bottom, contentPadding + CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: backdropHeight)
        .clipped()
    }

    // MARK: - Metadata

    private func metadataLine(_ item: BaseItemDto) -> some View {
        let parts: [String] = [
            item.productionYear.map(String.init),
            item.runTimeTicks.map { ticks in
                let minutes = ticks.jellyfinMinutes
                return minutes > 60 ? loc.localized("detail.runtime.hours", minutes / 60, minutes % 60) : loc.localized("detail.runtime.minutes", minutes)
            },
            viewModel.resolvedType == .series ? item.childCount.map { loc.localized("detail.seasons", $0) } : nil
        ].compactMap { $0 }

        return Text(parts.joined(separator: " · "))
            .font(.system(size: metadataFontSize, weight: .medium))
    }

    // MARK: - Episode Navigation

    /// Computes prev/next episode refs and builds an EpisodeNavigator for a given episode ID.
    /// Returns nil navigator when there are fewer than 2 episodes in the current season.
    private func episodeNavigation(for episodeId: String) -> (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?) {
        // Use the current season's episodes; fall back to nextUpEpisodes when the episode
        // lives in a different season (e.g. next-up crosses a season boundary).
        let inCurrentSeason = viewModel.episodes.contains { $0.id == episodeId }
        let sourceEpisodes = inCurrentSeason ? viewModel.episodes : viewModel.nextUpEpisodes
        return buildEpisodeNavigation(
            for: episodeId, in: sourceEpisodes,
            apiClient: appState.apiClient, userId: appState.currentUserId ?? ""
        )
    }

    // MARK: - Action Buttons

    private func actionButtons(_ item: BaseItemDto) -> some View {
        let isSeries = viewModel.resolvedType == .series
        let nextEp: BaseItemDto? = isSeries ? viewModel.nextUpEpisode : nil

        // Determine resume position ticks and total ticks
        let posTicks: Int = {
            if !isSeries { return item.userData?.playbackPositionTicks ?? 0 }
            return nextEp?.userData?.playbackPositionTicks ?? 0
        }()
        let totalTicks: Int = {
            if !isSeries { return item.runTimeTicks ?? 0 }
            return nextEp?.runTimeTicks ?? 0
        }()
        let isPlayed: Bool = isSeries
            ? (nextEp?.userData?.isPlayed ?? false)
            : (item.userData?.isPlayed ?? false)

        let showResume = posTicks > 0 && !isPlayed && totalTicks > 0
        let progress: Double = showResume ? min(1.0, Double(posTicks) / Double(totalTicks)) : 0
        let remainingTicks = max(0, totalTicks - posTicks)
        let remainingMinutes = remainingTicks.jellyfinMinutes
        let startSeconds: Double? = showResume ? posTicks.jellyfinSeconds : nil

        let playItemId: String = nextEp?.id ?? item.id ?? ""
        let playTitle: String = nextEp?.name ?? item.name ?? ""

        return VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            // Episode label for series next-up
            if let ep = nextEp {
                let parts: [String] = [
                    ep.indexNumber.map { loc.localized("detail.episode", $0) },
                    ep.name
                ].compactMap { $0 }
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(1)
                }
            }

            // Progress bar + remaining time when resuming
            if showResume {
                ProgressBarView(progress: progress)
                    .frame(width: playButtonWidth)

                Text(remainingMinutes >= 60
                    ? loc.localized("home.remainingTime.hours", remainingMinutes / 60, remainingMinutes % 60)
                    : loc.localized("home.remainingTime.minutes", remainingMinutes))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }

            // Play button — include episode navigation when playing a series episode
            let epNav = nextEp.flatMap { ep -> (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)? in
                guard let id = ep.id else { return nil }
                return episodeNavigation(for: id)
            }
            if !playItemId.isEmpty {
                PlayLink(
                    itemId: playItemId, title: playTitle, startTime: startSeconds,
                    previousEpisode: epNav?.previous, nextEpisode: epNav?.next,
                    episodeNavigator: epNav?.navigator
                ) {
                    HStack(spacing: CinemaSpacing.spacing2) {
                        Text(loc.localized("detail.play"))
                            .font(.system(size: buttonFontSize, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "play.fill")
                            .font(.system(size: buttonFontSize - 2, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, buttonVerticalPadding)
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
            }
        }
        .padding(.horizontal, contentPadding)
    }

    // MARK: - Cast

    private func castSection(_ people: [BaseItemPerson]) -> some View {
        return ContentRow(title: loc.localized("detail.castCrew")) {
            ForEach(people.prefix(20), id: \.id) { person in
                CastCircle(
                    name: person.name ?? "",
                    role: person.role,
                    imageURL: person.id.map {
                        appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 200)
                    }
                )
            }
        }
    }

    // MARK: - Seasons

    private func seasonsSection(_ item: BaseItemDto) -> some View {
        let seriesId = item.id ?? viewModel.itemId

        return VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            // Season picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.seasons, id: \.id) { season in
                        let isSelected = season.id == viewModel.selectedSeasonId
                        Button {
                            if let id = season.id {
                                Task { await viewModel.selectSeason(id, seriesId: seriesId, using: appState) }
                            }
                        } label: {
                            Text(season.name ?? loc.localized("detail.season"))
                                .font(.system(size: seasonTabFontSize, weight: isSelected ? .bold : .medium))
                                .foregroundStyle(isSelected ? .white : CinemaColor.onSurfaceVariant)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    isSelected
                                        ? Capsule().fill(themeManager.accentContainer)
                                        : Capsule().fill(CinemaColor.surfaceContainerHigh)
                                )
                        }
                        #if os(tvOS)
                        .buttonStyle(SeasonTabButtonStyle(isSelected: isSelected, accent: themeManager.accent))
                        .focusEffectDisabled()
                        .hoverEffectDisabled()
                        #else
                        .buttonStyle(.plain)
                        #endif
                    }
                }
                .padding(.horizontal, contentPadding)
            }

            // Episodes list
            VStack(spacing: 12) {
                ForEach(viewModel.episodes, id: \.id) { episode in
                    episodeRow(episode)
                }
            }
            .padding(.horizontal, contentPadding)
        }
    }

    @ViewBuilder
    private func episodeRow(_ episode: BaseItemDto) -> some View {
        if let id = episode.id {
            let (epPrev, epNext, epNavigator) = episodeNavigation(for: id)
            let epLabel: String = {
                var parts: [String] = []
                if let num = episode.indexNumber { parts.append(loc.localized("detail.episode", num)) }
                if let name = episode.name { parts.append(name) }
                return parts.joined(separator: ", ")
            }()
            PlayLink(
                itemId: id, title: episode.name ?? "",
                previousEpisode: epPrev, nextEpisode: epNext,
                episodeNavigator: epNavigator
            ) {
                HStack(spacing: 12) {
                    // Thumbnail
                    let epProgress: Double? = {
                        guard let ticks = episode.userData?.playbackPositionTicks,
                              let total = episode.runTimeTicks,
                              ticks > 0, total > 0,
                              !(episode.userData?.isPlayed ?? false)
                        else { return nil }
                        return min(1.0, Double(ticks) / Double(total))
                    }()
                    CinemaLazyImage(url: appState.imageBuilder.imageURL(itemId: id, imageType: .primary, maxWidth: 300), fallbackIcon: "play.circle")
                        .frame(width: episodeThumbnailWidth, height: episodeThumbnailWidth * 9 / 16)
                        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
                        .overlay(alignment: .bottom) {
                            if let p = epProgress {
                                ProgressBarView(progress: p, height: 3, trackColor: Color.white.opacity(0.25))
                                    .padding(.horizontal, 6)
                                    .padding(.bottom, 6)
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

                        if let runtime = episode.runTimeTicks {
                            let minutes = runtime.jellyfinMinutes
                            Text(loc.localized("detail.runtime.min", minutes))
                                .font(CinemaFont.label(.medium))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                        }
                    }

                    Spacer()
                }
                .padding(12)
                .background(CinemaColor.surfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVCardButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel(epLabel)
        }
    }

    // MARK: - Similar Items

    private var similarSection: some View {
        return ContentRow(title: loc.localized("detail.moreLikeThis")) {
            ForEach(viewModel.similarItems, id: \.id) { item in
                NavigationLink {
                    if let id = item.id {
                        MediaDetailScreen(
                            itemId: id,
                            itemType: item.type ?? .movie
                        )
                    }
                } label: {
                    PosterCard(
                        title: item.name ?? "",
                        imageURL: item.id.map { appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300) },
                        subtitle: item.productionYear.map(String.init)
                    )
                    .frame(width: similarCardWidth)
                }
                #if os(tvOS)
                .buttonStyle(CinemaTVCardButtonStyle())
                #else
                .buttonStyle(.plain)
                #endif
                .accessibilityLabel([item.name, item.productionYear.map(String.init)].compactMap { $0 }.joined(separator: ", "))
            }
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        ErrorStateView(message: message, retryTitle: loc.localized("action.retry")) {
            Task { await viewModel.load(using: appState) }
        }
    }

    // MARK: - Adaptive Sizing

    private var backdropHeight: CGFloat {
        #if os(tvOS)
        760
        #else
        310
        #endif
    }

    private var detailTitleSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(64)
        #else
        26
        #endif
    }

    private var detailHeroSpacing: CGFloat {
        #if os(tvOS)
        14
        #else
        8
        #endif
    }

    private var contentPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing20
        #else
        CinemaSpacing.spacing4
        #endif
    }

    private var metadataFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(20)
        #else
        13
        #endif
    }

    private var genreFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(20)
        #else
        13
        #endif
    }

    private var ratingFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(22)
        #else
        15
        #endif
    }

    private var buttonFontSize: CGFloat {
        #if os(tvOS)
        28
        #else
        18
        #endif
    }

    private var buttonVerticalPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing4
        #else
        CinemaSpacing.spacing2
        #endif
    }

    private var actionButtonSpacing: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing5
        #else
        12
        #endif
    }

    private var playButtonWidth: CGFloat {
        #if os(tvOS)
        240
        #else
        160
        #endif
    }

    private var similarCardWidth: CGFloat {
        #if os(tvOS)
        200
        #else
        140
        #endif
    }

    private var episodeThumbnailWidth: CGFloat {
        #if os(tvOS)
        200
        #else
        130
        #endif
    }

    private var episodeTitleFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(22)
        #else
        15
        #endif
    }

    private var seasonTabFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(22)
        #else
        14
        #endif
    }
}

// MARK: - tvOS Season Tab Button Style

#if os(tvOS)
private struct SeasonTabButtonStyle: ButtonStyle {
    let isSelected: Bool
    let accent: Color
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                Capsule()
                    .strokeBorder(accent.opacity(isFocused ? 0.8 : 0), lineWidth: 1.5)
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
#endif
