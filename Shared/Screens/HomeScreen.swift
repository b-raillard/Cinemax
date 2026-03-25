import SwiftUI
import NukeUI
import CinemaxKit
import JellyfinAPI

@MainActor @Observable
final class HomeViewModel {
    var heroItem: BaseItemDto?
    var resumeItems: [BaseItemDto] = []
    var latestItems: [BaseItemDto] = []
    var isLoading = true
    var errorMessage: String?

    func load(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        isLoading = true

        do {
            async let resume = appState.apiClient.getResumeItems(userId: userId, limit: 10)
            async let latest = appState.apiClient.getLatestMedia(userId: userId, limit: 16)

            resumeItems = try await resume
            latestItems = try await latest

            // Pick first resume item or first latest as hero
            heroItem = resumeItems.first ?? latestItems.first
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

struct HomeScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State private var viewModel = HomeViewModel()

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            if viewModel.isLoading {
                ProgressView()
                    .tint(CinemaColor.onSurfaceVariant)
                    .scaleEffect(1.5)
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
            LazyVStack(spacing: CinemaSpacing.spacing6) {
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
        let serverURL = appState.serverURL ?? URL(string: "http://localhost")!
        let builder = ImageURLBuilder(serverURL: serverURL)

        ZStack(alignment: .bottomLeading) {
            // Backdrop — episodes/seasons don't have their own backdrop; use the parent (series)
            if let backdropId = item.parentBackdropItemID ?? item.seriesID ?? item.id {
                LazyImage(url: builder.imageURL(itemId: backdropId, imageType: .backdrop, maxWidth: 1920)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(CinemaColor.surfaceContainerLow)
                    }
                }
            }

            // Gradient overlays
            CinemaGradient.heroOverlay

            // Content
            VStack(alignment: .leading, spacing: heroPadding > 60 ? 16 : 10) {
                // Badges
                HStack(spacing: 8) {
                    if let rating = item.officialRating {
                        Text(rating)
                            .font(.system(size: badgeFontSize, weight: .bold))
                            .tracking(1)
                            .textCase(.uppercase)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
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

                // Overview
                if let overview = item.overview {
                    Text(overview)
                        .font(.system(size: overviewFontSize))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(3)
                        .frame(maxWidth: maxOverviewWidth, alignment: .leading)
                }

                // Action buttons
                HStack(spacing: 12) {
                    if let id = item.id {
                        PlayLink(itemId: id, title: item.name ?? "") {
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
            .padding(heroPadding)
            .padding(.bottom, CinemaSpacing.spacing6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .clipped()
    }

    // MARK: - Continue Watching

    private var continueWatchingRow: some View {
        ContentRow(title: loc.localized("home.continueWatching"), showViewAll: true) {
            ForEach(viewModel.resumeItems, id: \.id) { item in
                if let id = item.id {
                    PlayLink(itemId: id, title: item.name ?? "") {
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
        let serverURL = appState.serverURL ?? URL(string: "http://localhost")!
        let builder = ImageURLBuilder(serverURL: serverURL)

        let progress: Double = {
            guard let position = item.userData?.playbackPositionTicks,
                  let total = item.runTimeTicks,
                  total > 0 else { return 0 }
            return Double(position) / Double(total)
        }()

        let remaining: String = {
            guard let position = item.userData?.playbackPositionTicks,
                  let total = item.runTimeTicks else { return "" }
            let remainingTicks = total - position
            let minutes = remainingTicks / 600_000_000
            if minutes > 60 {
                return loc.localized("home.remainingTime.hours", minutes / 60, minutes % 60)
            }
            return loc.localized("home.remainingTime.minutes", minutes)
        }()

        WideCard(
            title: item.name ?? "",
            imageURL: (item.parentBackdropItemID ?? item.seriesID ?? item.id).map { builder.imageURL(itemId: $0, imageType: .backdrop, maxWidth: 600) },
            progress: progress,
            subtitle: remaining
        )
    }

    // MARK: - Recently Added

    private var recentlyAddedRow: some View {
        ContentRow(title: loc.localized("home.recentlyAdded"), showViewAll: true) {
            ForEach(viewModel.latestItems, id: \.id) { item in
                recentlyAddedCard(item)
                    .frame(width: posterCardWidth)
            }
        }
    }

    @ViewBuilder
    private func recentlyAddedCard(_ item: BaseItemDto) -> some View {
        let serverURL = appState.serverURL ?? URL(string: "http://localhost")!
        let builder = ImageURLBuilder(serverURL: serverURL)

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
                imageURL: item.id.map { builder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300) },
                subtitle: subtitle
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
    }

    // MARK: - Helpers

    private func metadataText(for item: BaseItemDto) -> some View {
        let parts: [String] = [
            item.productionYear.map(String.init),
            item.runTimeTicks.map { ticks in
                let minutes = ticks / 600_000_000
                return minutes > 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
            },
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
        500
        #endif
    }

    private var heroTitleSize: CGFloat {
        #if os(tvOS)
        72
        #else
        40
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

    private var badgeFontSize: CGFloat {
        #if os(tvOS)
        12
        #else
        10
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
