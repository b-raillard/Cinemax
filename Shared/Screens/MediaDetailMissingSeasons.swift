import SwiftUI
import CinemaxKit

// MARK: - Missing seasons (Seerr) — series fiche

/// « Pas encore dans ta bibliothèque » of a series fiche: the seasons Seerr
/// knows that the library lacks, as dashed season cards over each season's
/// own poster (dimmed, like every missing card) AFTER the episodes —
/// iPhone / iPad, and Apple TV when there is no pill row (one owned season).
///
/// Equatable on its data (the closures are the screen's, reading the view
/// model at tap time); it reads the request presenter itself, so a card's
/// badge and the header action follow a request just sent.
struct MediaDetailMissingSeasonsRow: View, Equatable {
    let section: MissingSection<SeerrMissingSeason>
    let cardWidth: CGFloat
    let onRequest: (SeerrMissingSeason) -> Void
    let onRequestAll: () -> Void

    @Environment(SeerrRequestPresenter.self) private var presenter
    @Environment(SeerrSession.self) private var seerr: SeerrSession?
    @Environment(LocalizationManager.self) private var loc

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.section == rhs.section && lhs.cardWidth == rhs.cardWidth
        }
    }

    var body: some View {
        MissingTitlesRow(
            title: loc.localized("seerr.missing.title"),
            count: nil,
            section: section,
            headerAction: headerAction,
            cardWidth: cardWidth
        ) { season in
            Button {
                onRequest(season)
            } label: {
                MissingTitleCard(
                    title: SeerrRequestPresenter.seasonName(season.seasonNumber, loc: loc),
                    subtitle: nil,
                    badge: presenter.badge(for: season.id, default: season.badge),
                    posterURL: seerr?.posterURL(season.posterPath)
                )
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVCardButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
        }
    }

    /// « Demander les N » — from two requestable seasons: a single one is its
    /// own card. On Apple TV the row closes with it as a card.
    private var headerAction: MissingHeaderAction? {
        guard case .loaded(let seasons) = section else { return nil }
        let count = presenter.requestableSeasons(seasons).count
        guard count >= 2 else { return nil }
        return MissingHeaderAction(label: loc.counted("seerr.missing.requestAll", count), perform: onRequestAll)
    }
}

#if os(tvOS)
/// Apple TV with a pill row (two owned seasons or more): the missing seasons
/// as dashed pills APPENDED after the owned ones, so nothing moves when Seerr
/// answers. Skeleton pills while loading, never focusable. Selecting one asks
/// for it (the confirmation) — it never becomes the selected season, and the
/// row's default focus stays on the selected OWNED season (no `focused`
/// binding here).
struct MediaDetailMissingSeasonPills: View, Equatable {
    let section: MissingSection<SeerrMissingSeason>
    let fontSize: CGFloat
    let onRequest: (SeerrMissingSeason) -> Void

    @Environment(SeerrRequestPresenter.self) private var presenter
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.section == rhs.section && lhs.fontSize == rhs.fontSize
        }
    }

    private static let skeletonCount = 2

    var body: some View {
        HStack(spacing: CinemaTVLayout.seasonPillSpacing) {
            switch section {
            case .hidden:
                EmptyView()
            case .loading:
                ForEach(0..<Self.skeletonCount, id: \.self) { _ in skeletonPill }
            case .loaded(let seasons):
                ForEach(seasons) { season in pill(season) }
            }
        }
    }

    private func pill(_ season: SeerrMissingSeason) -> some View {
        let badge = presenter.badge(for: season.id, default: season.badge)
        let name = SeerrRequestPresenter.seasonName(season.seasonNumber, loc: loc)
        return Button {
            onRequest(season)
        } label: {
            HStack(spacing: 6) {
                Text(name)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                if badge == .request {
                    Image(systemName: "plus")
                        .font(.system(size: fontSize * 0.8, weight: .semibold))
                        .foregroundStyle(themeManager.accent)
                } else {
                    Text(badge.label(loc))
                        .foregroundStyle(CinemaColor.onSurfaceMuted)
                }
            }
            .font(.system(size: fontSize, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.vertical, CinemaTVLayout.seasonPillVerticalPadding)
            // The design system's one dashed outline, on the missing-season
            // pill too (Shared/DesignSystem/CLAUDE.md): no fill, « not here yet ».
            .overlay {
                Capsule()
                    .strokeBorder(CinemaColor.onSurfaceMuted, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(SeasonTabButtonStyle(isSelected: false, accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .accessibilityLabel(loc.localized("seerr.missing.a11y", name, badge.label(loc)))
    }

    /// Sized like a real pill (same text metrics, hidden), never focusable.
    private var skeletonPill: some View {
        Text(SeerrRequestPresenter.seasonName(10, loc: loc))
            .font(.system(size: fontSize, weight: .medium))
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.vertical, CinemaTVLayout.seasonPillVerticalPadding)
            .hidden()
            .overlay { SkeletonBlock().clipShape(Capsule()) }
            .focusable(false)
            .accessibilityHidden(true)
    }
}
#endif
