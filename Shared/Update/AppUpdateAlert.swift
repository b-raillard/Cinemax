import SwiftUI

/// The launch prompt for « une nouvelle version est disponible ».
///
/// Hosted ONCE at the root of `AppNavigation`, like every other app-wide
/// presentation: it has to survive whichever branch is on screen, and it must
/// not be re-declared per screen.
///
/// An alert rather than a toast, deliberately: `ToastCenter` is for feedback
/// and recoverable errors, and this asks the user for a decision — the
/// project's own rule on the split.
struct AppUpdatePresentation: ViewModifier {
    let checker: AppUpdateChecker
    let loc: LocalizationManager

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: isPresented) {
                actions
            } message: {
                Text(message)
            }
    }

    // MARK: - Presentation state

    /// **A required update cannot be dismissed.** `decline()` acts on `.offer`
    /// alone, so a dismissal attempt while `.required` leaves the decision
    /// standing and the alert comes straight back. That is the whole mechanism
    /// of the mandatory case — there is no separate "blocking" surface, and
    /// `AppUpdatePolicy` guarantees `.required` only ever names a release that
    /// genuinely exists on the Store.
    private var isPresented: Binding<Bool> {
        Binding(
            get: { checker.decision != .none },
            set: { presented in
                guard !presented else { return }
                checker.decline()
            }
        )
    }

    private var title: String {
        switch checker.decision {
        case .required: loc.localized("update.required.title")
        case .offer, .none: loc.localized("update.available.title")
        }
    }

    private var message: String {
        switch checker.decision {
        case .none:
            ""
        case .offer(let release):
            [loc.localized("update.available.message", release.displayVersion, installedVersion), platformHint]
                .compactMap { $0 }
                .joined(separator: "\n\n")
        case .required(let release):
            [loc.localized("update.required.message", release.displayVersion), platformHint]
                .compactMap { $0 }
                .joined(separator: "\n\n")
        }
    }

    /// Said only when there is no button to press: where the App Store cannot
    /// be opened from here (tvOS without the Store app, e.g. the simulator),
    /// the alert says where to go instead.
    private var platformHint: String? {
        #if os(tvOS)
        checker.storeURLToOpen == nil ? loc.localized("update.tvos.hint") : nil
        #else
        nil
        #endif
    }

    private var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    // MARK: - Buttons

    @ViewBuilder
    private var actions: some View {
        switch checker.decision {
        case .none:
            EmptyView()
        case .offer:
            updateButton()
            Button(loc.localized("update.action.later"), role: .cancel) { checker.decline() }
        case .required:
            updateButton()
            #if os(tvOS)
            // The only honest action left on tvOS: re-ask the Store, so a user
            // who has just updated from the system App Store gets out of here
            // without relaunching.
            Button(loc.localized("update.action.retry")) {
                Task { await checker.refresh() }
            }
            #endif
        }
    }

    /// Rendered only where it can actually do something — the lookup carried
    /// a page and this device can open it (see `storeURLToOpen`). A button
    /// that silently does nothing is worse than an absent one.
    @ViewBuilder
    private func updateButton() -> some View {
        if checker.storeURLToOpen != nil {
            Button(loc.localized("update.action.update")) { checker.openStore() }
        }
    }
}
