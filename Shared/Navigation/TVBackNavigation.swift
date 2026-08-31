import SwiftUI
import Observation

// MARK: - tvOS "back" routing
//
// On tvOS the Menu (back) button has to do three different things depending on
// where the user stands, and SwiftUI gives exactly one lever to express that: a
// single `.onExitCommand` on the `TabView`. Everything here feeds that lever.
//
// Four properties of `.onExitCommand`, all measured on an Apple TV 4K simulator
// (tvOS 26.2) on 2026-08-31 with a purpose-built probe app, because none of
// them are derivable from the documentation:
//
//  1. A handler on the `TabView` fires when focus sits on the TAB BAR. That is
//     the reported bug's setting: a page whose content runs out of focusable
//     rows lets an Up press escape into the bar, and from there tvOS's default
//     Menu behaviour is to QUIT the app.
//  2. It also fires when focus is inside a PUSHED screen, and it SWALLOWS
//     `NavigationStack`'s own pop. So the moment the app wants any custom Menu
//     behaviour at the tab level it must own the pop as well — there is no
//     "handle this case and let the system keep the rest".
//  3. The ANCESTOR wins. An `.onExitCommand` installed on the pushed screen
//     itself never runs while the `TabView` carries one — which is why the two
//     handlers that used to drive the tvOS Settings sub-navigation had to move
//     onto this coordinator instead of staying where they were.
//  4. Passing `nil` restores the system default, i.e. suspends the app. That is
//     the only way to express "réduire l'app": `UIApplication.suspend()` is
//     private, and any non-nil handler consumes the press.
//
// A presented modal (`fullScreenCover`) is NOT affected: it is its own
// presentation context and the `TabView`'s handler does not see its Menu
// presses (measured — the cover dismissed, the handler stayed silent). Every
// existing modal `.onExitCommand { dismiss() }` in the app keeps working.
//
// The coordinator and the decision below are deliberately NOT `#if os(tvOS)`:
// they are pure state and pure logic, and the unit-test target builds against
// the iOS app. Only the view modifiers are platform-gated.

// MARK: - Decision

/// What the Menu button does, given where the user stands. Pure, so the rule
/// the user described is locked by tests rather than by the one call site.
enum TVBackDecision: Equatable {
    /// Something is stacked in this tab — go back one level.
    case goBack
    /// A main page that isn't the fallback one — go to that tab.
    case switchTab(String)
    /// Nothing left to undo — hand the press back to the system, which
    /// suspends the app.
    case suspend
}

enum TVBackPolicy {
    /// Order matters and is the user's own wording: back first, wherever focus
    /// happens to sit; then "a main page other than Accueil sends you to
    /// Accueil"; then "on Accueil, minimise".
    ///
    /// `homeTabID` is nil only when there are no tabs at all — unreachable in
    /// practice (`resolvedTabs` never resolves empty) but it must not decide to
    /// switch to a tab that doesn't exist.
    static func decide(tabID: String, hasBack: Bool, homeTabID: String?) -> TVBackDecision {
        if hasBack { return .goBack }
        guard let homeTabID, homeTabID != tabID else { return .suspend }
        return .switchTab(homeTabID)
    }
}

// MARK: - Coordinator

/// Knows, per tab, what the Menu button should undo — the screen pushed on top
/// of that tab's `NavigationStack`, or an in-place "sub-page" state such as the
/// tvOS Settings category detail.
///
/// Registration rides `onAppear`/`onDisappear`, which SwiftUI drives exactly the
/// way this needs (all four verified on the probe):
///
/// - pushing B fires `B.onAppear` **then** `A.onDisappear`, so at most one entry
///   per tab is live and it is always the screen actually on screen;
/// - popping fires `A.onAppear` then `B.onDisappear`, so the parent re-arms
///   before the child releases;
/// - leaving a tab fires the top screen's `onDisappear`, and coming back fires
///   its `onAppear` again — a tab that still holds a pushed screen re-arms
///   itself with no bookkeeping on the tab switch;
/// - therefore `canGoBack(in:)` describes the CURRENT tab only, which is what
///   stops "Menu on the Films tab" from popping something on Accueil.
@MainActor
@Observable
final class TVBackCoordinator {
    /// Registered back actions per tab, innermost last. In practice this holds
    /// at most one entry per tab (see above); it stays an array so an
    /// unexpected extra registration degrades to "undo the newest" rather than
    /// to a lost one.
    private var order: [String: [UUID]] = [:]
    private var actions: [UUID: () -> Void] = [:]

