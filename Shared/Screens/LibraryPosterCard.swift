import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Poster card with a navigation link into `MediaDetailScreen`, used by
/// `LibraryGenreRow` and by the filtered grids in `MediaLibraryScreen`.
/// Subtitle composition differs by `itemType` (series show season counts,
/// movies show community rating).
///
/// `body` only computes the two cheap, focus-independent pieces (the poster
/// image URL + the subtitle string) and hands them to `PosterCardContent`,
/// which renders everything else. On tvOS, `PosterCardContent` owns the
/// `dimUnfocusedPosters` spotlight `@FocusState` itself, so a focus step
/// re-evaluates only `PosterCardContent.body` — never re-runs the URL
/// construction (`appState.imageBuilder.imageURL(...)`) or subtitle
/// formatting in this `body`.
///
/// Admin overlay (iOS): when `appState.isAdministrator` is true the image
/// carries a small blur-circle ellipsis at the bottom-right that opens the
/// shared `AdminItemMenu` (Identifier / Edit metadata / Refresh / Delete).
/// The admin menu is a `ZStack` sibling of the image `NavigationLink`, not
/// nested inside its label — taps on the ellipsis hit the Menu, taps on the
/// rest of the poster hit the link. The title/subtitle row is plain text —
/// not a separate focusable target — so tvOS focus moves directly between
/// posters without an extra step landing on the label.
struct LibraryPosterCard: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc

    let item: BaseItemDto
    let itemType: BaseItemKind
    #if os(iOS)
    /// Caller-provided hook for the admin 3-dot menu's destination
    /// selection. The card is rendered inside a lazy grid/row, so the
    /// matching `navigationDestination(item:)` MUST live on a non-lazy
    /// ancestor — the screen body. This callback bubbles the
    /// `(item, destination)` pair up; the screen stores it in a
    /// `@State AdminMenuPushIntent?` and hosts the destination there.
    var onAdminAction: ((BaseItemDto, AdminItemMenu.Destination) -> Void)? = nil
    #endif

    var body: some View {
        let subtitle = subtitleText
        let posterURL: URL? = item.id.map {
            appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300, tag: item.primaryImageTagValue)
        }

        #if os(iOS)
        PosterCardContent(
            item: item,
            itemType: itemType,
            subtitle: subtitle,
            posterURL: posterURL,
            onAdminAction: onAdminAction
        )
        #else
        PosterCardContent(
            item: item,
            itemType: itemType,
            subtitle: subtitle,
            posterURL: posterURL
        )
        #endif
    }

    private var subtitleText: String {
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        if itemType == .series {
            if let count = item.childCount {
                parts.append(loc.localized(count == 1 ? "tvShows.season" : "tvShows.seasonsPlural", count))
            }
        } else {
            if let rating = item.communityRating {
                parts.append(String(format: "%.1f", rating))
            }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Poster Card Content

/// Renders the actual card chrome (poster `NavigationLink` + admin overlay +
/// title/subtitle rows) from values `LibraryPosterCard.body` has already
/// computed. Kept as its own `View` (not a `ViewModifier`) so the tvOS
/// `dimUnfocusedPosters` spotlight — which needs `.focused($isFocused)` on
/// the `NavigationLink` AND the `.opacity`/`.animation` dim on the outer
/// `VStack` spanning both the poster and the title rows — can own its own
/// `@FocusState` without touching `LibraryPosterCard.body`. A `ViewModifier`
/// can't do this: `.focused` only binds correctly when attached directly to
/// the focusable control, so a modifier applied there could only dim that
/// control, not the title text below it too. Byte-identical dim semantics to
/// the pre-refactor code, now isolated one level down: `PosterCardContent`'s
/// own `body` re-evaluates per focus step (cheap — pure composition from
/// already-computed values), while `LibraryPosterCard.body` never does.
private struct PosterCardContent: View {
    @Environment(AppState.self) private var appState

    let item: BaseItemDto
    let itemType: BaseItemKind
    let subtitle: String
    let posterURL: URL?
    #if os(iOS)
    var onAdminAction: ((BaseItemDto, AdminItemMenu.Destination) -> Void)? = nil
    #endif

    #if os(tvOS)
    // Opt-in "spotlight" — dims this card while a *sibling* holds focus. Read
    // per-card via `@FocusState` so no grid-level focus plumbing is needed; the
    // feature is gated on the `dimUnfocusedPosters` setting (default off).
    @Environment(\.motionEffectsEnabled) private var motionEnabled
    @AppStorage(SettingsKey.dimUnfocusedPosters) private var dimUnfocused = SettingsKey.Default.dimUnfocusedPosters
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            ZStack(alignment: .bottomTrailing) {
                NavigationLink {
                    if let id = item.id {
                        MediaDetailScreen(itemId: id, itemType: itemType)
                    }
                } label: {
                    Color.clear
                        .aspectRatio(2 / 3, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            CinemaLazyImage(url: posterURL, fallbackIcon: "film")
                        }
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                        .cinemaFocus()
                }
                #if os(tvOS)
                .buttonStyle(CinemaTVCardButtonStyle())
                .focused($isFocused)
                #else
                .buttonStyle(.plain)
                #endif
                .accessibilityLabel([item.name, subtitle.isEmpty ? nil : subtitle].compactMap { $0 }.joined(separator: ", "))
                // Long-press / long-press-select watched + favorite actions.
                // On the NavigationLink (the focusable button), never its label,
                // so tvOS focus is untouched; coexists with the admin ellipsis
                // ZStack sibling below (taps hit the menu, long-press hits this).
                .mediaCardContextMenu(item: item)

                #if os(iOS)
                if appState.isAdministrator {
                    AdminItemMenu(
                        item: item,
                        onSelectDestination: { dest in
                            onAdminAction?(item, dest)
                        }
                    )
                    .background(Circle().fill(.ultraThinMaterial))
                    .padding(CinemaSpacing.spacing2)
                }
                #endif
            }

            titleRows
                .accessibilityHidden(true)
        }
        #if os(tvOS)
        // Spotlight: recede while another card is focused (opt-in, default off).
        .opacity(dimUnfocused && !isFocused ? 0.55 : 1)
        .animation(motionEnabled ? .easeInOut(duration: 0.2) : nil, value: isFocused)
        .animation(motionEnabled ? .easeInOut(duration: 0.2) : nil, value: dimUnfocused)
        #endif
    }

    @ViewBuilder
    private var titleRows: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            Text("M\nM")
                .font(CinemaFont.label(.large))
                .lineLimit(2)
                .hidden()
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    Text(item.name ?? "")
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(2)
                }

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.outline)
                    .lineLimit(1)
            }
        }
    }
}
