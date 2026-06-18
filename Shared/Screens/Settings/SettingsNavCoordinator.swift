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
    /// Currently-pushed top-level Settings category (Appearance / Account /
    /// Server / Interface / Downloads / Admin landings). `nil` ⇒ landing page.
    var selectedCategory: SettingsCategory?

    /// Currently-pushed Interface sub-page (Main Menu / Home page / Detail
    /// page / Playback / Debug). `nil` ⇒ Interface hub.
    var selectedInterfaceSub: InterfaceSubcategory?

    /// Idempotency guard for the genre fetch: the Home-page sub-detail `.task`
    /// re-fires on every Settings remount. Reset to `false` on a failed/early
    /// fetch so a later appearance retries. (The genre list itself lives in the
    /// `@AppStorage` `library.cachedGenres` so it re-renders the
    /// navigationDestination — see `SettingsScreen.cachedGenresJSON`.)
    var homeGenresLoadAttempted = false

    init() {}
}
