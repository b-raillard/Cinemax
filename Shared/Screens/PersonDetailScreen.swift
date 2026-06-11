import SwiftUI
import CinemaxKit
import JellyfinAPI

// MARK: - Person Detail

/// Person page reached from the cast carousel: portrait + bio + filmography
/// (persons are Jellyfin items, so the bio comes from a regular `getItem` and
/// the filmography from `getPersonItems`). Shared iOS/tvOS — the layout is a
/// simple editorial scroll, sized through `CinemaScale`-aware tokens.
struct PersonDetailScreen: View {
    let personId: String
    let personName: String

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc

    @State private var person: BaseItemDto?
    @State private var movies: [BaseItemDto] = []
    @State private var series: [BaseItemDto] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    #if os(tvOS)
    private let portraitSize: CGFloat = 280
    private let cardWidth: CGFloat = 220
    #else
    private let portraitSize: CGFloat = 132
    private let cardWidth: CGFloat = 130
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                header
                if let overview = person?.overview, !overview.isEmpty {
                    Text(overview)
                        .font(CinemaFont.dynamicBody)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .padding(.horizontal, CinemaSpacing.spacing5)
                }
                if let errorMessage {
                    ErrorStateView(
                        message: errorMessage,
                        retryTitle: loc.localized("action.retry")
                    ) {
                        Task { await load(force: true) }
                    }
                } else if isLoading && movies.isEmpty && series.isEmpty {
                    LoadingStateView()
                        .frame(maxWidth: .infinity)
                } else {
                    if !movies.isEmpty {
                        filmographyRow(title: loc.localized("person.movies"), items: movies)
                    }
                    if !series.isEmpty {
                        filmographyRow(title: loc.localized("person.series"), items: series)
                    }
                    if movies.isEmpty && series.isEmpty {
                        EmptyStateView(
                            systemImage: "person.fill",
                            title: loc.localized("person.empty")
                        )
                    }
                }
            }
            .padding(.vertical, CinemaSpacing.spacing6)
        }
        .background(CinemaColor.surface)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load(force: false) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: CinemaSpacing.spacing5) {
            CinemaLazyImage(
                url: appState.imageBuilder.imageURL(
                    itemId: personId, imageType: .primary,
                    maxWidth: 400, tag: person?.primaryImageTagValue
                ),
                fallbackIcon: "person.fill",
                fallbackBackground: CinemaColor.surfaceContainerHigh
            )
            .frame(width: portraitSize, height: portraitSize)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                Text(personName)
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                if let birth = person?.premiereDate {
                    Text(String(format: loc.localized("person.born"), birth.formatted(date: .long, time: .omitted)))
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
                let count = movies.count + series.count
                if count > 0 {
                    Text(String(format: loc.localized("person.titleCount"), count))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
            Spacer()
        }
        .padding(.horizontal, CinemaSpacing.spacing5)
    }

    private func filmographyRow(title: String, items: [BaseItemDto]) -> some View {
        ContentRow(title: title, data: items, id: \.id) { item in
            NavigationLink {
                if let id = item.id {
                    MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
                }
            } label: {
                PosterCard(
                    title: item.name ?? "",
                    imageURL: item.id.map {
                        appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300, tag: item.primaryImageTagValue)
                    },
                    subtitle: item.productionYear.map(String.init)
                )
                .frame(width: cardWidth)
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVCardButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel([item.name, item.productionYear.map(String.init)].compactMap { $0 }.joined(separator: ", "))
        }
    }

    private func load(force: Bool) async {
        if hasLoaded && !force { return }
        hasLoaded = true
        guard let userId = appState.currentUserId else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let personTask = appState.apiClient.getItem(userId: userId, itemId: personId)
            async let itemsTask = appState.apiClient.getPersonItems(personId: personId, userId: userId)
            person = try? await personTask
            let items = try await itemsTask
            movies = items.filter { $0.type == .movie }
            series = items.filter { $0.type == .series }
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
        }
        isLoading = false
    }
}
