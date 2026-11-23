#if os(tvOS)
import SwiftUI
import CinemaxKit

/// The Apple TV request fiche for a film or a series (owner's choice TV-1,
/// canvas « Fiche de demande Seerr », 2026-11-23): the iOS mini-fiche's
/// content laid out like a library fiche — the backdrop full screen, the
/// title, « Demander… » (focused on open), the rating, the synopsis, a
/// series' seasons to tick, then « Casting » and « Infos » below, reached by
/// moving down. Menu closes it. Drawn at once from the card's `SeerrTitle`;
/// the title's `/movie` or `/tv` (`SeerrRequestFiche.loadDetails`) fills in
/// the backdrop, cast and facts. No « Bande-annonce »: tvOS has no browser to
/// open TMDb's YouTube link in (the same reason the library fiche only plays
/// trailers the server holds).
struct SeerrRequestTVFiche: View {
    let draft: SeerrRequestDraft

    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(SeerrSession.self) private var session
    @Environment(SeerrRequestPresenter.self) private var presenter

    @State private var selection: Set<Int>
    @State private var sending = false
    @State private var details: SeerrTitleDetails?
    @State private var fullOverview: EpisodeOverviewItem?
    @State private var overviewHeights = OverviewHeights()
    @FocusState private var requestFocused: Bool
    @FocusState private var firstCastFocused: Bool

    init(draft: SeerrRequestDraft) {
        self.draft = draft
        _selection = State(initialValue: draft.defaultSelection(partial: true))
    }

    private var title: SeerrTitle? {
        switch draft {
        case .movie(let title), .series(let title, _, _): title
        case .films: nil
        }
    }

