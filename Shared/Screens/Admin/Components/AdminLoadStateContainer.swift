#if os(iOS)
import SwiftUI
import CinemaxKit

/// Switches between loading, error, empty, and content states for admin
/// screens. Centralises the pattern so every admin list/form/grid behaves the
/// same on failure and empty, and surfaces a retry affordance uniformly.
///
/// Callers drive the state (typically from a view model). Content is built by
/// a closure so we don't impose a container shape — Users uses a grid, Devices
/// a list, Dashboard a VStack of cards.
@MainActor
struct AdminLoadStateContainer<Content: View>: View {
    let isLoading: Bool
    let errorMessage: String?
    let isEmpty: Bool
    let emptyIcon: String
    let emptyTitle: String
    let emptySubtitle: String?
    let emptyActionTitle: String?
    let onRetry: () -> Void
    let onEmptyAction: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @Environment(LocalizationManager.self) private var loc

    init(
        isLoading: Bool,
        errorMessage: String? = nil,
        isEmpty: Bool = false,
        emptyIcon: String = "tray",
        emptyTitle: String = "",
        emptySubtitle: String? = nil,
        emptyActionTitle: String? = nil,
        onRetry: @escaping () -> Void,
        onEmptyAction: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.isEmpty = isEmpty
        self.emptyIcon = emptyIcon
        self.emptyTitle = emptyTitle
        self.emptySubtitle = emptySubtitle
        self.emptyActionTitle = emptyActionTitle
        self.onRetry = onRetry
        self.onEmptyAction = onEmptyAction
        self.content = content
    }

    var body: some View {
        if isLoading {
            LoadingStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = errorMessage {
            ErrorStateView(
                message: message,
                retryTitle: loc.localized("action.retry"),
                onRetry: onRetry
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isEmpty {
            EmptyStateView(
                systemImage: emptyIcon,
                title: emptyTitle,
                subtitle: emptySubtitle,
                actionTitle: emptyActionTitle,
                onAction: onEmptyAction
            )
        } else {
            content()
        }
    }
}
#endif
