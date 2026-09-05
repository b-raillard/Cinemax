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

                sectionLabel(loc.localized("syncplay.existingGroups"))

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
    /// Laid out like `WatchTogetherLobby`, deliberately: the two screens are one
    /// journey (create here, wait there) and they were built to different page
    /// contracts. This one ran edge to edge at 1920 px — the panel stretched
    /// across the screen, its accent CTA became a full-bleed slab whose focus
    /// ring bled over the panel's own corners, and the empty state floated in
    /// the middle of a column nothing else was centred in. Same page margin,
    /// same reading measure, same centring, same CTA width as the lobby.
    private var tvBody: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                    tvHeader
                    createSection
                    sectionLabel(loc.localized("syncplay.existingGroups"))
                    groupsSection
                }
                // Padding INSIDE the width frame — see the same note in
                // `WatchTogetherLobby.content`: applied outside two stacked
                // `maxWidth: .infinity` frames it is silently dropped.
                .padding(.horizontal, pagePadding)
                .padding(.vertical, CinemaSpacing.spacing8)
                .frame(maxWidth: readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .task { await model.load(api: appState.apiClient, loc: loc) }
    }

    private var tvHeader: some View {
        // `.center`, not `.firstTextBaseline`: the CTA's box is taller than the
        // title's line, so baseline-aligning them pushed the button's top above
        // the title and the row read as two things at different heights.
        HStack(alignment: .center) {
            Text(loc.localized("syncplay.title"))
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)
            Spacer(minLength: CinemaSpacing.spacing4)
            CinemaButton(title: loc.localized("action.done"), style: .ghost) { dismiss() }
                .frame(width: ctaWidth)
        }
    }

    @ViewBuilder
    private var groupsSection: some View {
        if model.isLoading {
            LoadingStateView()
                .frame(maxWidth: .infinity)
        } else if let error = model.errorMessage {
            ErrorStateView(message: error, retryTitle: loc.localized("action.retry")) {
                Task { await model.load(api: appState.apiClient, loc: loc) }
            }
            .frame(maxWidth: .infinity)
        } else if model.groups.isEmpty {
            // `EmptyStateView` centres its own content; without this it centres
            // inside its intrinsic width and sits off to the left of a column
            // everything else fills.
            EmptyStateView(
                systemImage: "person.2.slash",
                title: loc.localized("syncplay.noGroups.title"),
                subtitle: loc.localized("syncplay.noGroups.subtitle")
            )
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: CinemaSpacing.spacing3) {
                ForEach(model.groups) { group in
                    groupRow(group)
                }
            }
        }
    }

    // MARK: - tvOS metrics (same contract as `WatchTogetherLobby`)

    private var pagePadding: CGFloat { CinemaTVLayout.pagePadding }
    private var readingWidth: CGFloat { CinemaTVLayout.readingMaxWidth }
    private var ctaWidth: CGFloat { CinemaTVLayout.ctaWidth }
    #endif

    // MARK: - Shared pieces

    /// The group's NAME is the one thing about a session that reaches every
    /// account: `GroupInfoDto` carries no item, so somebody who may not read
    /// `/Sessions` learns what is playing from this string or from nothing at
    /// all. Naming the group after the work rather than after its owner
    /// therefore costs no request and no permission, and it is what lets a card
    /// on someone else's Home say what it is. The owner's name remains the
    /// fallback for the case the title is missing.
    private var defaultGroupName: String {
        let title = itemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let owner = appState.currentUser?.name
        if let owner, !owner.isEmpty {
            return loc.localized("syncplay.defaultName", owner)
        }
        return loc.localized("syncplay.title")
    }

    /// **RULE — tvOS gets NO name field here.** A `TextField` on tvOS is drawn
    /// by the system as a bright white capsule that cannot be restyled
    /// (`.textFieldStyle(.plain)` is inert there — measured), so it sat inside
    /// this dark panel looking like a foreign object; and reaching it costs a
    /// full-screen keyboard driven from a remote, to retype a name that already
    /// defaults to the work's title. The name is shown as text instead, so the
    /// user still knows what the session will be called. iPhone keeps the
    /// field: a soft keyboard is one tap and renaming a session is a
    /// reasonable thing to want there.
    /// One section label for both platforms. They had drifted — a bare
    /// `.font(.system(size:))` on iOS against a `CinemaFont` token on tvOS — so
    /// the same heading was two different things depending on the device.
    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(CinemaFont.label(.medium))
            .tracking(1.2)
            .foregroundStyle(CinemaColor.onSurfaceVariant)
    }

    private var createButton: some View {
        CinemaButton(
            title: loc.localized("syncplay.create"),
            style: .accent,
            icon: "plus.circle.fill",
            isLoading: model.busy
        ) {
            createGroup()
        }
    }

    #if os(tvOS)
    /// Name on the left, CTA on the right, one row.
    ///
    /// Stacked, the panel spent its whole 1100 pt measure on a short name and a
    /// button that then had to be either a full-bleed slab or a small control
    /// adrift in an empty half. On a 16:9 screen the row uses the width it has
    /// and the panel stays the height of one line.
    private var createSection: some View {
        HStack(alignment: .center, spacing: CinemaSpacing.spacing6) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                sectionLabel(loc.localized("syncplay.groupName"))
                HStack(spacing: CinemaSpacing.spacing3) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: CinemaScale.pt(24)))
                        .foregroundStyle(themeManager.accent)
                    Text(defaultGroupName)
                        .font(CinemaFont.bodyLarge)
                        .foregroundStyle(CinemaColor.onSurface)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: CinemaSpacing.spacing4)
            createButton
                .frame(width: ctaWidth)
        }
        .padding(CinemaSpacing.spacing5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }
    #else
    private var createSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            GlassTextField(
                label: loc.localized("syncplay.groupName"),
                text: $model.newGroupName,
                placeholder: defaultGroupName,
                icon: "person.2.fill"
            )
            createButton
        }
        .padding(CinemaSpacing.spacing4)
        .glassPanel()
    }
    #endif

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
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(themeManager.accent)
            }
            .padding(CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel()
        }
        // A full-width row is the "rangée" focus level: accent stroke and a
        // brightness lift, no growth. It carried `.plain` on tvOS, i.e. NO
        // focus treatment at all — the one focusable list on this screen said
        // nothing when the remote reached it.
        #if os(tvOS)
        .buttonStyle(TVFilterRowButtonStyle(accent: themeManager.accent))
        #else
        .buttonStyle(.plain)
        #endif
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
