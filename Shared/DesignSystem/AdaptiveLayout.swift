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

    // MARK: - Detail hero title logo

    /// The fiche draws the work's LOGO instead of its text title only when its
    /// hero is at least this wide (iPad, iPhone in landscape): narrower, the
    /// mark would shrink past its own legibility. Keyed on the measured width,
    /// not the size class — an iPhone in landscape is still `.compact`.
    static let detailLogoMinHeroWidth: CGFloat = 600
    /// 0.6 × tvOS's `CinemaTVLayout.logoHeight` / `logoMaxWidth` (160 / 700 pt):
    /// the same height-led box, scaled to arm's length.
    static let detailLogoHeight: CGFloat = 96
    static let detailLogoMaxWidth: CGFloat = 420
    /// Ceiling on the logo as a share of the CLAMPED hero height. An iPhone in
    /// landscape clamps the hero to ~200 pt (see `containerRelativeFrame` in
    /// `MediaDetailScreen.backdropSection`); a full 96 pt mark there would push
    /// the badges row out of the top of the clipped hero.
    static let detailLogoMaxHeroFraction: CGFloat = 0.3

    /// Height of the fiche's title logo for a hero of `size`, or `nil` when
    /// the hero is too narrow to carry one (the text title stands instead).
    static func detailLogoHeight(forHero size: CGSize) -> CGFloat? {
        guard size.width >= detailLogoMinHeroWidth else { return nil }
        return min(detailLogoHeight, size.height * detailLogoMaxHeroFraction)
    }
}

// MARK: - tvOS layout metrics

#if os(tvOS)
/// Fixed layout metrics for tvOS — the counterpart to `AdaptiveLayout`, which
/// answers only for iOS size classes.
///
/// tvOS renders to one canvas at one viewing distance, so these are constants
/// rather than functions of a size class. They were previously bare literals
/// repeated inside `#if os(tvOS)` branches across seven screens, which is how
/// the page margin came to be 112 pt on Library, Search, Home and the detail
/// fiche but 48 pt on Favourites and Watch History — two screens the user moves
/// between, with visibly different card sizes and gutters.
///
/// These are raw points on purpose: `CinemaScale.factor` scales *type*, and a
/// hero that grew with the font-size slider would push its own buttons off the
/// bottom of the screen.
enum CinemaTVLayout {
    // MARK: Page rhythm

    /// Horizontal margin for every full-page surface: grids, heroes, top bars,
    /// in-scroll titles, and the header of any rail that sits among them.
    static let pagePadding: CGFloat = CinemaSpacing.spacing20

    // MARK: Heroes

    /// Full-bleed hero on Home and the library browse layout.
    static let heroHeight: CGFloat = 820
    /// The detail fiche's backdrop — shorter, because the fiche's own content
    /// starts immediately below it.
    static let detailBackdropHeight: CGFloat = 760
    /// Caps the hero synopsis so it reads as a teaser, not a paragraph.
    static let heroOverviewMaxWidth: CGFloat = 600

    // MARK: Cards

    /// 2:3 poster in a horizontal rail.
    static let posterCardWidth: CGFloat = 200
    /// 16:9 card (Continue Watching, Next Up, Watching Now).
    static let wideCardWidth: CGFloat = 400
    /// Filmography card on the person page — wider than a rail poster because
    /// the page carries only two rows.
    static let filmographyCardWidth: CGFloat = 220
    /// Circular portrait at the top of the person page.
    static let personPortraitSize: CGFloat = 280
    /// 16:9 episode still in the detail fiche's episode row.
    static let episodeThumbnailWidth: CGFloat = 200

    // MARK: Grids

    /// Every 2:3 poster grid in the app: library, search, favourites, watch
    /// history, collections.
    static let gridColumnCount = 6
    /// Horizontal gutter between grid columns. Also the vertical row spacing —
    /// a square rhythm reads as a grid rather than as stacked rows.
    static let gridGutter: CGFloat = 32

    static var posterGridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridGutter), count: gridColumnCount)
    }

    // MARK: Calls to action

    /// One key of the parental-lock PIN pad. Square, and large enough that the
    /// focus ring of a key never touches its neighbours' — the pad is driven
    /// with a remote, where a mis-focused digit is a wrong PIN.
    static let pinKeySize: CGFloat = 120

    /// Standard button width for a sheet's confirm/dismiss action.
    static let ctaWidth: CGFloat = 240
    /// A hero's Play button — narrower than `ctaWidth` because it sits beside a
    /// second button rather than alone.
    static let heroPlayButtonWidth: CGFloat = 220
    /// The documented Play/Lecture label exception: a bare 28 pt rather than a
    /// `CinemaScale.pt` value, so the primary CTA keeps its weight whatever the
    /// user's font-size setting.
    static let ctaLabelFontSize: CGFloat = 28
    /// One height for every control in the fiche's action row — the Play CTA,
    /// « Depuis le début » and the icon-over-label accessories. They used to
    /// size themselves (≈77 pt for Play, ≈115 pt for an accessory), so the
    /// row's rhythm was set by its secondary controls.
    static let actionRowHeight: CGFloat = 80
    /// Width of one accessory (favourite, watched, playlist…) beside Play.
    /// Fixed so the row's geometry never depends on how long a translation is.
    static let accessoryButtonWidth: CGFloat = 150

    // MARK: Prose

    /// Caps a paragraph's measure. Unbounded, a synopsis ran the full 1920 px —
    /// roughly 200 characters a line, which is unreadable at 3 m.
    static let readingMaxWidth: CGFloat = 1100
    /// Caps a settings-style column (server list, privacy rows, help text) on a
    /// full-screen cover. Wider than `readingMaxWidth` because rows carry a
    /// control at their trailing edge, not just prose.
    static let formMaxWidth: CGFloat = 1400

    // MARK: Title logo

    /// A title logo is sized by HEIGHT, not width: marks vary from a short
    /// wordmark to a long sentence, and pinning the width would make one tower
    /// over the next. The width is only a ceiling for the longest of them.
    static let logoHeight: CGFloat = 160
    static let logoMaxWidth: CGFloat = 700
}
#endif
