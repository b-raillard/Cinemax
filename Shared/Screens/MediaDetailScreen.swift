import SwiftUI
import CinemaxKit
import JellyfinAPI

struct MediaDetailScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    #if os(tvOS)
    @Environment(VideoPlayerCoordinator.self) private var coordinator
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State var viewModel: MediaDetailViewModel
    @State private var episodeOverview: EpisodeOverviewItem?
    @AppStorage(SettingsKey.detailShowQualityBadges) private var showQualityBadges: Bool = SettingsKey.Default.detailShowQualityBadges

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
        .sheet(item: $episodeOverview) { ep in
            EpisodeOverviewSheet(item: ep)
                .environment(themeManager)
        }
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

                    // Quality badges
                    if showQualityBadges {
                        MediaQualityBadges(item: item)
                            .padding(.horizontal, contentPadding)
                    }

                    // Overview — Dynamic Type-aware since users read this prose.
                    if let overview = item.overview {
                        Text(overview)
                            .font(CinemaFont.dynamicBody)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .frame(maxWidth: readingMaxWidth, alignment: .leading)
                            .padding(.horizontal, contentPadding)
                            #if os(tvOS)
                            .focusable()
                            #endif
                    }

                    // Studio / Network
                    studioLine(item)
                        .frame(maxWidth: readingMaxWidth, alignment: .leading)
                        .padding(.horizontal, contentPadding)

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
            if let backdropId = item.backdropItemID {
                CinemaLazyImage(
                    url: appState.imageBuilder.imageURL(itemId: backdropId, imageType: .backdrop, maxWidth: ImageURLBuilder.screenPixelWidth),
                    fallbackIcon: nil,
                    fallbackBackground: CinemaColor.surfaceContainerLow
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
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

                // Community + critic ratings (audience on left, critics on right)
                ratingsRow(item)
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

    // MARK: - Ratings Row (backdrop)

    @ViewBuilder
    private func ratingsRow(_ item: BaseItemDto) -> some View {
        let hasCommunity = item.communityRating != nil
        let hasCritic = item.criticRating != nil

        if hasCommunity || hasCritic {
            HStack(spacing: CinemaSpacing.spacing4) {
                if let rating = item.communityRating {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                        Text(String(format: "%.1f", rating))
                            .fontWeight(.bold)
                    }
                    .font(.system(size: ratingFontSize))
                    .foregroundStyle(CinemaColor.onSurface)
                    .accessibilityLabel("\(loc.localized("detail.audienceRating")) \(String(format: "%.1f", rating))")
                }

                if let critic = item.criticRating {
                    let isFresh = critic >= 60
                    HStack(spacing: 4) {
                        // Rotten Tomatoes-style — green when ≥ 60, red otherwise.
                        Image(systemName: isFresh ? "applescript.fill" : "takeoutbag.and.cup.and.straw.fill")
                            .foregroundStyle(isFresh ? .green : .red)
                        Text("\(Int(critic.rounded()))%")
                            .fontWeight(.bold)
                    }
                    .font(.system(size: ratingFontSize))
                    .foregroundStyle(CinemaColor.onSurface)
                    .accessibilityLabel("\(loc.localized("detail.criticRating")) \(Int(critic.rounded())) percent")
                }
            }
        }
    }

    // MARK: - Studio / Network

    /// Comma-separated list of up to 2 studios (or network label for series).
    /// Rendered below the overview text. Returns `EmptyView` when no studios are present.
    @ViewBuilder
    private func studioLine(_ item: BaseItemDto) -> some View {
        let names = (item.studios ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
        if !names.isEmpty {
            let isSeries = viewModel.resolvedType == .series
            let labelKey = isSeries ? "detail.network" : "detail.studio"
            HStack(alignment: .firstTextBaseline, spacing: CinemaSpacing.spacing2) {
                Text(loc.localized(labelKey))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Text(names.prefix(2).joined(separator: ", "))
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(1)
            }
        }
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

    /// Looks up precomputed prev/next episode refs from the ViewModel's navigation maps.
    private func episodeNavigation(for episodeId: String) -> (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?) {
        if let nav = viewModel.episodeNavigationMap[episodeId] {
            return nav
        }
        if let nav = viewModel.nextUpNavigationMap[episodeId] {
            return nav
        }
        return (nil, nil, nil)
    }

    // MARK: - Action Buttons

    /// Resolves the data `PlayActionButtonsSection` needs. Kept out of the
    /// sub-view so the sub-view's dependencies stay narrow (and its
    /// `Equatable` short-circuit can skip unrelated view-model updates).
    private func actionButtons(_ item: BaseItemDto) -> some View {
        let isSeries = viewModel.resolvedType == .series
        let nextEp: BaseItemDto? = isSeries ? viewModel.nextUpEpisode : nil

        let posTicks: Int = isSeries
            ? (nextEp?.userData?.playbackPositionTicks ?? 0)
            : (item.userData?.playbackPositionTicks ?? 0)
        let totalTicks: Int = isSeries
            ? (nextEp?.runTimeTicks ?? 0)
            : (item.runTimeTicks ?? 0)
        let isPlayed: Bool = isSeries
            ? (nextEp?.userData?.isPlayed ?? false)
            : (item.userData?.isPlayed ?? false)

        let showResume = posTicks > 0 && !isPlayed && totalTicks > 0
        let progress: Double = showResume ? min(1.0, Double(posTicks) / Double(totalTicks)) : 0
        let remainingMinutes = max(0, totalTicks - posTicks).jellyfinMinutes
        let startSeconds: Double? = showResume ? posTicks.jellyfinSeconds : nil

        let playItemId: String = nextEp?.id ?? item.id ?? ""
        let playTitle: String = nextEp?.name ?? item.name ?? ""

        let nextEpisodeLabel: String? = {
            guard let ep = nextEp else { return nil }
            let prefix: String?
            if let season = ep.parentIndexNumber, let num = ep.indexNumber {
                prefix = String(format: "S%02d:E%02d", season, num)
            } else if let num = ep.indexNumber {
                prefix = loc.localized("detail.episode", num)
            } else {
                prefix = nil
            }
            let parts: [String] = [prefix, ep.name].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " - ")
        }()

        let remainingText: String? = showResume ? loc.remainingTime(minutes: remainingMinutes) : nil

        let epNav = nextEp.flatMap { ep -> (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)? in
            guard let id = ep.id else { return nil }
            return episodeNavigation(for: id)
        }

        return PlayActionButtonsSection(
            playItemId: playItemId,
            playTitle: playTitle,
            nextEpisodeLabel: nextEpisodeLabel,
            startSeconds: startSeconds,
            showResume: showResume,
            progress: progress,
            remainingText: remainingText,
            epPrev: epNav?.previous,
            epNext: epNav?.next,
            epNavigator: epNav?.navigator,
            playLabel: loc.localized("detail.play"),
            playFromBeginningLabel: loc.localized("detail.playFromBeginning"),
            buttonFontSize: buttonFontSize,
            buttonVerticalPadding: buttonVerticalPadding,
            playButtonWidth: playButtonWidth,
            contentPadding: contentPadding
        )
        .equatable()
    }

    // MARK: - Cast

    private func castSection(_ people: [BaseItemPerson]) -> some View {
        return ContentRow(
            title: loc.localized("detail.castCrew"),
            data: Array(people.prefix(20)),
            id: \.id
        ) { person in
            CastCircle(
                name: person.name ?? "",
                role: person.role,
                imageURL: person.id.map {
                    appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 200)
                }
            )
        }
    }

    // MARK: - Seasons

    private func seasonsSection(_ item: BaseItemDto) -> some View {
        let seriesId = item.id ?? viewModel.itemId
        let currentSeasonName = viewModel.seasons.first { $0.id == viewModel.selectedSeasonId }?.name
            ?? loc.localized("detail.season")

        return VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            #if os(tvOS)
            // tvOS: horizontal scroll of season pills
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
                        .buttonStyle(SeasonTabButtonStyle(isSelected: isSelected, accent: themeManager.accent))
                        .focusEffectDisabled()
                        .hoverEffectDisabled()
                    }
                }
                .padding(.horizontal, contentPadding)
            }
            // tvOS: vertical list of unified episode rows
            VStack(spacing: 12) {
                ForEach(viewModel.episodes, id: \.id) { episode in
                    episodeRow(episode)
                }
            }
            .padding(.horizontal, contentPadding)
            #else
            // iOS: dropdown Menu for season selection
            Menu {
                ForEach(viewModel.seasons, id: \.id) { season in
                    Button {
                        if let id = season.id {
                            Task { await viewModel.selectSeason(id, seriesId: seriesId, using: appState) }
                        }
                    } label: {
                        Text(season.name ?? loc.localized("detail.season"))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentSeasonName)
                        .font(.system(size: seasonTabFontSize, weight: .bold))
                        .foregroundStyle(themeManager.accent)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(themeManager.accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(CinemaColor.surfaceContainerHigh)
                .clipShape(Capsule())
            }
            .padding(.horizontal, contentPadding)
            // iOS: horizontal scroll of episode cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(viewModel.episodes, id: \.id) { episode in
                        iOSEpisodeCard(episode)
                            .containerRelativeFrame(.horizontal) { w, _ in w - contentPadding * 2 - 32 }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, contentPadding)
            }
            .scrollTargetBehavior(.viewAligned)
            #endif
        }
    }

    // MARK: - iOS Episode Card (horizontal scroll, vertical layout)

    #if os(iOS)
    @ViewBuilder
    private func iOSEpisodeCard(_ episode: BaseItemDto) -> some View {
        if let id = episode.id {
            let (epPrev, epNext, epNavigator) = episodeNavigation(for: id)
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
                                url: appState.imageBuilder.imageURL(itemId: id, imageType: .primary, maxWidth: 600),
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
                                    .font(.system(size: 28, weight: .semibold))
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
                    if let num = episode.indexNumber {
                        Text(loc.localized("detail.episode", num))
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }
                    Text(episode.name ?? "")
                        .font(.system(size: episodeTitleFontSize, weight: .bold))
                        .foregroundStyle(CinemaColor.onSurface)
                        .lineLimit(2)

                    episodeMetadataLine(episode)

                    if let ov = overview {
                        Text(ov)
                            .font(CinemaFont.dynamicBody)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .lineLimit(3)
                            .padding(.top, 2)
                        Button {
                            episodeOverview = EpisodeOverviewItem(id: id, title: episode.name ?? "", overview: ov)
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
    #endif

    // MARK: - tvOS Episode Row (unified card with two focusable zones)

    #if os(tvOS)
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
                            episodeMetadataLine(episode)
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
                        episodeOverview = EpisodeOverviewItem(id: id, title: episode.name ?? "", overview: ov)
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
    #endif

    // MARK: - Shared Episode Metadata Line

    /// Small secondary-text line under an episode title combining "X min remaining" (or runtime)
    /// with the air date. Returns `EmptyView` when nothing meaningful is available.
    @ViewBuilder
    private func episodeMetadataLine(_ episode: BaseItemDto) -> some View {
        let isPlayed = episode.userData?.isPlayed ?? false
        let runtimeText: String? = {
            // Prefer "X remaining" while in-progress, otherwise show total runtime.
            if !isPlayed,
               let position = episode.userData?.playbackPositionTicks,
               let total = episode.runTimeTicks,
               position > 0, total > position {
                let remainingMinutes = (total - position).jellyfinMinutes
                if remainingMinutes <= 0 { return nil }
                return loc.remainingTime(minutes: remainingMinutes)
            }
            if let runtime = episode.runTimeTicks, runtime > 0 {
                return loc.localized("detail.runtime.min", runtime.jellyfinMinutes)
            }
            return nil
        }()

        let dateText: String? = episode.premiereDate.map {
            $0.formatted(.dateTime.month(.abbreviated).day().year())
        }

        let parts: [String] = [runtimeText, dateText].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " • "))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
    }

    // MARK: - Similar Items

    private var similarSection: some View {
        return ContentRow(
            title: loc.localized("detail.moreLikeThis"),
            data: viewModel.similarItems,
            id: \.id
        ) { item in
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
        AdaptiveLayout.detailBackdropHeight(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
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
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    /// Max width for prose blocks (overview, studio line) on wide screens so lines stay readable.
    /// Horizontal carousels (cast, similar, episodes) intentionally ignore this and use full width.
    private var readingMaxWidth: CGFloat {
        #if os(tvOS)
        .infinity
        #else
        AdaptiveLayout.readingMaxWidth(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass)) ?? .infinity
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

// MARK: - Episode Overview

private struct EpisodeOverviewItem: Identifiable {
    let id: String
    let title: String
    let overview: String
}

private struct EpisodeOverviewSheet: View {
    let item: EpisodeOverviewItem
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(themeManager.accentContainer)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                Text(item.title)
                    .font(.system(size: 17, weight: .bold))
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

// MARK: - Play Action Buttons

/// Progress bar + "Play" / "Play from beginning" buttons for the detail screen.
/// Extracted as an Equatable sub-view so `SeasonId`/`episodes` changes on the
/// parent view model don't re-evaluate the play-button tree (the only inputs
/// that actually change what this renders are the resume state and the next
/// episode identity).
private struct PlayActionButtonsSection: View, Equatable {
    let playItemId: String
    let playTitle: String
    let nextEpisodeLabel: String?
    let startSeconds: Double?
    let showResume: Bool
    let progress: Double
    let remainingText: String?
    let epPrev: EpisodeRef?
    let epNext: EpisodeRef?
    let epNavigator: EpisodeNavigator?

    let playLabel: String
    let playFromBeginningLabel: String

    let buttonFontSize: CGFloat
    let buttonVerticalPadding: CGFloat
    let playButtonWidth: CGFloat
    let contentPadding: CGFloat

    @Environment(ThemeManager.self) private var themeManager

    // Equatable ignores the navigator closure — fresh closures that carry the
    // same prev/next identity are treated as equal so the sub-view doesn't
    // thrash when the parent rebuilds a functionally-identical navigator.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.playItemId == rhs.playItemId
            && lhs.playTitle == rhs.playTitle
            && lhs.nextEpisodeLabel == rhs.nextEpisodeLabel
            && lhs.startSeconds == rhs.startSeconds
            && lhs.showResume == rhs.showResume
            && lhs.progress == rhs.progress
            && lhs.remainingText == rhs.remainingText
            && lhs.epPrev?.id == rhs.epPrev?.id
            && lhs.epNext?.id == rhs.epNext?.id
            && lhs.playLabel == rhs.playLabel
            && lhs.playFromBeginningLabel == rhs.playFromBeginningLabel
            && lhs.buttonFontSize == rhs.buttonFontSize
            && lhs.buttonVerticalPadding == rhs.buttonVerticalPadding
            && lhs.playButtonWidth == rhs.playButtonWidth
            && lhs.contentPadding == rhs.contentPadding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            if let label = nextEpisodeLabel {
                Text(label)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(1)
            }

            if showResume {
                ProgressBarView(progress: progress)
                    .frame(width: playButtonWidth)

                if let remainingText {
                    Text(remainingText)
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }

            if !playItemId.isEmpty {
                PlayLink(
                    itemId: playItemId, title: playTitle, startTime: startSeconds,
                    previousEpisode: epPrev, nextEpisode: epNext,
                    episodeNavigator: epNavigator
                ) {
                    HStack(spacing: CinemaSpacing.spacing2) {
                        Text(playLabel)
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

                if showResume {
                    PlayLink(
                        itemId: playItemId, title: playTitle, startTime: nil,
                        previousEpisode: epPrev, nextEpisode: epNext,
                        episodeNavigator: epNavigator
                    ) {
                        HStack(spacing: CinemaSpacing.spacing2) {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: buttonFontSize - 2, weight: .bold))
                            Text(playFromBeginningLabel)
                                .font(.system(size: buttonFontSize, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(CinemaColor.onSurface)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, buttonVerticalPadding)
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
                    .frame(width: playButtonWidth)
                }
            }
        }
        .padding(.horizontal, contentPadding)
    }
}

// MARK: - tvOS Button Styles

#if os(tvOS)
/// Focus indicator for an individual zone inside a shared card background.
/// Shows an accent stroke around the focused zone without adding its own background.
private struct TVEpisodeZoneButtonStyle: ButtonStyle {
    let accent: Color
    @Environment(\.isFocused) private var isFocused
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(isFocused ? 0.06 : 0)
            .overlay(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .strokeBorder(accent.opacity(isFocused ? 0.75 : 0), lineWidth: 2)
                    .padding(1)
            )
            .animation(motionEnabled ? .easeOut(duration: 0.15) : nil, value: isFocused)
    }
}

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
