import SwiftUI
import CinemaxKit

/// « Tout voir » of the season's request row (« À demander pour Noël »): the
/// same cards in a grid, read page by page as the end comes near. Pushed onto
/// Home's stack and fed by Home's own `SeasonRequestsModel`, so it opens on
/// the row's cards without asking again.
struct SeasonRequestsScreen: View {
    let title: String
    let model: SeasonRequestsModel

    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(SeerrSession.self) private var seerr: SeerrSession?
    @Environment(SeerrRequestPresenter.self) private var seerrRequests: SeerrRequestPresenter?
    @Environment(ProFeatureAccess.self) private var proAccess: ProFeatureAccess?
    @Environment(NetworkMonitor.self) private var network: NetworkMonitor?
    @Environment(\.seasonID) private var seasonID
    @Environment(\.dismiss) private var dismiss
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        let titles = visibleTitles
        ZStack {
            SeasonalBackdrop().ignoresSafeArea()
            grid(titles)
        }
        #if os(iOS)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // The title is drawn in the season's face just below; the bar keeps
        // the name (back-button menu, VoiceOver) without printing it twice.
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
        }
        #endif
        // Nothing left to show (Seerr signed out, the account moved, a reload
        // that failed): the row is gone from Home, so the page goes too —
        // never a black page with only a back button.
        .onChange(of: titles.isEmpty, initial: true) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }

    /// Re-read at render behind the gates, like the row on Home: a late
    /// answer never paints where Seerr no longer applies.
    private var visibleTitles: [SeerrMissingTitle] {
        guard let seerr, seerrRequests != nil else { return model.titles(for: nil) }
        let visible = seerr.isVisible(
            proAllows: proAccess?.allows(.requests) ?? false, isOnline: network?.isOnline ?? false)
        return model.titles(for: visible ? seerr.snapshot() : nil)
    }

    private func grid(_ titles: [SeerrMissingTitle]) -> some View {
        ScrollView {
            Text(title)
                .accessibilityAddTraits(.isHeader)
                .font(SeasonalTypography.titleFont(for: SeasonalThemeCatalogue.theme(id: seasonID), size: CinemaScale.pt(40))
                      ?? CinemaFont.display(.small))
                .foregroundStyle(CinemaColor.onSurface)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, gridPadding)
                .padding(.top, CinemaSpacing.spacing5)

            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(titles) { missing in
                    MissingTitleButton(missing: missing, onRequest: request)
                        .onAppear { model.loadMoreIfNeeded(onAppearOf: missing.id) }
                }
            }
            .padding(.horizontal, gridPadding)
            .padding(.top, CinemaSpacing.spacing3)

            if model.isLoadingMore {
                ProgressView()
                    .tint(CinemaColor.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CinemaSpacing.spacing6)
                    .accessibilityLabel(loc.localized("player.a11y.loading"))
            }

            Spacer(minLength: 80)
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
    }

    private func request(_ missing: SeerrMissingTitle) {
        guard let seerr, let seerrRequests else { return }
        Task { await seerrRequests.request(missing, session: seerr, loc: loc, toasts: toasts) }
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        CinemaTVLayout.posterGridColumns
        #else
        // The card's text sits ON the poster: at the library grid's three
        // phone columns « Demander » and « 2024 · Film » were cut (measured
        // on an iPhone 17 Pro, 2026-11-20) — two columns there.
        let form = AdaptiveLayout.form(horizontalSizeClass: sizeClass)
        return form == .compact
            ? Array(repeating: GridItem(.flexible(), spacing: 16), count: 2)
            : AdaptiveLayout.posterGridColumns(for: form)
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.gridGutter
        #else
        20
        #endif
    }

    private var gridPadding: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.pagePadding
        #else
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }
}
