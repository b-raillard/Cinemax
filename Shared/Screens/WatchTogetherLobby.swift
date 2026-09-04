import SwiftUI
import CinemaxKit
import JellyfinAPI

/// The staging screen between "I opened a session" and "the film plays".
///
/// Without it, creating a session dropped the user straight into the player,
/// where the group sits in `Waiting` until every participant reports ready — a
/// black screen with nothing on it and no way back. It is also the only place
/// in the app that can answer *how do I get out of this*: before this screen
/// existed, `playbackDidDismiss()` was the sole caller of `leaveGroup()`, so
/// closing the player was the one and only exit.
///
/// **What it can and cannot offer, and why.** Jellyfin has no invitation
/// primitive — `POST /Sessions/{id}/Message` is the only way to reach another
/// person, and it delivers a plain toast that carries no join action. Worse,
/// enumerating other people's sessions needs `/Sessions`, which is admin-only
/// (`getControllableSessions` returns the caller's own). So "invite" is
/// **admin-only and is a notification**: it tells someone a session is open and
/// they join from the « En direct » row on their own Home. For everyone else
/// the screen says exactly that, rather than showing a button that cannot work.
struct WatchTogetherLobby: View {
    let itemId: String
    let title: String
    let backdropURL: URL?
    /// Proceed to the player.
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toast

    @State private var invitees: [InviteTarget] = []
    @State private var notified: Set<String> = []
    @State private var isLeaving = false

    private var controller: SyncPlayController { .shared }

    /// Someone we can notify: one live session belonging to another user.
    private struct InviteTarget: Identifiable, Equatable {
        let id: String          // session id
        let userName: String
        let deviceName: String
    }

    var body: some View {
        // The backdrop is a BACKGROUND, never a ZStack sibling. As a sibling it
        // drives the stack's size from `CinemaLazyImage`'s natural 1920 px, and
        // that width is then proposed to the content: the paragraph rendered on
        // one line, the whole column ran off both edges, and the header and the
        // participant chips ended up outside the viewport entirely. Exactly the
        // full-bleed-ZStack trap CLAUDE.md documents. `.background` never
        // participates in sizing.
        content
            .background { backdrop }
            .task { await loadInvitees() }
        #if os(tvOS)
        .onExitCommand { leave() }
        #endif
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            CinemaColor.surface
            if let backdropURL {
                CinemaLazyImage(url: backdropURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(0.35)
                    .blur(radius: 12)
            }
            CinemaGradient.heroOverlay
        }
        .ignoresSafeArea()
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            // Padding INSIDE the width frame, not wrapped around it. Applied
            // outside two stacked `maxWidth: .infinity` frames it was simply
            // ignored: the content ran edge to edge and off both sides, taking
            // the header and the participant chips out of the viewport
            // entirely — they were laid out, just not on screen.
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                header
                participantsSection
                inviteSection
                actions
                    .padding(.top, CinemaSpacing.spacing4)
            }
            .padding(.horizontal, pagePadding)
            .padding(.vertical, CinemaSpacing.spacing8)
            .frame(maxWidth: readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            HStack(spacing: CinemaSpacing.spacing2) {
                Circle()
                    .fill(themeManager.accent)
                    .frame(width: 8, height: 8)
                Text(loc.localized("syncplay.lobby.eyebrow").uppercased())
                    .font(CinemaFont.label(.medium))
                    .tracking(1.4)
                    .foregroundStyle(themeManager.accent)
            }
            Text(title)
                .font(CinemaFont.display(.small))
                .foregroundStyle(CinemaColor.onSurface)
            if let name = controller.groupName, !name.isEmpty {
                Text(name)
                    .font(CinemaFont.bodyLarge)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
        }
    }

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            Text(loc.localized("syncplay.lobby.participants").uppercased())
                .font(CinemaFont.label(.medium))
                .tracking(1.2)
                .foregroundStyle(CinemaColor.onSurfaceVariant)

