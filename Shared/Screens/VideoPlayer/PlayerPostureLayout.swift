import CoreGraphics

/// The iPhone Duo hinge, detached from `UIHinge.Status` (iOS 27.1 SDK only) so
/// the decision and its tests compile with any SDK.
enum HingeReading: Equatable, Sendable {
    case unknown, closed, partiallyOpen, fullyOpen
}

enum PlayerLayoutMode: Equatable, Sendable {
    /// The player as it always was: full-screen video, HUD on top.
    case regular
    /// iPhone Duo half-folded in portrait: video on the upper screen, a deck of
    /// blocks on the lower one. See the RULE in `VideoPlayer/CLAUDE.md`.
    case tabletop
}

/// Pure decision of the iOS player's layout mode.
enum PlayerPostureLayout {
    /// Table ⇔ half-open AND taller than wide. Half-open in landscape, the
    /// device opens like a book (vertical fold): regular player.
    static func mode(hinge: HingeReading, viewSize: CGSize) -> PlayerLayoutMode {
        guard hinge == .partiallyOpen, viewSize.height > viewSize.width else { return .regular }
        return .tabletop
    }

    /// `UIHingeInteraction` sends `hinge == nil` when the view moves between
    /// hierarchies (the player being presented, PiP): not a posture change, so
    /// the last known reading stands.
    static func reading(previous: HingeReading, update: HingeReading?) -> HingeReading {
        update ?? previous
    }

    /// Settings → Lecture → Débogage « Simuler le mode table »: any iPhone held
    /// in portrait gets the Duo's table layout, to see and test it without one.
    static func effectiveHinge(_ reading: HingeReading, simulateTabletop: Bool) -> HingeReading {
        simulateTabletop ? .partiallyOpen : reading
    }

    /// The deck's lock exists only in table mode; locked, the deck never hides
    /// on the timer…
    static func autoHides(mode: PlayerLayoutMode, locked: Bool) -> Bool {
        !(mode == .tabletop && locked)
    }

    /// …nor on a tap (user decision, 2026-10-07: only the lock decides).
    static func tapHides(mode: PlayerLayoutMode, locked: Bool) -> Bool {
        !(mode == .tabletop && locked)
    }

    /// A locked deck must be on screen in table mode: a HUD that faded in the
    /// other mode (landscape, unfolded) comes back on entry, no tap needed.
    static func revealsOnModeChange(mode: PlayerLayoutMode, locked: Bool, visible: Bool) -> Bool {
        !visible && !autoHides(mode: mode, locked: locked)
    }
}
