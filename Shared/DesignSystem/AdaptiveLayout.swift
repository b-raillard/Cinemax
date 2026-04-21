import SwiftUI

/// Size-class-aware layout metrics for iOS.
///
/// Phone uses the existing compact values (unchanged). iPad (`horizontalSizeClass == .regular`)
/// gets larger poster cards, denser adaptive grids, and roomier padding. tvOS is handled by
/// the existing `#if os(tvOS)` branches at each call site and does not consult this helper.
///
/// Grids use `GridItem(.adaptive(minimum:))` on iPad so the column count auto-scales with
/// available width (including sidebar, split view, Stage Manager). iPhone keeps its fixed
/// column count so card sizing stays stable across its narrow range of widths.
enum AdaptiveLayout {
    /// Narrow compact horizontal class (iPhone) vs wide regular class (iPad).
    enum Form {
        case compact
        case regular
    }

    static func form(horizontalSizeClass: UserInterfaceSizeClass?) -> Form {
        horizontalSizeClass == .regular ? .regular : .compact
    }

    // MARK: - Horizontal-scroll card widths

    /// 2:3 poster card in a horizontal-scroll row (HomeScreen recentlyAdded, genre rows).
    static func posterCardWidth(for form: Form) -> CGFloat {
        form == .regular ? 180 : 140
    }

    /// 16:9 wide card (HomeScreen continue-watching, watching-now).
    static func wideCardWidth(for form: Form) -> CGFloat {
        form == .regular ? 380 : 280
    }

    // MARK: - Grids (`LazyVGrid`)

    /// Grid columns for 2:3 poster grids (search results, filtered library).
    /// iPhone: fixed 3 flexible columns. iPad: adaptive minimum so landscape packs more.
    static func posterGridColumns(for form: Form) -> [GridItem] {
        switch form {
        case .compact:
            return Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)
        case .regular:
            return [GridItem(.adaptive(minimum: 160), spacing: 16)]
        }
    }

    /// Grid columns for browse-genre tiles (shorter, wider rectangles).
    static func browseGenreColumns(for form: Form) -> [GridItem] {
        switch form {
        case .compact:
            return Array(repeating: GridItem(.flexible(), spacing: CinemaSpacing.spacing3), count: 2)
        case .regular:
            return [GridItem(.adaptive(minimum: 220), spacing: CinemaSpacing.spacing3)]
        }
    }

    /// Grid columns for the user-switch sheet. Smaller minimum since avatars are compact.
    static func userGridColumns(for form: Form) -> [GridItem] {
        switch form {
        case .compact:
            return Array(repeating: GridItem(.flexible(), spacing: CinemaSpacing.spacing3), count: 3)
        case .regular:
            return [GridItem(.adaptive(minimum: 150), spacing: CinemaSpacing.spacing3)]
        }
    }

    // MARK: - Padding / content width

    /// Horizontal screen padding for grids and scroll content.
    static func horizontalPadding(for form: Form) -> CGFloat {
        form == .regular ? CinemaSpacing.spacing6 : CinemaSpacing.spacing3
    }

    /// Maximum readable width for prose on large iPads (detail overviews, license body).
    /// `nil` means "no cap — fill the container".
    static func readingMaxWidth(for form: Form) -> CGFloat? {
        form == .regular ? 900 : nil
    }

    // MARK: - Hero / backdrop heights

    /// HomeScreen hero backdrop.
    static func heroHeight(for form: Form) -> CGFloat {
        form == .regular ? 500 : 360
    }

    /// MediaDetailScreen backdrop hero.
    static func detailBackdropHeight(for form: Form) -> CGFloat {
        form == .regular ? 460 : 310
    }
}
