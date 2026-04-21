import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Full-bleed hero block at the top of the iOS browse view. tvOS does not
/// render this — the tvOS library screen leads with the inline filter bar
/// directly because the top tab bar already dominates that area.
struct LibraryHeroSection: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    let item: BaseItemDto
    let itemType: BaseItemKind

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let id = item.id {
                CinemaLazyImage(
                    url: appState.imageBuilder.imageURL(itemId: id, imageType: .backdrop, maxWidth: ImageURLBuilder.screenPixelWidth),
                    fallbackIcon: nil,
                    fallbackBackground: CinemaColor.surfaceContainerLow
                )
                .accessibilityHidden(true)
            }

            CinemaGradient.heroOverlay

            VStack(alignment: .leading, spacing: heroContentSpacing) {
                HStack(spacing: 8) {
                    if let rating = item.officialRating {
                        RatingBadge(rating: rating)
                    }
                    heroMetadataText
                }
                .foregroundStyle(CinemaColor.onSurfaceVariant)

                Text(item.name ?? "")
                    .font(.system(size: heroTitleSize, weight: .black))
                    .tracking(-1.5)
                    .foregroundStyle(.white)
                    .textCase(.uppercase)
                    .lineLimit(2)

                #if os(tvOS)
                if let overview = item.overview {
                    Text(overview)
                        .font(.system(size: overviewFontSize))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(3)
                        .frame(maxWidth: maxOverviewWidth, alignment: .leading)
                }
                #endif

                if let id = item.id {
                    heroActionButtons(id: id)
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

    @ViewBuilder
    private func heroActionButtons(id: String) -> some View {
        HStack(spacing: heroButtonSpacing) {
            PlayLink(itemId: id, title: item.name ?? "") {
                HStack(spacing: CinemaSpacing.spacing2) {
                    Text(loc.localized("action.play"))
                        .font(.system(size: heroButtonFontSize, weight: .bold))
                    Image(systemName: "play.fill")
                        .font(.system(size: heroButtonFontSize - 2, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, heroButtonVerticalPadding)
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
            .frame(width: heroButtonWidth)

            NavigationLink {
                MediaDetailScreen(itemId: id, itemType: itemType)
            } label: {
                HStack(spacing: CinemaSpacing.spacing2) {
                    Text(loc.localized("action.moreInfo"))
                        .font(.system(size: heroButtonFontSize, weight: .bold))
                        .lineLimit(1)
                    Image(systemName: "info.circle")
                        .font(.system(size: heroButtonFontSize - 2, weight: .bold))
                }
                .foregroundStyle(CinemaColor.onSurface)
                #if os(tvOS)
                .frame(maxWidth: .infinity)
                #endif
                .padding(.vertical, heroButtonVerticalPadding)
                .padding(.horizontal, CinemaSpacing.spacing4)
                #if os(iOS)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                #endif
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .ghost))
            .frame(width: heroButtonWidth)
            #else
            .buttonStyle(.plain)
            .fixedSize()
            #endif
        }
    }

    private var heroMetadataText: some View {
        let parts: [String] = [
            item.productionYear.map(String.init),
            itemType == .series
                ? item.childCount.map { loc.localized($0 == 1 ? "tvShows.season" : "tvShows.seasonsPlural", $0) }
                : item.formattedRuntime,
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
        CinemaScale.pt(72)
        #else
        20
        #endif
    }

    private var overviewFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(18)
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

    private var heroContentSpacing: CGFloat {
        #if os(tvOS)
        16
        #else
        10
        #endif
    }

    private var maxOverviewWidth: CGFloat {
        #if os(tvOS)
        600
        #else
        300
        #endif
    }

    private var heroButtonWidth: CGFloat {
        #if os(tvOS)
        240
        #else
        160
        #endif
    }

    private var heroButtonFontSize: CGFloat {
        #if os(tvOS)
        28
        #else
        16
        #endif
    }

    private var heroButtonVerticalPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing4
        #else
        CinemaSpacing.spacing2
        #endif
    }

    private var heroButtonSpacing: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing5
        #else
        12
        #endif
    }

    private var metadataFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(16)
        #else
        CinemaScale.pt(13)
        #endif
    }
}
