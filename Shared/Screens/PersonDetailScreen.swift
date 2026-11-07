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
    @Environment(NetworkMonitor.self) private var network
    @Environment(ToastCenter.self) private var toasts
    /// Seerr's « Pas encore dans ta bibliothèque ». Optional, like the fiche's:
    /// a host without them loses the section, never crashes.
    @Environment(SeerrSession.self) private var seerr: SeerrSession?
    @Environment(SeerrRequestPresenter.self) private var seerrRequests: SeerrRequestPresenter?
    @Environment(ProFeatureAccess.self) private var proAccess: ProFeatureAccess?

    @State private var seerrModel = PersonDetailSeerrModel()
    @State private var person: BaseItemDto?
    @State private var movies: [BaseItemDto] = []
    @State private var series: [BaseItemDto] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    /// Card → fiche zoom (iOS) — see `CardZoom`.
    @Namespace private var zoomNamespace
    #if os(tvOS)
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.motionEffectsEnabled) private var motionEffects
    @FocusState private var portraitFocused: Bool
    #endif

    #if os(tvOS)
    private let portraitSize: CGFloat = CinemaTVLayout.personPortraitSize
    private let cardWidth: CGFloat = CinemaTVLayout.filmographyCardWidth
    /// The page margin, so the portrait, the biography and the filmography
    /// rails share one left edge. `ContentRow` draws its rails at the tvOS page
    /// margin; leaving this page's own content at `spacing5` (28 pt) would set
    /// the header 84 pt inboard of the rows under it.
    private let pagePadding: CGFloat = CinemaTVLayout.pagePadding
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let portraitSize: CGFloat = 132
    private let cardWidth: CGFloat = 130
    /// The page column `ContentRow` draws its filmography rails at — 16 pt on
    /// iPhone, 32 on iPad. A fixed 28 pt left the header and biography on
    /// another left edge than the rails under them (recette 2026-10-08, M3-01).
    private var pagePadding: CGFloat {
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                header
                if let overview = person?.overview, !overview.isEmpty {
                    Text(overview)
                        .font(CinemaFont.dynamicBody)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .padding(.horizontal, pagePadding)
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
                    // AFTER everything the library owns — under the empty
                    // state too, as in the search: nothing on screen moves
                    // when Seerr answers.
                    missingTitlesRow
                }
            }
            .padding(.vertical, CinemaSpacing.spacing6)
        }
        #if os(tvOS)
        // The filmography rails' focused card grows 1.06×; without this the
        // vertical scroll clips that growth at its own edges.
        .scrollClipDisabled()
        #endif
        .background(CinemaColor.surface)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            // Before the load, which reads them (same wiring as the fiche):
            // wired after, the first load would run with Seerr off.
            seerrModel.seerr = seerr
            seerrModel.allowsSeerr = { [seerr, proAccess, network] in
                seerr?.isVisible(proAllows: proAccess?.allows(.requests) ?? false, isOnline: network.isOnline) ?? false
            }
            await load(force: false)
        }
        // Always a pushed screen. Its header is focusable now (see `header`),
        // which is what stops an Up press escaping into the tab bar — the case
        // that surfaced the Menu-button bug this modifier answers.
        .tvPushedScreen()
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
            #if os(tvOS)
            // Focusable so the page has a top row at all. Without one, an Up
            // press from the filmography rails had nowhere to go and escaped
            // into the tab bar — from where tvOS's default Menu behaviour is to
            // QUIT the app, which is the reported bug `TVBackPolicy` exists to
            // contain. A circular ring, since the rectangular `cinemaFocus()`
            // is the wrong shape for a portrait — same reason `CastCircle`
            // draws its own.
            // Card level, like `CastCircle`: ring + accent halo + card timing.
            .overlay(
                Circle().strokeBorder(
                    themeManager.accent.opacity(portraitFocused ? CinemaTVFocus.strokeOpacity : 0),
                    lineWidth: CinemaTVFocus.cardRingWidth
                )
            )
            .shadow(
                color: themeManager.accent.opacity(portraitFocused ? CinemaTVFocus.haloOpacity : 0),
                radius: CinemaTVFocus.haloRadius,
                y: 6
            )
            .focusable()
            .focused($portraitFocused)
            .focusEffectDisabled()
            .animation(motionEffects ? .easeInOut(duration: CinemaTVFocus.cardDuration) : nil, value: portraitFocused)
            #endif

            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                Text(personName)
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                if let birth = person?.premiereDate {
                    Text(String(format: loc.localized("person.born"), birth.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(loc.locale))))
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
                let count = movies.count + series.count
                if count > 0 {
                    Text(loc.counted("person.titleCount", count))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
            Spacer()
        }
        .padding(.horizontal, pagePadding)
    }

    private func filmographyRow(title: String, items: [BaseItemDto]) -> some View {
        ContentRow(title: title, data: items, id: \.id) { item in
            // One surface per rail (Films / Séries) — see `CardZoom`.
            let zoom = CardZoom(zoomNamespace, surface: "person.\(title)", itemId: item.id)
            // One value feeds both the overlay and VoiceOver, so the card
            // cannot announce a state it does not draw.
            let status = MediaCardStatus.make(
                positionTicks: item.userData?.playbackPositionTicks,
                runtimeTicks: item.runTimeTicks,
                isPlayed: item.userData?.isPlayed
            )
            NavigationLink {
                DeferredView {
                    if let id = item.id {
                        MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
                    }
                }
                .cardZoomDestination(zoom)
            } label: {
                PosterCard(
                    title: item.name ?? "",
                    imageURL: item.id.map {
                        appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300, tag: item.primaryImageTagValue)
                    },
                    subtitle: item.productionYear.map(String.init),
                    status: status,
                    zoomSource: zoom
                )
                .frame(width: cardWidth)
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVCardButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel([item.name, item.productionYear.map(String.init)].compactMap { $0 }.joined(separator: ", "))
            .mediaCardStatusAccessibility(status)
            // On the NavigationLink (the focusable button), never its label,
            // so tvOS focus is untouched.
            .mediaCardContextMenu(item: item, artwork: .poster)
        }
    }

    private func load(force: Bool) async {
        if hasLoaded && !force { return }
        hasLoaded = true
        guard let userId = appState.currentUserId else { return }
        isLoading = true
        errorMessage = nil
        seerrModel.reset()
        // The TMDb ids only while the Seerr section may show: what tells an
        // owned title from a missing one.
        let withProviderIds = seerrModel.allowsSeerr()
        do {
            async let personTask = appState.apiClient.getItem(userId: userId, itemId: personId)
            async let itemsTask = appState.apiClient.getPersonItems(
                personId: personId, userId: userId, includeProviderIds: withProviderIds)
            person = try? await personTask
            let items = try await itemsTask
            movies = items.filter { $0.type == .movie }
            series = items.filter { $0.type == .series }
        } catch {
            // Jellyfin decides what is « in the library »: no answer, no Seerr.
            errorMessage = loc.userFacingMessage(for: error)
            isLoading = false
            return
        }
        isLoading = false
        // Once the owned filmography is on screen, a side task of its own.
        seerrModel.load(
            tmdbId: person.flatMap(SeerrMissing.tmdbId(of:)),
            owned: SeerrMissing.ownedTmdbIds(movies + series),
            fetchedProviderIds: withProviderIds)
    }

    // MARK: - Missing titles (Seerr)

    /// The section as this account may see it right now — Pro, age cap,
    /// network and the Seerr account re-read at render, so a late answer
    /// never paints where Seerr no longer applies.
    private var missingTitles: MissingSection<SeerrMissingTitle> {
        guard let seerr, seerrRequests != nil else { return seerrModel.section(for: nil) }
        let visible = seerr.isVisible(proAllows: proAccess?.allows(.requests) ?? false, isOnline: network.isOnline)
        return seerrModel.section(for: visible ? seerr.snapshot() : nil)
    }

    /// « Pas encore dans ta bibliothèque »: films and series mixed, like the
    /// search's — no count, no « Demander les N ».
    @ViewBuilder
    private var missingTitlesRow: some View {
        let section = missingTitles
        if !section.drawsNothing {
            MissingTitlesRow(
                title: loc.localized("seerr.missing.title"), count: nil, section: section,
                headerAction: nil, cardWidth: cardWidth
            ) { missing in
                MissingTitleButton(missing: missing, onRequest: requestMissing)
            }
        }
    }

    /// A card: the request — or « Déjà demandé ».
    private func requestMissing(_ missing: SeerrMissingTitle) {
        guard let seerr, let seerrRequests else { return }
        Task { await seerrRequests.request(missing, session: seerr, loc: loc, toasts: toasts) }
    }
}

