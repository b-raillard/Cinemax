import SwiftUI
import CinemaxKit
import JellyfinAPI

// MARK: - Similar Items Section

/// One card of a fiche carousel: the library's own first — their index never
/// moves — then, on the « Fait partie de » row only, the saga's films Seerr
/// knows and the library lacks (or their skeletons), closed by « Demander
/// les N ».
enum SimilarRowItem: Identifiable {
    case owned(BaseItemDto)
    case missing(SeerrMissingTitle)
    case skeleton(Int)
    case requestAll

    var id: String {
        switch self {
        case .owned(let item): "owned-\(item.id ?? "")"
        case .missing(let missing): "missing-\(missing.id)"
        case .skeleton(let index): "skeleton-\(index)"
        case .requestAll: "requestAll"
        }
    }
}

/// "More like this" horizontal carousel. Equatable so non-similar mutations
/// on the parent view model don't re-render this row.
struct MediaDetailSimilarSection: View, Equatable {
    let items: [BaseItemDto]
    let cardWidth: CGFloat
    /// Custom row title — the collection row ("Part of: …") reuses this whole
    /// section with its own header; nil keeps the "More like this" default.
    var titleOverride: String? = nil
    /// The saga's missing films, APPENDED after the owned cards — the
    /// « Fait partie de » row only; `.hidden` everywhere else. The header is
    /// the owned row's and never changes when Seerr answers: the count stays
    /// out, and « Demander les N » is the card closing the row.
    var trailing: MissingSection<SeerrMissingTitle> = .hidden
    var onRequestMissing: (SeerrMissingTitle) -> Void = { _ in }
    var onRequestAllMissing: () -> Void = {}

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    /// Optional: only read while `trailing` shows something.
    @Environment(SeerrRequestPresenter.self) private var presenter: SeerrRequestPresenter?
    /// Published by `MediaDetailScreen`, one surface per section — see `CardZoom`.
    @Environment(\.cardZoomScope) private var zoomScope

