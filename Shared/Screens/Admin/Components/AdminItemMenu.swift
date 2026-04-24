#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Admin 3-dot menu shared between `MediaDetailScreen` and the admin
/// overlay on poster cards. Always scoped to one `BaseItemDto`; the
/// four actions (Identifier / Edit metadata / Refresh metadata / Delete
/// media) map onto existing admin endpoints.
///
/// Hosts its own `navigationDestination(item:)` so picking an action from
/// the menu pushes the corresponding admin screen onto the surrounding
/// NavigationStack. Callers wrap the menu in whatever label they want
/// (an ellipsis toolbar button, a blur-circle overlay on a poster card, …).
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

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    @State private var destination: Destination?
    @State private var showDeleteConfirm = false
    @State private var isRefreshing = false

    enum Destination: Hashable {
        case identify
        case editMetadata
    }

    var body: some View {
        Menu {
            Button {
                destination = .identify
            } label: {
                Label(loc.localized("admin.item.identify"), systemImage: "magnifyingglass")
            }

            Button {
                destination = .editMetadata
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CinemaColor.onSurface)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(loc.localized("admin.item.menu"))
        .navigationDestination(item: $destination) { dest in
            switch dest {
            case .identify:
                IdentifyScreen(item: item)
            case .editMetadata:
                MetadataEditorScreen(item: item)
            }
        }
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
#endif