    private var partial: Bool { session.publicSettings?.partialRequestsEnabled ?? true }
    private var effective: Set<Int> { SeerrRequestPresenter.effectiveSelection(draft, selection, partial: partial) }
    private var canSend: Bool {
        if case .movie = draft { return !sending }
        return !effective.isEmpty && !sending
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing10) {
                    cast
                    facts
                }
                .padding(.horizontal, CinemaTVLayout.pagePadding)
                .padding(.bottom, CinemaSpacing.spacing20)
            }
        }
        .scrollIndicators(.hidden)
        .background(CinemaColor.surface)
        .ignoresSafeArea()
        // Opens on « Demander »; answers before the cast section's own
        // default below (the library fiche's outer-default RULE).
        .defaultFocus($requestFocused, true, priority: .userInitiated)
        .onExitCommand { dismiss() }
        .task(id: draft.id) {
            guard details == nil, let title else { return }
            details = await SeerrRequestFiche.loadDetails(of: title, session: session)
        }
        .fullScreenCover(item: $fullOverview) { item in
            EpisodeOverviewSheet(item: item)
                .environment(themeManager)
                .environment(loc)
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
            if let title {
                Text(title.title)
                    .font(CinemaFont.display(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                metaLine(title)
            }
            actions
            seasons
            summary
        }
        .frame(maxWidth: CinemaTVLayout.readingMaxWidth, alignment: .leading)
        .padding(.horizontal, CinemaTVLayout.pagePadding)
        .padding(.top, SeerrTVFicheLayout.heroTopPadding)
        .padding(.bottom, CinemaSpacing.spacing10)
        .frame(maxWidth: .infinity, minHeight: SeerrTVFicheLayout.heroMinHeight, alignment: .bottomLeading)
        .background(alignment: .top) { backdrop }
    }

    private var backdrop: some View {
        Color.clear
            .frame(height: SeerrTVFicheLayout.backdropHeight)
            .overlay {
                if let url = SeerrRequestFiche.imageURL(details?.backdropPath, SeerrImages.backdropURL, session: session) {
                    CinemaLazyImage(url: url, fallbackIcon: nil, fallbackBackground: CinemaColor.surfaceContainerLow)
                } else {
                    BackdropFallbackView()
                }
            }
            .clipped()
            // Legible text on the left, then a fade into the page below.
            .overlay {
                LinearGradient(
                    stops: [.init(color: CinemaColor.surface.opacity(0.97), location: 0),
                            .init(color: CinemaColor.surface.opacity(0.88), location: 0.45),
                            .init(color: CinemaColor.surface.opacity(0.25), location: 0.75),
                            .init(color: .clear, location: 1)],
                    startPoint: .leading, endPoint: .trailing)
            }
            .overlay {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.5), .init(color: CinemaColor.surface, location: 1)],
                    startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)
    }

    private func metaLine(_ title: SeerrTitle) -> some View {
        HStack(spacing: CinemaSpacing.spacing4) {
            let line = SeerrRequestFiche.heroLine(year: title.year, details: details, loc: loc)
            if !line.isEmpty {
                Text(line)
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            if let rating = SeerrRequestFiche.rating(details, loc: loc) {
                HStack(spacing: CinemaSpacing.spacing2) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(themeManager.accent)
                        .accessibilityHidden(true)
                    Text(rating.score)
                        .fontWeight(.bold)
                        .foregroundStyle(CinemaColor.onSurface)
                    Text(rating.votes)
                        .foregroundStyle(CinemaColor.onSurfaceMuted)
                }
                .font(CinemaFont.headline(.small))
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            CinemaButton(
                title: SeerrRequestPresenter.actionTitle(for: draft, selection: effective, loc: loc),
                style: .accent, isLoading: sending
            ) { send() }
            // A set width: `fixedSize` let the title shrink (« Demander la
            // saison 1 » smaller than « Demander ce film », simulator).
            .frame(width: SeerrTVFicheLayout.requestWidth)
            .disabled(!canSend)
            .focused($requestFocused)
            if case .connected(let user) = session.connection {
                Text(loc.localized(SeerrRequestPresenter.nextStepKey(permissions: user.permissions, kind: title?.kind ?? .movie)))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
        }
        .padding(.top, CinemaSpacing.spacing3)
        // Its own section: Down from a season pill or the synopsis comes back
        // to « Demander », never to whatever lines up under the pointer.
        .focusSection()
    }

    /// A series' seasons, each a pill that ticks or unticks it; the button
    /// above follows (« Demander les saisons 1 à 3 »). None without partial
    /// requests: the whole series goes.
    @ViewBuilder
    private var seasons: some View {
        if case .series(_, let numbers, _) = draft, partial, numbers.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: CinemaSpacing.spacing3) {
                    ForEach(numbers, id: \.self) { number in
                        let isOn = selection.contains(number)
                        Button {
                            if isOn { selection.remove(number) } else { selection.insert(number) }
                        } label: {
                            Label(SeerrRequestPresenter.seasonName(number, loc: loc),
                                  systemImage: isOn ? "checkmark.circle.fill" : "circle")
                                .font(CinemaFont.label(.large))
                                .padding(.horizontal, CinemaSpacing.spacing4)
                                .padding(.vertical, CinemaSpacing.spacing2)
                        }
                        .buttonStyle(CinemaTVButtonStyle(cinemaStyle: isOn ? .accent : .ghost))
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
                .padding(.vertical, CinemaSpacing.spacing3)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    // MARK: Synopsis

    /// Cut at `overviewLineLimit` lines; « Voir plus » (focusable) opens the
    /// whole text in the episode-overview screen, only when it was cut.
    @ViewBuilder
    private var summary: some View {
        if let title, let overview = title.overview, !overview.isEmpty {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                Text(overview)
                    .font(CinemaFont.bodyLarge)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(SeerrTVFicheLayout.overviewLineLimit)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { overviewHeights.shown = $0 }
                    .background(alignment: .topLeading) {
                        Text(overview)
                            .font(CinemaFont.bodyLarge)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { overviewHeights.full = $0 }
                    }
                if overviewHeights.isCut {
                    Button {
                        fullOverview = EpisodeOverviewItem(id: draft.id, title: title.title, overview: overview)
                    } label: {
                        Text(loc.localized("detail.seeMore"))
                            .font(CinemaFont.label(.large))
                            .padding(.horizontal, CinemaSpacing.spacing4)
                            .padding(.vertical, CinemaSpacing.spacing2)
                    }
                    .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .ghost))
                }
            }
            .padding(.top, CinemaSpacing.spacing3)
            // Its own section: Down from a season pill skipped « Voir plus »
            // for the cast (simulator, 2026-11-23).
            .focusSection()
        }
    }

    // MARK: Cast

    @ViewBuilder
    private var cast: some View {
        let members = details?.cast ?? []
        if !members.isEmpty {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                Text(loc.localized("detail.castCrew"))
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: CinemaSpacing.spacing5) {
                        ForEach(Array(members.enumerated()), id: \.offset) { index, member in
                            // A focus stop so the page scrolls down to the cast
                            // and the facts, drawn like the library fiche's
                            // cast; nothing to open (a TMDb person has no
                            // Jellyfin page). A bare `.focusable()` took focus
                            // with no ring at all (simulator, 2026-11-23).
                            Button {} label: {
                                CastCircle(
                                    name: member.name,
                                    role: member.character.flatMap { $0.isEmpty ? nil : $0 },
                                    imageURL: SeerrRequestFiche.imageURL(member.profilePath, SeerrImages.profileURL, session: session))
                            }
                            .buttonStyle(CinemaTVCardButtonStyle())
                            .modifier(SeerrTVFirstCardFocus(binding: index == 0 ? $firstCastFocused : nil))
                        }
                    }
                    .padding(.vertical, CinemaSpacing.spacing4)
                }
                .scrollClipDisabled()
            }
            .focusSection()
            // Down from « Demander » enters on the FIRST card, not the one
            // under the pointer (James Caan, second, on the simulator).
            .defaultFocus($firstCastFocused, true, priority: .userInitiated)
        }
    }

    // MARK: Facts

    @ViewBuilder
    private var facts: some View {
        if let title, let details {
            let facts = SeerrRequestFiche.facts(
                title: title, details: details, streamingRegion: session.publicSettings?.streamingRegion, loc: loc)
            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    Text(loc.localized("seerr.fiche.infos"))
                        .font(CinemaFont.headline(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: CinemaSpacing.spacing4, alignment: .top), count: 3),
                        alignment: .leading, spacing: CinemaSpacing.spacing4
                    ) {
                        ForEach(facts) { fact in
                            Button {} label: { SeerrTVFactTile(fact: fact) }
                                .buttonStyle(CinemaTVCardButtonStyle())
                        }
                    }
                }
                .focusSection()
            }
        }
    }

    private func send() {
        sending = true
        let chosen = effective
        Task {
            await presenter.submit(draft, selection: chosen, session: session, loc: loc, toasts: toasts)
            sending = false
            dismiss()
        }
    }
}