            if controller.participants.isEmpty {
                Text(loc.localized("syncplay.lobby.alone"))
                    .font(CinemaFont.bodyLarge)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            } else {
                FlowLayout(spacing: CinemaSpacing.spacing3) {
                    ForEach(controller.participants, id: \.self) { name in
                        participantChip(name)
                    }
                }
            }
        }
    }

    private func participantChip(_ name: String) -> some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            UserAvatar(userId: nil, name: name, primaryImageTag: nil, size: avatarSize)
            Text(name == appState.currentUser?.name ? loc.localized("syncplay.you") : name)
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurface)
        }
        .padding(.horizontal, CinemaSpacing.spacing3)
        .padding(.vertical, CinemaSpacing.spacing2)
        .background(CinemaColor.surfaceContainerHigh, in: Capsule())
    }

    // MARK: - Invite

    @ViewBuilder
    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            Text(loc.localized("syncplay.lobby.invite").uppercased())
                .font(CinemaFont.label(.medium))
                .tracking(1.2)
                .foregroundStyle(CinemaColor.onSurfaceVariant)

            // The honest explanation comes FIRST, because it is what everyone
            // sees: joining happens from the other person's own Home, and the
            // notification below is only a nudge toward it.
            Text(loc.localized("syncplay.lobby.invite.how"))
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            if appState.isAdministrator {
                if invitees.isEmpty {
                    Text(loc.localized("syncplay.lobby.invite.nobody"))
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                } else {
                    ForEach(invitees) { target in
                        inviteRow(target)
                    }
                }
            }
        }
    }

    private func inviteRow(_ target: InviteTarget) -> some View {
        let done = notified.contains(target.id)
        return Button {
            notify(target)
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                UserAvatar(userId: nil, name: target.userName, primaryImageTag: nil, size: avatarSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.userName)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                    Text(target.deviceName)
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
                Spacer()
                Text(loc.localized(done ? "syncplay.lobby.invite.sent" : "syncplay.lobby.invite.send"))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(done ? CinemaColor.onSurfaceVariant : themeManager.accent)
            }
            .padding(CinemaSpacing.spacing3)
            .background(CinemaColor.surfaceContainer, in: RoundedRectangle(cornerRadius: CinemaRadius.large))
            .contentShape(Rectangle())
        }
        #if os(tvOS)
        .buttonStyle(TVFilterRowButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
        #else
        .buttonStyle(.plain)
        #endif
        .disabled(done)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: CinemaSpacing.spacing3) {
            CinemaButton(title: loc.localized("syncplay.lobby.start"), style: .accent) {
                onStart()
            }
            .frame(maxWidth: ctaWidth)

            CinemaButton(title: loc.localized("syncplay.lobby.leave"), style: .ghost) {
                leave()
            }
            .frame(maxWidth: ctaWidth)
            .disabled(isLeaving)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Behaviour

    private func leave() {
        guard !isLeaving else { return }
        isLeaving = true
        controller.leaveGroup()
        dismiss()
    }

    /// Admin-only, and best-effort: the message is a courtesy, so a failure
    /// costs the recipient a nudge, never the session.
    private func notify(_ target: InviteTarget) {
        notified.insert(target.id)
        Task {
            do {
                try await appState.apiClient.sendMessage(
                    sessionId: target.id,
                    header: loc.localized("syncplay.title"),
                    text: String(
                        format: loc.localized("syncplay.lobby.invite.message"),
                        appState.currentUser?.name ?? "", title
                    ),
                    timeoutMs: 15_000
                )
                toast.success(loc.localized("syncplay.lobby.invite.sentToast", target.userName))
            } catch {
                notified.remove(target.id)
                toast.error(loc.localized("syncplay.error"), message: loc.userFacingMessage(for: error))
            }
        }
    }

    /// Everyone else with a live session on this server. Non-admins get an
    /// empty list — `/Sessions` is elevated — which is why the section leads
    /// with the explanation rather than with this.
    private func loadInvitees() async {
        guard appState.isAdministrator else { return }
        let me = appState.currentUserId
        let sessions = (try? await appState.apiClient.getActiveSessions(activeWithinSeconds: 300)) ?? []
        invitees = sessions.compactMap { session in
            guard let id = session.id,
                  let user = session.userName,
                  (session.userID ?? "") != me,
                  !controller.participants.contains(user) else { return nil }
            return InviteTarget(id: id, userName: user, deviceName: session.deviceName ?? "")
        }
    }

    // MARK: - Metrics

    private var pagePadding: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.pagePadding
        #else
        CinemaSpacing.spacing5
        #endif
    }

    private var readingWidth: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.readingMaxWidth
        #else
        .infinity
        #endif
    }

    private var ctaWidth: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.ctaWidth
        #else
        // Bounded so the pair reads as a pair on an iPad, where an unbounded
        // button would stretch the full column width.
        420
        #endif
    }

    private var avatarSize: CGFloat {
        #if os(tvOS)
        44
        #else
        32
        #endif
    }
}
