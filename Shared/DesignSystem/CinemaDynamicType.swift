import SwiftUI

/// Where Dynamic Type stops in this app, and why stopping it is **opt-in per
/// surface** rather than global.
///
/// `AppNavigation` used to cap the whole app at `.accessibility2`, with the
/// stated reason "hero titles and the tab bar would collapse". Two things were
/// wrong with that. It punished the wrong people — a user on one of the three
/// largest accessibility sizes got a SMALLER layout than they asked for on
/// every screen, the reading ones (a synopsis, an episode overview, a help
/// sheet, the licences) included, which is precisely where the setting earns
/// its keep. And it protected surfaces that never needed protecting: the Home
/// and library heroes, the fiche's title and every poster card size their type
/// through `CinemaScale.pt`, which reads the app's own `uiScale` and **not**
/// Dynamic Type, so removing the cap cannot move them by a point.
///
/// What genuinely follows Dynamic Type today is: the native tab-bar / sidebar
/// labels (`MainTabView` sets no font on them), native `List` / `Form` chrome,
/// and text using `CinemaFont.dynamic*`. So the cap now lives on the few
/// surfaces whose geometry is fixed by something other than their own text.
enum CinemaDynamicType {
    /// The ceiling a layout-bound surface accepts. Same value the root cap used,
    /// so nothing about those surfaces changes — what changes is everything else.
    static let layoutCap: DynamicTypeSize = .accessibility2

    /// How far a `CinemaFont.dynamicBodyLayoutBound` may grow, as a MULTIPLE of
    /// its app-scaled base size.
    ///
    /// A separate knob from `layoutCap` because the two act on different
    /// machinery: `layoutCap` bounds SwiftUI's own environment scaling, while
    /// `CinemaFont.dynamic*` computes a point size from `UIFontMetrics`, which
    /// reads the SYSTEM preferred size and ignores the environment entirely — so
    /// a `.dynamicTypeSize(...)` modifier does not bound it, and text inside a
    /// capped surface would keep growing past its box without this.
    static let layoutBoundMaxGrowth: CGFloat = 1.35
}

extension View {
    /// Caps Dynamic Type on a surface whose geometry cannot follow it — a hero
    /// clamped to a viewport fraction, a fixed-width card in a carousel, the
    /// tab bar, the player host. See `CinemaDynamicType` for why this is opt-in.
    ///
    /// Apply it as high as the fixed geometry reaches and no higher: anything
    /// outside it (a synopsis under a hero, the sheet a card's "see more" opens)
    /// must keep scaling all the way up.
    func layoutBoundDynamicType() -> some View {
        dynamicTypeSize(...CinemaDynamicType.layoutCap)
    }
}
