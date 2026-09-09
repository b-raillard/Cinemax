import SwiftUI

// MARK: - Episode Overview

/// Identifiable payload for the episode-overview `.sheet(item:)` on
/// `MediaDetailScreen`. Built by the iOS episode card and tvOS episode row when
/// the user taps "See more"; consumed by `EpisodeOverviewSheet` below.
struct EpisodeOverviewItem: Identifiable {
    let id: String
    let title: String
    let overview: String
}

/// Modal sheet showing the full episode overview text. Presented via
/// `.sheet(item: $episodeOverview)` on `MediaDetailScreen`.
struct EpisodeOverviewSheet: View {
    let item: EpisodeOverviewItem
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        #if os(tvOS)
        tvOSBody
        #else
        iOSBody
        #endif
    }

    #if !os(tvOS)
    private var iOSBody: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            HStack(alignment: .center) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: CinemaScale.pt(14), weight: .bold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(themeManager.accentContainer)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc.localized("action.done"))

                Spacer()

                Text(item.title)
                    .font(.system(size: CinemaScale.pt(17), weight: .bold))
                    .foregroundStyle(CinemaColor.onSurface)
                    .multilineTextAlignment(.center)

                Spacer()

                Color.clear.frame(width: 36, height: 36)
            }

            ScrollView {
                Text(item.overview)
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(CinemaSpacing.spacing5)
        .background(CinemaColor.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    #endif

    #if os(tvOS)
    /// tvOS chrome — the one shape every tvOS modal shares
    /// (`WatchedHistoryScreen`): header row with the title and an accent Done
    /// button, prose below at the page margin capped to a readable measure,
    /// Menu dismisses. The round `.plain` xmark had no focus treatment at all
    /// on tvOS.
    private var tvOSBody: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                tvHeader

                ScrollView {
                    // Focusable so the remote can reach and scroll a long
                    // overview, washed so that focus is VISIBLE when it lands
                    // here — the wash sits inside `.focusable()`, same as the
                    // fiche's synopsis.
                    Text(item.overview)
                        .font(CinemaFont.body)
                        .frame(maxWidth: CinemaTVLayout.readingMaxWidth, alignment: .leading)
                        .tvFocusableProse()
                        .focusable()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, CinemaTVLayout.pagePadding)
                        .padding(.bottom, CinemaSpacing.spacing8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onExitCommand { dismiss() }
    }

    private var tvHeader: some View {
        HStack(alignment: .center) {
            Text(item.title)
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)

            Spacer(minLength: CinemaSpacing.spacing6)

            CinemaButton(
                title: loc.localized("action.done"),
                style: .accent
            ) {
                dismiss()
            }
            .frame(width: CinemaTVLayout.ctaWidth)
        }
        .padding(.horizontal, CinemaTVLayout.pagePadding)
        .padding(.top, CinemaSpacing.spacing8)
        .padding(.bottom, CinemaSpacing.spacing5)
        // Without this, up-presses from the prose never reach the Done button
        // (separate container — same rule as the Home/Library hero).
        .focusSection()
    }
    #endif
}
