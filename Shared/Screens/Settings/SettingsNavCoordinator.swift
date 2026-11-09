import SwiftUI

/// Owns the Settings screen's sub-navigation state outside of `SettingsScreen`
/// itself. tvOS's `TabView` is backed by `UITabBarController` which uses
/// position-based indexing for child view controllers — when the resolved
/// tabs list shifts (toggle off, reorder, change tab source) and Settings
/// lands at a different index, UIKit recreates the hosting controller, the
/// SwiftUI `@State` inside `SettingsScreen` resets, and the user is dumped
/// back to the Settings landing mid-edit.
///
/// Hoisting these two pieces of navigation state up to `AppNavigation` (which
/// never remounts during normal usage) makes them survive the `SettingsScreen`
/// remount. iOS doesn't exhibit the bug but uses the same coordinator for
/// symmetry and to avoid platform-specific state plumbing.
@MainActor @Observable
final class SettingsNavCoordinator {
    /// Currently-pushed top-level Settings category (Appearance / Interface /
    /// Playback / Account / Server / Admin landings). `nil` ⇒ landing page.
    var selectedCategory: SettingsCategory?

    /// Currently-pushed Interface sub-page (Main Menu / Home page / Library /
    /// Detail page). `nil` ⇒ Interface hub.
    var selectedInterfaceSub: InterfaceSubcategory?

    /// tvOS: Apparence → « Icône de l'app » (design B), a third-level page
    /// like an Interface sub-page. iOS pushes its own page instead.
    var showsAppIconPage = false

    /// tvOS: Demandes → a user's page (the Jellyfin user id). Here rather
    /// than in the page so the « ‹ Demandes » row can close it before the
    /// category — iOS pushes the page instead.
    var requestsUserId: String?

    /// tvOS: Demandes → one of its pages (« À valider », « Qui peut
    /// demander »…, layout A). Closed by the « ‹ Demandes » row after a
    /// user's page and before the category; iOS pushes the page instead.
    var requestsPage: RequestsPage?

    init() {}
}