/// `.focused` on the first cast card only (as `MediaDetailCastSection`'s
/// `FirstCardFocus`).
private struct SeerrTVFirstCardFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding)
        } else {
            content
        }
    }
}

/// The two heights that tell whether the synopsis was cut.
private struct OverviewHeights: Equatable {
    var shown: CGFloat = 0
    var full: CGFloat = 0
    var isCut: Bool { full > shown + 1 }
}

/// One « Infos » fact, the label of a card button (the scroll needs a stop
/// there): the card style lifts it, the ground lightens under focus.
private struct SeerrTVFactTile: View {
    let fact: SeerrRequestFiche.Fact
    @Environment(\.isFocused) private var isFocused
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            Text(fact.label)
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceMuted)
            Text(fact.value)
                .font(CinemaFont.headline(.small))
                .foregroundStyle(CinemaColor.onSurface)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(CinemaSpacing.spacing5)
        .background(
            isFocused ? CinemaColor.surfaceContainerHigh : CinemaColor.surfaceContainer,
            in: RoundedRectangle(cornerRadius: CinemaRadius.large))
        .animation(motionEnabled ? .easeOut(duration: 0.15) : nil, value: isFocused)
        .accessibilityElement(children: .combine)
    }
}

enum SeerrTVFicheLayout {
    /// Room for the tab-less screen's top edge.
    static let heroTopPadding: CGFloat = 200
    /// The hero fills most of the screen; the cast's top peeks below it.
    static let heroMinHeight: CGFloat = 860
    static let backdropHeight: CGFloat = 1080
    static let overviewLineLimit = 5
    /// Room for « Demander les saisons 1 à 12 » whole.
    static let requestWidth: CGFloat = 560
}
#endif
