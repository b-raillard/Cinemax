import SwiftUI
import NukeUI
import CinemaxKit
import JellyfinAPI

@MainActor @Observable
final class MediaDetailViewModel {
    var item: BaseItemDto?
    var similarItems: [BaseItemDto] = []
    var seasons: [BaseItemDto] = []
    var episodes: [BaseItemDto] = []
    var selectedSeasonId: String?
    var isLoading = true
    var errorMessage: String?

    // The resolved type after loading (episode/season → series)
    var resolvedType: BaseItemKind = .movie

    let itemId: String
    let itemType: BaseItemKind

    init(itemId: String, itemType: BaseItemKind) {
        self.itemId = itemId
        self.itemType = itemType
    }

    func load(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        isLoading = true

        do {
            let loadedItem = try await appState.apiClient.getItem(userId: userId, itemId: itemId)

            // Resolve episodes/seasons to their parent series for full detail
            let effectiveType = loadedItem.type ?? itemType
            if effectiveType == .episode || effectiveType == .season,
               let seriesId = loadedItem.seriesID {
                let seriesItem = try await appState.apiClient.getItem(userId: userId, itemId: seriesId)
                item = seriesItem
                resolvedType = .series

                async let similar = appState.apiClient.getSimilarItems(itemId: seriesId, userId: userId, limit: 12)
                similarItems = try await similar

                seasons = try await appState.apiClient.getSeasons(seriesId: seriesId, userId: userId)
                if let firstSeason = seasons.first, let seasonId = firstSeason.id {
                    selectedSeasonId = seasonId
                    episodes = try await appState.apiClient.getEpisodes(seriesId: seriesId, seasonId: seasonId, userId: userId)
                }
            } else {
                item = loadedItem
                resolvedType = effectiveType

                async let similar = appState.apiClient.getSimilarItems(itemId: itemId, userId: userId, limit: 12)
                similarItems = try await similar

                if effectiveType == .series {
                    seasons = try await appState.apiClient.getSeasons(seriesId: itemId, userId: userId)
                    if let firstSeason = seasons.first, let seasonId = firstSeason.id {
                        selectedSeasonId = seasonId
                        episodes = try await appState.apiClient.getEpisodes(seriesId: itemId, seasonId: seasonId, userId: userId)
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func selectSeason(_ seasonId: String, seriesId: String, using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        selectedSeasonId = seasonId
        do {
            episodes = try await appState.apiClient.getEpisodes(seriesId: seriesId, seasonId: seasonId, userId: userId)
        } catch {
            // Keep existing episodes on error
        }
    }
}

struct MediaDetailScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State var viewModel: MediaDetailViewModel

    init(itemId: String, itemType: BaseItemKind = .movie) {
        _viewModel = State(initialValue: MediaDetailViewModel(itemId: itemId, itemType: itemType))
    }

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            if viewModel.isLoading {
                ProgressView()
                    .tint(CinemaColor.onSurfaceVariant)
                    .scaleEffect(1.5)
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
    }

    // MARK: - Detail Content

    private func detailContent(_ item: BaseItemDto) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
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
        let serverURL = appState.serverURL ?? URL(string: "http://localhost")!
        let builder = ImageURLBuilder(serverURL: serverURL)

        ZStack(alignment: .bottomLeading) {
            if let backdropId = item.parentBackdropItemID ?? item.seriesID ?? item.id {
                LazyImage(url: builder.imageURL(itemId: backdropId, imageType: .backdrop, maxWidth: 1920)) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(CinemaColor.surfaceContainerLow)
                    }
                }
            }

            CinemaGradient.heroOverlay

            VStack(alignment: .leading, spacing: detailHeroSpacing) {
                // Badges
                HStack(spacing: 8) {
                    if let rating = item.officialRating {
                        Text(rating)
                            .font(.system(size: badgeFontSize, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
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
            .padding(contentPadding)
            .padding(.bottom, CinemaSpacing.spacing4)
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
                let minutes = ticks / 600_000_000
                return minutes > 60 ? loc.localized("detail.runtime.hours", minutes / 60, minutes % 60) : loc.localized("detail.runtime.minutes", minutes)
            },
            viewModel.resolvedType == .series ? item.childCount.map { loc.localized("detail.seasons", $0) } : nil
        ].compactMap { $0 }

        return Text(parts.joined(separator: " · "))
            .font(.system(size: metadataFontSize, weight: .medium))
    }

    // MARK: - Action Buttons

    private func actionButtons(_ item: BaseItemDto) -> some View {
        HStack(spacing: actionButtonSpacing) {
            if let id = item.id {
                PlayLink(itemId: id, title: item.name ?? "") {
                    HStack(spacing: CinemaSpacing.spacing2) {
                        Text(loc.localized("detail.play"))
                            .font(.system(size: buttonFontSize, weight: .bold))
                        Image(systemName: "play.fill")
                            .font(.system(size: buttonFontSize - 2, weight: .bold))
                    }
                    .foregroundStyle(CinemaColor.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, buttonVerticalPadding)
                    .padding(.horizontal, CinemaSpacing.spacing4)
                    #if os(iOS)
                    .background(CinemaGradient.primaryButton)
                    .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                    #endif
                }
                #if os(tvOS)
                .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .primary))
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
        let serverURL = appState.serverURL ?? URL(string: "http://localhost")!
        let builder = ImageURLBuilder(serverURL: serverURL)

        return ContentRow(title: loc.localized("detail.castCrew")) {
            ForEach(people.prefix(20), id: \.id) { person in
                CastCircle(
                    name: person.name ?? "",
                    role: person.role,
                    imageURL: person.id.map {
                        builder.imageURL(itemId: $0, imageType: .primary, maxWidth: 200)
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
        let serverURL = appState.serverURL ?? URL(string: "http://localhost")!
        let builder = ImageURLBuilder(serverURL: serverURL)

        if let id = episode.id {
            PlayLink(itemId: id, title: episode.name ?? "") {
                HStack(spacing: 12) {
                    // Thumbnail
                    LazyImage(url: builder.imageURL(itemId: id, imageType: .primary, maxWidth: 300)) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(CinemaColor.surfaceContainerHigh)
                                .overlay {
                                    Image(systemName: "play.circle")
                                        .foregroundStyle(CinemaColor.outlineVariant)
                                }
                        }
                    }
                    .frame(width: episodeThumbnailWidth, height: episodeThumbnailWidth * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))

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
                            let minutes = runtime / 600_000_000
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
        }
    }

    // MARK: - Similar Items

    private var similarSection: some View {
        let serverURL = appState.serverURL ?? URL(string: "http://localhost")!
        let builder = ImageURLBuilder(serverURL: serverURL)

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
                        imageURL: item.id.map { builder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300) },
                        subtitle: item.productionYear.map(String.init)
                    )
                    .frame(width: similarCardWidth)
                }
                #if os(tvOS)
                .buttonStyle(CinemaTVCardButtonStyle())
                #else
                .buttonStyle(.plain)
                #endif
            }
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: CinemaSpacing.spacing3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(CinemaColor.error)
            Text(message)
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
            CinemaButton(title: loc.localized("action.retry"), style: .ghost) {
                Task { await viewModel.load(using: appState) }
            }
            .frame(width: 160)
        }
    }

    // MARK: - Adaptive Sizing

    private var backdropHeight: CGFloat {
        #if os(tvOS)
        760
        #else
        420
        #endif
    }

    private var detailTitleSize: CGFloat {
        #if os(tvOS)
        56
        #else
        32
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

    private var badgeFontSize: CGFloat {
        #if os(tvOS)
        14
        #else
        11
        #endif
    }

    private var metadataFontSize: CGFloat {
        #if os(tvOS)
        16
        #else
        13
        #endif
    }

    private var genreFontSize: CGFloat {
        #if os(tvOS)
        16
        #else
        13
        #endif
    }

    private var ratingFontSize: CGFloat {
        #if os(tvOS)
        18
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
        220
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
        18
        #else
        15
        #endif
    }

    private var seasonTabFontSize: CGFloat {
        #if os(tvOS)
        18
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
