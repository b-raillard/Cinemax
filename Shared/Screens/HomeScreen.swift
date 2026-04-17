import SwiftUI
import CinemaxKit
import JellyfinAPI

struct HomeScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State private var viewModel = HomeViewModel()

    @AppStorage("home.showContinueWatching") private var showContinueWatching: Bool = true
    @AppStorage("home.showRecentlyAdded") private var showRecentlyAdded: Bool = true
    @AppStorage("home.showGenreRows") private var showGenreRows: Bool = true
    @AppStorage("home.showWatchingNow") private var showWatchingNow: Bool = true

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            if viewModel.isLoading {
                LoadingStateView()
            } else if isHomeEmpty {
                homeEmptyState
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
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxShouldRefreshCatalogue)) { _ in
            Task { await viewModel.reload(using: appState) }
        }
    }

    /// True when there's no hero, no resume items, no recently added items, and no genre rows.
    /// Happens on a fresh Jellyfin install or a server with no media.
    private var isHomeEmpty: Bool {
        viewModel.heroItem == nil
            && viewModel.resumeItems.isEmpty
            && viewModel.latestItems.isEmpty
            && viewModel.genreRows.isEmpty
    }

    private var homeEmptyState: some View {
        ScrollView {
            EmptyStateView(
                systemImage: "tv.slash",
                title: loc.localized("empty.home.title"),
                subtitle: loc.localized("empty.home.subtitle"),
                actionTitle: loc.localized("action.refresh")
            ) {
                Task { await viewModel.reload(using: appState) }
            }
            .padding(.top, CinemaSpacing.spacing20)
        }
        .refreshable { await viewModel.reload(using: appState) }
    }

    private var content: some View {
        // Wrap in `ScrollViewReader` so that on tvOS we can scroll back to the
        // top sentinel whenever the screen reappears (after a deep-nav pop or
        // tab switch). Without this the tvOS top tab bar can be hidden behind
        // scrolled content and the user can't reach it with the remote.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                    // Sentinel for `proxy.scrollTo(_:anchor:)`
                    Color.clear.frame(height: 0).id(scrollTopID)

                    // Hero
                    if let hero = viewModel.heroItem {
                        heroSection(hero)
                    }

                    // Watching Now (other users on the server)
                    if showWatchingNow, !viewModel.activeSessions.isEmpty {
                        watchingNowRow
                    }

                    // Continue Watching
                    if showContinueWatching, !viewModel.resumeItems.isEmpty {
                        continueWatchingRow
                    }

                    // Recently Added
                    if showRecentlyAdded, !viewModel.latestItems.isEmpty {
                        recentlyAddedRow
                    }

                    // Genre rows
                    if showGenreRows {
                        ForEach(viewModel.genreRows, id: \.genre) { row in
                            genreRow(genre: row.genre, items: row.items)
                        }
                    }

                    Spacer(minLength: 80)
                }
            }
            .refreshable {
                await viewModel.reload(using: appState)
            }
            #if os(tvOS)
            .scrollClipDisabled()
            .onAppear {
                // Returning from a deep navigation (e.g., MediaDetail → Menu) —
                // reveal the top tab bar by scrolling to the sentinel.
                proxy.scrollTo(scrollTopID, anchor: .top)
            }
            #endif
        }
    }

    private var scrollTopID: String { "home.top" }

    // MARK: - Genre Rows

    @ViewBuilder
    private func genreRow(genre: String, items: [BaseItemDto]) -> some View {
        ContentRow(title: genre, data: items, id: \.id) { item in
            recentlyAddedCard(item)
                .frame(width: posterCardWidth)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(_ item: BaseItemDto) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Backdrop — episodes/seasons don't have their own backdrop; use the parent (series)
            if let backdropId = item.parentBackdropItemID ?? item.seriesID ?? item.id {
                CinemaLazyImage(
                    url: appState.imageBuilder.imageURL(itemId: backdropId, imageType: .backdrop, maxWidth: ImageURLBuilder.screenPixelWidth),
                    fallbackIcon: nil,
                    fallbackBackground: CinemaColor.surfaceContainerLow
                )
                .accessibilityHidden(true)
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

    // MARK: - Watching Now (other users)

    /// Small row showing other server users' active playback sessions. Each card shows
    /// the item artwork + "Name is watching" label, and navigates to the item's detail
    /// screen on tap. Hidden entirely when the server has no other active sessions.
    private var watchingNowRow: some View {
        ContentRow(
            title: loc.localized("home.watchingNow"),
            data: Array(viewModel.activeSessions.indices),
            id: \.self
        ) { idx in
            watchingNowCard(viewModel.activeSessions[idx])
                .frame(width: wideCardWidth)
        }
    }

    @ViewBuilder
    private func watchingNowCard(_ session: SessionInfoDto) -> some View {
        if let item = session.nowPlayingItem, let id = item.id {
            // Episodes → use parent series for backdrop; fall back to the episode itself.
            let backdropId = item.parentBackdropItemID ?? item.seriesID ?? id
            let title = (item.seriesName ?? item.name) ?? ""
            let subtitle = String(format: loc.localized("home.watchingNow.playing"), session.userName ?? "")

            NavigationLink {
                MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
            } label: {
                WideCard(
                    title: title,
                    imageURL: appState.imageBuilder.imageURL(itemId: backdropId, imageType: .backdrop, maxWidth: 600),
                    progress: sessionProgress(session),
                    subtitle: subtitle
                )
                .overlay(alignment: .topLeading) {
                    // Small red "LIVE" pill to signal this is a session, not a recommendation.
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
                }
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVCardButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel("\(title), \(subtitle)")
        }
    }

    private func sessionProgress(_ session: SessionInfoDto) -> Double {
        guard let position = session.playState?.positionTicks,
              let total = session.nowPlayingItem?.runTimeTicks,
              total > 0 else { return 0 }
        return min(1.0, Double(position) / Double(total))
    }

    private var continueWatchingRow: some View {
        ContentRow(
            title: loc.localized("home.continueWatching"),
            data: viewModel.resumeItems,
            id: \.id
        ) { item in
            continueWatchingPlayLink(item)
        }
    }

    @ViewBuilder
    private func continueWatchingPlayLink(_ item: BaseItemDto) -> some View {
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
            .accessibilityLabel(item.name ?? "")
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
        ContentRow(
            title: loc.localized("home.recentlyAdded"),
            data: viewModel.latestItems,
            id: \.id
        ) { item in
            recentlyAddedCard(item)
                .frame(width: posterCardWidth)
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
