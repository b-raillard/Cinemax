#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Admin 3-dot menu shared between `MediaDetailScreen` and the admin
/// overlay on poster cards. Always scoped to one `BaseItemDto`; the
/// four actions (Identifier / Edit metadata / Refresh metadata / Delete
/// media) map onto existing admin endpoints.
///
/// **Navigation contract**: the menu does NOT host its own
/// `navigationDestination(item:)`. SwiftUI silently ignores destination
/// modifiers placed inside lazy containers (`LazyVGrid`/`LazyHStack`/
/// `LazyVStack`/`List`), and `LibraryPosterCard` — the menu's main
/// caller — is rendered inside the library `LazyVGrid`. Instead, the
/// menu fires `onSelectDestination(_:)` and the caller stores the result
/// in a `@State AdminMenuPushIntent?` hosted on the screen body (outside
/// the lazy container) and binds `.navigationDestination(item:)` there.
///
/// Refresh uses the server's default mode (no "replace all" flags); power
/// users reach the full refresh-options form via Edit metadata → Actions.
/// Delete reuses `DestructiveConfirmSheet` with the item title as the
/// type-to-confirm phrase — same pattern as the editor's Delete tab.
struct AdminItemMenu: View {
    let item: BaseItemDto
    /// Fired on successful delete so callers can pop navigation or remove
    /// the item from a local list. Nil by default — callers that rely on
    /// the `.cinemaxShouldRefreshCatalogue` broadcast can skip this.
    var onItemDeleted: (() -> Void)? = nil
    /// Fired when the user picks a menu action that requires pushing a
    /// new screen (Identify / Edit metadata). The caller stores the value
    /// in an `@State AdminMenuPushIntent?` and hosts the matching
    /// `navigationDestination` on a non-lazy ancestor.
    var onSelectDestination: (Destination) -> Void

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    @State private var showDeleteConfirm = false
    @State private var isRefreshing = false

    enum Destination: Hashable {
        case identify
        case editMetadata
    }

    var body: some View {
        Menu {
            Button {
                onSelectDestination(.identify)
            } label: {
                Label(loc.localized("admin.item.identify"), systemImage: "magnifyingglass")
            }

            Button {
                onSelectDestination(.editMetadata)
            } label: {
                Label(loc.localized("admin.item.editMetadata"), systemImage: "square.and.pencil")
            }

            Button {
                Task { await refresh() }
            } label: {
                Label(loc.localized("admin.item.refreshMetadata"), systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshing)

            Divider()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label(loc.localized("admin.item.delete"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: CinemaScale.pt(16), weight: .semibold))
                .foregroundStyle(CinemaColor.onSurface)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(loc.localized("admin.item.menu"))
        .sheet(isPresented: $showDeleteConfirm) {
            DestructiveConfirmSheet(
                title: loc.localized("admin.metadata.delete.title"),
                message: String(
                    format: loc.localized("admin.metadata.delete.message"),
                    item.name ?? ""
                ),
                requiredPhrase: item.name ?? "",
                confirmLabel: loc.localized("admin.metadata.delete.confirm"),
                onConfirm: { await deleteItem() }
            )
        }
    }

    // MARK: - Actions

    private func refresh() async {
        guard let id = item.id, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await appState.apiClient.refreshItem(
                id: id,
                metadataMode: .default,
                imageMode: .default,
                replaceAllMetadata: false,
                replaceAllImages: false
            )
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
            toasts.success(loc.localized("admin.metadata.actions.refresh.success"))
        } catch {
            toasts.error(error.localizedDescription)
        }
    }

    private func deleteItem() async {
        guard let id = item.id else { return }
        do {
            try await appState.apiClient.deleteItem(id: id)
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
            toasts.success(loc.localized("admin.metadata.delete.success"))
            onItemDeleted?()
        } catch {
            toasts.error(error.localizedDescription)
        }
    }
}

/// Pending admin-menu navigation push, lifted to a screen-level
/// `@State` so `navigationDestination(item:)` can live outside lazy
/// containers (per the contract on `AdminItemMenu`). Hashable
/// implementation is id-based — `BaseItemDto` itself doesn't need to
/// be Hashable.
struct AdminMenuPushIntent: Hashable, Identifiable {
    let item: BaseItemDto
    let destination: AdminItemMenu.Destination

    var id: String { (item.id ?? "") + "|" + destinationKey }

    private var destinationKey: String {
        switch destination {
        case .identify:     return "identify"
        case .editMetadata: return "editMetadata"
        }
    }

    static func == (lhs: AdminMenuPushIntent, rhs: AdminMenuPushIntent) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Shared `navigationDestination` body for `AdminMenuPushIntent`. Use as
/// `.navigationDestination(item: $adminPushIntent) { intent in
///     adminMenuPushDestination(for: intent)
/// }` on any non-lazy ancestor of an `AdminItemMenu` host.
@MainActor @ViewBuilder
func adminMenuPushDestination(for intent: AdminMenuPushIntent) -> some View {
    switch intent.destination {
    case .identify:
        IdentifyScreen(item: intent.item)
    case .editMetadata:
        MetadataEditorScreen(item: intent.item)
    }
}
#endif
