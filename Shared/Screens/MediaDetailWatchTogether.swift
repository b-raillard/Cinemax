import SwiftUI
import CinemaxKit

// MARK: - Watch Together (SyncPlay) entry sheet
//
// Presented from `MediaDetailScreen`'s action row. Lists the groups currently
// open on the server (join one) or creates a fresh group for the item on
// screen. On success it seeds the group's queue (creator only) and calls back
// so the detail screen starts playback through its normal play path — the VLC
// presenter then binds to `SyncPlayController.shared` and the group stays in
// sync. Kept a lightweight sibling file, matching the `MediaDetail*` pattern.

/// Small screen-scoped model: just the discoverable group list + transient
/// busy/error state. Group membership itself lives on `SyncPlayController`.
@MainActor
@Observable
final class WatchTogetherModel {
    var groups: [SyncPlayGroup] = []
    var isLoading = false
    var errorMessage: String?
    var newGroupName = ""
    /// True while a create/join round-trip is in flight — disables the CTAs.
    var busy = false

    func load(api: any SyncPlayAPI, loc: LocalizationManager) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            groups = try await api.syncPlayListGroups()
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
        }
    }
}

struct WatchTogetherSheet: View {
    let itemId: String
    let itemTitle: String
    /// Called after a successful create/join so the caller starts playback.
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toast

    @State private var model = WatchTogetherModel()

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        NavigationStack {
            iosBody
                .navigationTitle(loc.localized("syncplay.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(loc.localized("action.done")) { dismiss() }
                            .tint(themeManager.accent)
                    }
                }
        }
        #endif
    }

    // MARK: - iOS

    #if os(iOS)
    private var iosBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                createSection

                Text(loc.localized("syncplay.existingGroups").uppercased())
                    .font(.system(size: CinemaScale.pt(12), weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)

                if model.isLoading {
                    LoadingStateView()
                } else if let error = model.errorMessage {
                    ErrorStateView(message: error, retryTitle: loc.localized("action.retry")) {
                        Task { await model.load(api: appState.apiClient, loc: loc) }
                    }
                } else if model.groups.isEmpty {
                    EmptyStateView(
                        systemImage: "person.2.slash",
                        title: loc.localized("syncplay.noGroups.title"),
                        subtitle: loc.localized("syncplay.noGroups.subtitle")
                    )
                } else {
                    VStack(spacing: CinemaSpacing.spacing3) {
                        ForEach(model.groups) { group in
                            groupRow(group)
                        }
                    }
                }
            }
            .padding(CinemaSpacing.spacing4)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .refreshable { await model.load(api: appState.apiClient, loc: loc) }
        .task { await model.load(api: appState.apiClient, loc: loc) }
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvBody: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                    HStack {
                        Text(loc.localized("syncplay.title"))
                            .font(CinemaFont.headline(.large))
                            .foregroundStyle(CinemaColor.onSurface)
                        Spacer()
                        CinemaButton(title: loc.localized("action.done"), style: .ghost) { dismiss() }
                            .frame(width: 240)
                    }

                    createSection

                    Text(loc.localized("syncplay.existingGroups"))
                        .font(CinemaFont.headline(.small))
                        .foregroundStyle(CinemaColor.onSurface)

                    if model.isLoading {
                        LoadingStateView()
                    } else if let error = model.errorMessage {
                        ErrorStateView(message: error, retryTitle: loc.localized("action.retry")) {
                            Task { await model.load(api: appState.apiClient, loc: loc) }
                        }
                    } else if model.groups.isEmpty {
                        EmptyStateView(
                            systemImage: "person.2.slash",
                            title: loc.localized("syncplay.noGroups.title"),
                            subtitle: loc.localized("syncplay.noGroups.subtitle")
                        )
                    } else {
                        VStack(spacing: CinemaSpacing.spacing3) {
                            ForEach(model.groups) { group in
                                groupRow(group)
                            }
                        }
                    }
                }
                .padding(CinemaSpacing.spacing8)
            }
        }
        .task { await model.load(api: appState.apiClient, loc: loc) }
    }
    #endif

    // MARK: - Shared pieces

    private var defaultGroupName: String {
        let owner = appState.currentUser?.name
        if let owner, !owner.isEmpty {
            return loc.localized("syncplay.defaultName", owner)
        }
        return itemTitle
    }

    private var createSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            GlassTextField(
                label: loc.localized("syncplay.groupName"),
                text: $model.newGroupName,
                placeholder: defaultGroupName,
                icon: "person.2.fill"
            )
            CinemaButton(
                title: loc.localized("syncplay.create"),
                style: .accent,
                icon: "plus.circle.fill",
                isLoading: model.busy
            ) {
                createGroup()
            }
        }
        .padding(CinemaSpacing.spacing4)
        .glassPanel()
    }

    private func groupRow(_ group: SyncPlayGroup) -> some View {
        Button {
            join(group)
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name.isEmpty ? loc.localized("syncplay.unnamedGroup") : group.name)
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurface)
                        .lineLimit(1)
                    Text(participantsSummary(group))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: CinemaSpacing.spacing2)
                Text(loc.localized("syncplay.join"))
                    .font(.system(size: CinemaScale.pt(14), weight: .bold))
                    .foregroundStyle(themeManager.accent)
            }
            .padding(CinemaSpacing.spacing4)
            .glassPanel()
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
    }

    private func participantsSummary(_ group: SyncPlayGroup) -> String {
        if group.participants.isEmpty {
            return loc.localized("syncplay.participants", 0)
        }
        let names = group.participants.joined(separator: ", ")
        return names
    }

    // MARK: - Actions

    private func createGroup() {
        guard !model.busy else { return }
        let name = model.newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? defaultGroupName : name
        Task {
            model.busy = true
            let ok = await SyncPlayController.shared.createGroup(
                named: finalName,
                api: appState.apiClient,
                loc: loc,
                toast: toast,
                currentUserName: appState.currentUser?.name
            )
            if ok {
                await SyncPlayController.shared.setQueue(itemId: itemId, startPositionTicks: 0)
            }
            model.busy = false
            if ok {
                dismiss()
                onStart()
            }
        }
    }

    private func join(_ group: SyncPlayGroup) {
        guard !model.busy else { return }
        Task {
            model.busy = true
            let ok = await SyncPlayController.shared.joinGroup(
                group,
                api: appState.apiClient,
                loc: loc,
                toast: toast,
                currentUserName: appState.currentUser?.name
            )
            model.busy = false
            if ok {
                dismiss()
                onStart()
            }
        }
    }
}