    /// Skeletons appended while Seerr answers: a hint, off to the right.
    private static let skeletonCount = 2

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // SwiftUI calls `==` on the main actor during view diffing —
        // `assumeIsolated` lets us read the non-Sendable `BaseItemDto`
        // payload without a `nonisolated`-context warning.
        MainActor.assumeIsolated {
            guard lhs.cardWidth == rhs.cardWidth,
                  lhs.titleOverride == rhs.titleOverride,
                  lhs.trailing == rhs.trailing,
                  lhs.items.count == rhs.items.count else { return false }
            for (a, b) in zip(lhs.items, rhs.items) {
                if a.id != b.id || a.name != b.name || a.productionYear != b.productionYear { return false }
                // The status overlay reads these, so the diff must too —
                // otherwise a card keeps the progress bar the playback that
                // just finished has emptied.
                if a.userData?.playbackPositionTicks != b.userData?.playbackPositionTicks
                    || a.userData?.isPlayed != b.userData?.isPlayed { return false }
            }
            return true
        }
    }

    /// Owned first, in their order; then the missing films or the skeletons;
    /// then the action card. Nothing is appended for `.hidden` / `.loaded([])`.
    static func rowItems(
        owned: [BaseItemDto], trailing: MissingSection<SeerrMissingTitle>, showsRequestAll: Bool
    ) -> [SimilarRowItem] {
        var rows = owned.map(SimilarRowItem.owned)
        switch trailing {
        case .hidden:
            break
        case .loading:
            rows += (0..<skeletonCount).map(SimilarRowItem.skeleton)
        case .loaded(let missing):
            rows += missing.map(SimilarRowItem.missing)
            if showsRequestAll, !missing.isEmpty { rows.append(.requestAll) }
        }
        return rows
    }

    var body: some View {
        let requestAll = requestAllAction
        ContentRow(
            title: titleOverride ?? loc.localized("detail.moreLikeThis"),
            data: Self.rowItems(owned: items, trailing: trailing, showsRequestAll: requestAll != nil),
            id: \.id
        ) { row in
            switch row {
            case .owned(let item):
                ownedCard(item)
            case .missing(let missing):
                MediaDetailMissingFilmCard(missing: missing, onRequest: onRequestMissing)
                    .frame(width: cardWidth)
            case .skeleton:
                SkeletonBlock()
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .frame(width: cardWidth)
                    .accessibilityHidden(true)
                    #if os(tvOS)
                    .focusable(false)
                    #endif
            case .requestAll:
                if let requestAll { MissingActionCard(action: requestAll, width: cardWidth) }
            }
        }
    }

    /// « Demander les N » from two requestable films (by their EFFECTIVE
    /// badge, so it follows a request just sent): a single one is its own card.
    private var requestAllAction: MissingHeaderAction? {
        guard case .loaded(let missing) = trailing, let presenter else { return nil }
        let count = presenter.requestableFilms(missing).count
        guard count >= 2 else { return nil }
        return MissingHeaderAction(label: loc.counted("seerr.saga.requestAll", count), perform: onRequestAllMissing)
    }

    @ViewBuilder
    private func ownedCard(_ item: BaseItemDto) -> some View {
        let zoom = zoomScope?.zoom(for: item.id)
        // One value feeds both the overlay and VoiceOver, so the card
        // cannot announce a state it does not draw.
        let status = MediaCardStatus.make(
            positionTicks: item.userData?.playbackPositionTicks,
            runtimeTicks: item.runTimeTicks,
            isPlayed: item.userData?.isPlayed
        )
        NavigationLink {
            // Built at the push, not on every redraw (P3 — see DeferredView).
            DeferredView {
                if let id = item.id {
                    MediaDetailScreen(
                        itemId: id,
                        itemType: item.type ?? .movie
                    )
                }
            }
            .cardZoomDestination(zoom)
        } label: {
            PosterCard(
                title: item.name ?? "",
                imageURL: item.id.map { appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300, tag: item.primaryImageTagValue) },
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

// MARK: - Saga (Seerr)

/// A saga film the library lacks: the dashed card, its badge read from the
/// request presenter so it flips once a request is sent, without reloading
/// the row around it.
struct MediaDetailMissingFilmCard: View {
    let missing: SeerrMissingTitle
    let onRequest: (SeerrMissingTitle) -> Void

    @Environment(SeerrRequestPresenter.self) private var presenter: SeerrRequestPresenter?
    @Environment(SeerrSession.self) private var seerr: SeerrSession?

    var body: some View {
        Button {
            onRequest(missing)
        } label: {
            MissingTitleCard(
                title: missing.title.title,
                subtitle: missing.title.year.map(String.init),
                badge: presenter?.badge(for: missing.id, default: missing.badge) ?? missing.badge,
                posterURL: seerr?.posterURL(missing.title.posterPath)
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
    }
}

/// « Pour compléter la saga » — after « Dans cette collection » on a BoxSet
/// fiche, and « Pour compléter la saga <nom> » at the END of a film's fiche
/// when no « Fait partie de » row exists. Its header is Seerr's own: « 3 films
/// manquants », and « Demander les 3 » from two requestable films (the card
/// closing the row on Apple TV).
struct MediaDetailSagaRow: View, Equatable {
    let title: String
    let section: MissingSection<SeerrMissingTitle>
    let cardWidth: CGFloat
    let onRequest: (SeerrMissingTitle) -> Void
    let onRequestAll: () -> Void

    /// Optional like its siblings': a host without it loses the action, never
    /// crashes.
    @Environment(SeerrRequestPresenter.self) private var presenter: SeerrRequestPresenter?
    @Environment(LocalizationManager.self) private var loc

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.title == rhs.title && lhs.section == rhs.section && lhs.cardWidth == rhs.cardWidth
        }
    }

    var body: some View {
        MissingTitlesRow(
            title: title,
            count: count,
            section: section,
            headerAction: headerAction,
            cardWidth: cardWidth
        ) { missing in
            MediaDetailMissingFilmCard(missing: missing, onRequest: onRequest)
        }
    }

    /// « 3 films manquants » — every missing film, requested ones included.
    private var count: String? {
        guard case .loaded(let missing) = section, !missing.isEmpty else { return nil }
        return loc.counted("seerr.request.films.header", missing.count)
    }

    private var headerAction: MissingHeaderAction? {
        guard let presenter, case .loaded(let missing) = section else { return nil }
        let count = presenter.requestableFilms(missing).count
        guard count >= 2 else { return nil }
        return MissingHeaderAction(label: loc.counted("seerr.saga.requestAll", count), perform: onRequestAll)
    }
}