    /// True when this tab has something to go back to — a pushed screen, or a
    /// sub-page state that registered its own action.
    func canGoBack(in tabID: String) -> Bool {
        !(order[tabID] ?? []).isEmpty
    }

    func register(_ id: UUID, tabID: String, action: @escaping () -> Void) {
        // An empty tab id means the view isn't inside a tab's own stack (the
        // root-hosted deep-link cover, say, or any pushed screen on iOS, where
        // nothing injects one). Nothing there is reachable by the tab-level
        // handler, so registering would only ever create a stale entry.
        guard !tabID.isEmpty else { return }
        if actions[id] == nil { order[tabID, default: []].append(id) }
        actions[id] = action
    }

    func unregister(_ id: UUID, tabID: String) {
        actions[id] = nil
        order[tabID]?.removeAll { $0 == id }
        if order[tabID]?.isEmpty == true { order.removeValue(forKey: tabID) }
    }

    /// Runs the innermost registered action for this tab.
    func goBack(in tabID: String) {
        guard let id = order[tabID]?.last, let action = actions[id] else { return }
        action()
    }

    /// Called when a tab's ROOT screen appears — the one moment we know for
    /// certain that nothing is stacked on it. Self-heals an entry whose
    /// `onDisappear` never ran (a screen pushed inside a modal that was torn
    /// down wholesale, say): a stale entry would make Menu silently do nothing
    /// on that tab root, which is precisely the class of dead input this whole
    /// feature exists to remove.
    func clear(tabID: String) {
        guard let ids = order.removeValue(forKey: tabID) else { return }
        for id in ids { actions[id] = nil }
    }
}

// MARK: - Current tab id

private struct TVTabIDKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    /// Id of the tab whose `NavigationStack` this view lives in. Injected by
    /// `MainTabView` on each tab's stack (tvOS only), so a pushed screen knows
    /// which tab to register its "back" against. Empty everywhere else.
    var tvTabID: String {
        get { self[TVTabIDKey.self] }
        set { self[TVTabIDKey.self] = newValue }
    }
}

// MARK: - Registration modifiers

#if os(tvOS)

private struct TVBackActionModifier: ViewModifier {
    let action: () -> Void

    // Optional, per the project rule: a non-optional `@Environment(Type.self)`
    // for an `@Observable` traps at runtime when absent, and these screens are
    // also hosted in modals that re-inject the environment by hand.
    @Environment(TVBackCoordinator.self) private var coordinator: TVBackCoordinator?
    @Environment(\.tvTabID) private var tabID
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            // The closure is captured once, at appear. Safe for both uses here:
            // `dismiss` is a stable value, and the Settings actions only write
            // to `SettingsNavCoordinator`, a reference type.
            .onAppear { coordinator?.register(id, tabID: tabID, action: action) }
            .onDisappear { coordinator?.unregister(id, tabID: tabID) }
    }
}

private struct TVPushedScreenModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.modifier(TVBackActionModifier(action: { dismiss() }))
    }
}

private struct TVTabRootModifier: ViewModifier {
    let tabID: String
    @Environment(TVBackCoordinator.self) private var coordinator: TVBackCoordinator?

    func body(content: Content) -> some View {
        content.onAppear { coordinator?.clear(tabID: tabID) }
    }
}

#endif

extension View {
    /// Marks a screen that is PUSHED onto a tab's `NavigationStack`, so the
    /// tab-level Menu handler pops it instead of quitting the app or jumping to
    /// Accueil. Needed because that handler swallows the stack's own pop (see
    /// the file header).
    ///
    /// Apply it to screens that are only ever pushed (`MediaDetailScreen`,
    /// `PersonDetailScreen`…); for a screen that doubles as a tab root, apply it
    /// at the push site instead, or it would register itself as its own root.
    /// No-op on iOS.
    func tvPushedScreen() -> some View {
        #if os(tvOS)
        modifier(TVPushedScreenModifier())
        #else
        self
        #endif
    }

    /// Same contract as `tvPushedScreen()` for a "back" that is NOT a stack pop
    /// — an in-place sub-page state, such as the tvOS Settings category detail.
    /// No-op on iOS.
    func tvBackAction(_ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        modifier(TVBackActionModifier(action: action))
        #else
        self
        #endif
    }

    /// Applied by `MainTabView` to each tab's ROOT screen. No-op on iOS.
    func tvTabRoot(_ tabID: String) -> some View {
        #if os(tvOS)
        modifier(TVTabRootModifier(tabID: tabID))
        #else
        self
        #endif
    }
}