// MARK: - Seerr model

/// The actor page's « Pas encore dans ta bibliothèque »: the rest of the
/// person's TMDb credits (`SeerrMissing.creditTitles`), minus what the page's
/// filmography owns. A side task started once that filmography is written,
/// silent on failure (error or deadline ⇒ `.hidden`, nothing says why), and
/// no call without the person's TMDb id, without the owned ids, or when
/// `allowsSeerr` says no.
///
/// Its own task, not the screen's `.task`, which SwiftUI cancels once the
/// view disappears (a fiche pushed over it): a cancelled pass writes nothing,
/// so the skeleton would stay for good — the page never reloads on return.
@MainActor
@Observable
final class PersonDetailSeerrModel {
    /// The active account's Seerr, set by the screen. `nil` ⇒ no section.
    @ObservationIgnored var seerr: SeerrSession?
    /// Whether the section may load — `SeerrSession.isVisible` with the
    /// screen's Pro gate and network, wired by the screen.
    @ObservationIgnored var allowsSeerr: @MainActor () -> Bool = { false }
    /// `SeerrSession.loadSection`'s deadline — injectable for the tests.
    @ObservationIgnored var deadline: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(6)) }
    /// Read through `section(for:)`, which hides another account's.
    private(set) var section: MissingSection<SeerrMissingTitle> = .hidden
    /// The pass filling `section`. Internal so a test can await it.
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    /// The Seerr account and generation `section` was loaded for.
    @ObservationIgnored private var snapshot: SeerrSession.Snapshot?
    /// Bumped by every `reset` / `load`: a pass compares it with its own.
    @ObservationIgnored private var generation = 0

    /// The section to draw for the account Seerr serves right now: another
    /// profile's never shows.
    func section(for current: SeerrSession.Snapshot?) -> MissingSection<SeerrMissingTitle> {
        // Read FIRST, whatever the guard says: the view must observe it.
        let section = self.section
        guard let current, current == snapshot else { return .hidden }
        return section
    }

    /// Hides the section; the pass in flight, if any, writes nothing.
    func reset() {
        task?.cancel()
        task = nil
        generation += 1
        set(.hidden, snapshot: nil)
    }

    /// `owned`: the TMDb ids of the page's filmography, which carries them
    /// only when `fetchedProviderIds` — without them nothing is asked.
    func load(tmdbId: Int?, owned: Set<SeerrOwnedKey>, fetchedProviderIds: Bool) {
        reset()
        let pass = generation
        task = Task { await run(tmdbId: tmdbId, owned: owned, fetchedProviderIds: fetchedProviderIds, pass: pass) }
    }

    private func run(tmdbId: Int?, owned: Set<SeerrOwnedKey>, fetchedProviderIds: Bool, pass: Int) async {
        // A pass cancelled or superseded before it even ran writes NOTHING.
        guard !Task.isCancelled, generation == pass else { return }
        guard fetchedProviderIds, let tmdbId, allowsSeerr(), let seerr, let snapshot = seerr.snapshot() else {
            set(.hidden, snapshot: nil)
            return
        }
        set(.loading, snapshot: snapshot)
        // Both calls in ONE op, so the one deadline bounds them both.
        let section = await seerr.loadSection(deadline: deadline) { client, credential in
            async let person = client.person(id: tmdbId, credential)
            async let credits = client.combinedCredits(personId: tmdbId, credential)
            let titles = SeerrMissing.creditTitles(try await credits, person: try await person)
            return SeerrMissing.titles(titles, owned: owned)
        }
        guard !Task.isCancelled, generation == pass else { return }
        // `nil` = the account moved: nothing of this answer is written, and
        // the skeleton goes rather than wait for the next profile.
        set(section ?? .hidden, snapshot: section == nil ? nil : snapshot)
    }

    private func set(_ section: MissingSection<SeerrMissingTitle>, snapshot: SeerrSession.Snapshot?) {
        self.snapshot = snapshot
        if self.section != section { self.section = section }
    }
}
