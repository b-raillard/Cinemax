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
            async let detail = appState.apiClient.getItem(userId: userId, itemId: itemId)
            async let similar = appState.apiClient.getSimilarItems(itemId: itemId, userId: userId, limit: 12)

            item = try await detail
            similarItems = try await similar

            // Load seasons for series
            if itemType == .series {
                seasons = try await appState.apiClient.getSeasons(seriesId: itemId, userId: userId)
                if let firstSeason = seasons.first, let seasonId = firstSeason.id {
                    selectedSeasonId = seasonId
                    episodes = try await appState.apiClient.getEpisodes(seriesId: itemId, seasonId: seasonId, userId: userId)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func selectSeason(_ seasonId: String, using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        selectedSeasonId = seasonId
        do {
            episodes = try await appState.apiClient.getEpisodes(seriesId: itemId, seasonId: seasonId, userId: userId)
        } catch {
            // Keep existing episodes on error
        }
    }
}

struct MediaDetailScreen: View {
    @Environment(AppState.self) private var appState
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
                    }

                    // Cast
                    if let people = item.people, !people.isEmpty {
                        castSection(people)
                    }

                    // Seasons & Episodes (for series)
                    if viewModel.itemType == .series, !viewModel.seasons.isEmpty {
                        seasonsSection
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
            if let id = item.id {
                LazyImage(url: builder.imageURL(itemId: id, imageType: .backdrop, maxWidth: 1920)) { state in
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
                        .foregroundStyle(CinemaColor.tertiary)
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
                return minutes > 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
            },
            viewModel.itemType == .series ? item.childCount.map { "\($0) Seasons" } : nil
        ].compactMap { $0 }

        return Text(parts.joined(separator: " · "))
            .font(.system(size: metadataFontSize, weight: .medium))
    }

    // MARK: - Action Buttons

    private func actionButtons(_ item: BaseItemDto) -> some View {
        HStack(spacing: 12) {
            NavigationLink {
                if let id = item.id {
                    VideoPlayerView(itemId: id, title: item.name ?? "")
                }
            } label: {
                HStack(spacing: CinemaSpacing.spacing2) {
                    Text("Play")
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

            CinemaButton(title: "More Info", style: .ghost, icon: "info.circle") {}
                .frame(width: playButtonWidth)
        }
        .padding(.horizontal, contentPadding)
    }

    // MARK: - Cast

    private func castSection(_ people: [BaseItemPerson]) -> some View {
        let serverURL = appState.serverURL ?? URL(string: "http://localhost")!
        let builder = ImageURLBuilder(serverURL: serverURL)

        return ContentRow(title: "Cast & Crew") {
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

    private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            // Season picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.seasons, id: \.id) { season in
                        let isSelected = season.id == viewModel.selectedSeasonId
                        Button {
                            if let id = season.id {
                                Task { await viewModel.selectSeason(id, using: appState) }
                            }
                        } label: {
                            Text(season.name ?? "Season")
                                .font(.system(size: seasonTabFontSize, weight: isSelected ? .bold : .medium))
                                .foregroundStyle(isSelected ? .white : CinemaColor.onSurfaceVariant)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    isSelected
                                        ? Capsule().fill(CinemaColor.tertiaryContainer)
                                        : Capsule().fill(CinemaColor.surfaceContainerHigh)
                                )
                        }
                        #if os(tvOS)
                        .buttonStyle(.plain)
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

        NavigationLink {
            if let id = episode.id {
                VideoPlayerView(itemId: id, title: episode.name ?? "")
            }
        } label: {
            HStack(spacing: 12) {
                // Thumbnail
                if let id = episode.id {
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
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let num = episode.indexNumber {
                        Text("Episode \(num)")
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.tertiary)
                    }
                    Text(episode.name ?? "")
                        .font(.system(size: episodeTitleFontSize, weight: .semibold))
                        .foregroundStyle(CinemaColor.onSurface)
                        .lineLimit(2)

                    if let runtime = episode.runTimeTicks {
                        let minutes = runtime / 600_000_000
                        Text("\(minutes) min")
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

    // MARK: - Similar Items

    private var similarSection: some View {
        let serverURL = appState.serverURL ?? URL(string: "http://localhost")!
        let builder = ImageURLBuilder(serverURL: serverURL)

        return ContentRow(title: "More Like This") {
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
            CinemaButton(title: "Retry", style: .ghost) {
                Task { await viewModel.load(using: appState) }
            }
            .frame(width: 160)
        }
    }

    // MARK: - Adaptive Sizing

    private var backdropHeight: CGFloat {
        #if os(tvOS)
        700
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
