#if os(iOS)
import SwiftUI
import UIKit
import CinemaxKit

/// The request « mini-fiche » for a film or a series (owner's choice B,
/// canvas « Fiche de demande Seerr », 2026-11-22): the backdrop edge to edge,
/// the title, « Demander » beside « Bande-annonce », the rating, the whole
/// synopsis, the seasons to tick, the cast and an « Infos » grid. Drawn at
/// once from the card's `SeerrTitle`, « Demander » live from the start; the
/// title's `/movie` or `/tv` (one call, `loadSection`, never blocking the
/// request) then fills in the backdrop, cast and facts — a failed or late
/// read leaves those blocks out, with no message.
extension SeerrRequestSheet {
    var ficheBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ficheHero
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                    ficheActions
                    ficheSummary
                    choices
                    ficheCast
                    ficheFacts
                }
                .padding(.horizontal, CinemaSpacing.spacing4)
                .padding(.top, CinemaSpacing.spacing3)
                .padding(.bottom, CinemaSpacing.spacing8)
            }
        }
        .scrollIndicators(.hidden)
        .background(CinemaColor.surface.ignoresSafeArea())
        .overlay(alignment: .topLeading) { ficheCloseButton }
        .presentationDetents([.large])
        // iPad: the tall page sheet, not the small centred form sheet — that
        // one floated mid-screen over the search, its edges lost in the dark
        // page around it (owner, 2026-11-23). iPhone: unchanged.
        .presentationSizing(.page)
        .presentationDragIndicator(.visible)
        .task(id: draft.id) { await loadFicheDetails() }
    }

    // MARK: Hero

    private var ficheHero: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            // A short window (iPad split view) keeps the buttons in reach.
            .containerRelativeFrame(.vertical) { length, _ in
                min(SeerrFicheLayout.heroHeight, length * 0.5)
            }
            .overlay {
                Group {
                    if let url = ficheImageURL(details?.backdropPath, SeerrImages.backdropURL) {
                        CinemaLazyImage(url: url, fallbackIcon: nil, fallbackBackground: CinemaColor.surfaceContainerLow)
                            .accessibilityHidden(true)
                    } else {
                        BackdropFallbackView()
                    }
                }
                .heroBackdropBleed()
            }
            .overlay(alignment: .bottomLeading) {
                if let title = leadTitle {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                        Text(title.title)
                            .font(CinemaFont.display(.small))
                            .foregroundStyle(CinemaColor.onSurface)
                            .lineLimit(3)
                            .minimumScaleFactor(0.7)
                            .accessibilityAddTraits(.isHeader)
                        let line = SeerrRequestFiche.heroLine(year: title.year, details: details, loc: loc)
                        if !line.isEmpty {
                            Text(line)
                                .font(CinemaFont.label(.medium))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                        }
                    }
                    .padding(.horizontal, CinemaSpacing.spacing4)
                    .padding(.bottom, CinemaSpacing.spacing1)
                }
            }
            .layoutBoundDynamicType()
    }

    private var ficheCloseButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: CinemaScale.pt(15), weight: .bold))
                .foregroundStyle(CinemaColor.onSurface)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loc.localized("seerr.fiche.close"))
        .padding(.leading, CinemaSpacing.spacing3)
        .padding(.top, CinemaSpacing.spacing3)
    }

    // MARK: Actions

    private var ficheActions: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            // Side by side while both titles fit whole, else stacked — a
            // series' « Demander les saisons 1 à 8 » does not share a row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CinemaSpacing.spacing2) {
                    ficheRequestButton
                    ficheTrailerButton
                }
                VStack(spacing: CinemaSpacing.spacing2) {
                    ficheRequestButton
                    ficheTrailerButton
                }
            }
            nextStep
        }
    }

    private var ficheRequestButton: some View {
        CinemaButton(
            title: SeerrRequestPresenter.actionTitle(for: draft, selection: effective, loc: loc),
            style: .accent, isLoading: sending
        ) { send() }
        .disabled(!canSend)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var ficheTrailerButton: some View {
        if let url = details?.trailerURL {
            CinemaButton(title: loc.localized("detail.trailer"), style: .ghost, icon: "play.fill") {
                UIApplication.shared.open(url)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Summary

    @ViewBuilder
    private var ficheSummary: some View {
        let rating = SeerrRequestFiche.rating(details, loc: loc)
        let overview = leadTitle?.overview ?? ""
        if rating != nil || !overview.isEmpty {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                if let rating {
                    HStack(spacing: CinemaSpacing.spacing1) {
                        Image(systemName: "star.fill")
                            .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                            .foregroundStyle(themeManager.accent)
                            .accessibilityHidden(true)
                        Text(rating.score)
                            .font(CinemaFont.label(.medium))
                            .fontWeight(.bold)
                            .foregroundStyle(CinemaColor.onSurface)
                        Text(rating.votes)
                            .font(CinemaFont.label(.small))
                            .foregroundStyle(CinemaColor.onSurfaceMuted)
                    }
                    .accessibilityElement(children: .combine)
                }
                if !overview.isEmpty {
                    Text(overview)
                        .font(CinemaFont.dynamicBody)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Cast

    @ViewBuilder
    private var ficheCast: some View {
        let cast = details?.cast ?? []
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                Text(loc.localized("detail.castCrew"))
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurface)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
                        ForEach(Array(cast.enumerated()), id: \.offset) { _, member in
                            CastCircle(
                                name: member.name,
                                role: member.character.flatMap { $0.isEmpty ? nil : $0 },
                                imageURL: ficheImageURL(member.profilePath, SeerrImages.profileURL))
                            .frame(width: SeerrFicheLayout.castWidth)
                        }
                    }
                    .padding(.horizontal, CinemaSpacing.spacing4)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -CinemaSpacing.spacing4)
            }
        }
    }

    // MARK: Facts

    @ViewBuilder
    private var ficheFacts: some View {
        if let title = leadTitle, let details {
            let facts = SeerrRequestFiche.facts(
                title: title, details: details, streamingRegion: session.publicSettings?.streamingRegion, loc: loc)
            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                    Text(loc.localized("seerr.fiche.infos"))
                        .font(CinemaFont.headline(.small))
                        .foregroundStyle(CinemaColor.onSurface)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: CinemaSpacing.spacing2, alignment: .top),
                                  GridItem(.flexible(), alignment: .top)],
                        alignment: .leading, spacing: CinemaSpacing.spacing2
                    ) {
                        ForEach(facts) { fact in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fact.label)
                                    .font(CinemaFont.label(.small))
                                    .foregroundStyle(CinemaColor.onSurfaceMuted)
                                Text(fact.value)
                                    .font(CinemaFont.label(.medium))
                                    .foregroundStyle(CinemaColor.onSurface)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: SeerrFicheLayout.factMinHeight, alignment: .topLeading)
                            .padding(CinemaSpacing.spacing3)
                            .background(CinemaColor.surfaceContainer, in: RoundedRectangle(cornerRadius: CinemaRadius.large))
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    // MARK: Loading

    /// One read per opening (`SeerrRequestFiche.loadDetails`); a failure,
    /// the deadline or an account change leave `details` nil.
    func loadFicheDetails() async {
        guard details == nil, let title = leadTitle else { return }
        if let found = await SeerrRequestFiche.loadDetails(of: title, session: session) {
            details = found
        }
    }

    private func ficheImageURL(_ path: String?, _ build: (String?, URL, Bool) -> URL?) -> URL? {
        SeerrRequestFiche.imageURL(path, build, session: session)
    }
}

enum SeerrFicheLayout {
    static let heroHeight: CGFloat = 340
    static let castWidth: CGFloat = 92
    static let factMinHeight: CGFloat = 44
}
#endif
