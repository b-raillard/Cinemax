import SwiftUI
import CinemaxKit

// MARK: - "Play on…" (Jellyfin remote control)
//
// Presented from `MediaDetailScreen`. Lists the Jellyfin sessions this user can
// drive and sends `PlayNow` to the one they pick.
//
// Deliberately send-only: once the command lands, this device has NO transport
// controls. The two banner controllers (`PlaybackLiveActivityController`,
// `NowPlayingInfoController`) are attached by the *local* presenters only, and
// nothing plays locally here — so there is no Live Activity, no Now Playing
// entry, no Control Center banner on the sender. The user pilots from the target
// device's own remote. That is the validated behaviour, not an oversight; see
// the "Remote control" section in CLAUDE.md.

/// The item a "Play on…" send targets — built by
/// `MediaDetailScreen.resolvedPlayTarget`, so it carries the same episode,
/// resume position and version the local Play button would have opened.
/// `Hashable` for `sheet(item:)`'s identity contract.
struct RemotePlayIntent: Identifiable, Hashable {
    let id = UUID()
    let itemId: String
    let title: String
    let startPositionTicks: Int?
    let mediaSourceId: String?
}

/// Screen-scoped model: the target list plus transient busy/error state.
/// Nothing here outlives the sheet — no global state, no background task.
@MainActor
@Observable
final class RemotePlayModel {
    var targets: [RemotePlayTarget] = []
    var isLoading = false
    var errorMessage: String?
    /// True while a send is in flight — disables every row.
    var busy = false

    /// Re-probes the controllable sessions when the sheet opens.
    ///
    /// The detail screen already probed once — that's what decided this button
    /// should exist — but that snapshot can be minutes old, and *this* list is
    /// the one a command gets sent against. A device that went to sleep in
    /// between has to fall out before the user can tap it.
    func load(userId: String?, api: any RemoteControlAPI, loc: LocalizationManager) async {
        guard let userId else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let sessions = try await api.getControllableSessions(userId: userId)
            targets = RemotePlayTarget.resolve(
                sessions: sessions,
                currentUserId: userId,
                excludingDeviceId: KeychainService.getOrCreateDeviceID()
            )
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
        }
    }
}

struct RemotePlaySheet: View {
    let intent: RemotePlayIntent

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toast

    @State private var model = RemotePlayModel()

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        NavigationStack {
            iosBody
                .navigationTitle(loc.localized("remote.title"))
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
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                itemHeader
                targetList
            }
            .padding(CinemaSpacing.spacing4)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .refreshable { await reload() }
        .task { await reload() }
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvBody: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                    // Focus section so an up-press from the target rows reaches
                    // Done instead of being absorbed (same reason as
                    // `PrivacySecurityScreen`'s tvOS header).
                    HStack {
                        Text(loc.localized("remote.title"))
                            .font(CinemaFont.headline(.large))
                            .foregroundStyle(CinemaColor.onSurface)
                        Spacer()
                        CinemaButton(title: loc.localized("action.done"), style: .ghost) { dismiss() }
                            .frame(width: 240)
                    }
                    .focusSection()

                    itemHeader
                    targetList
                }
                .padding(CinemaSpacing.spacing8)
            }
        }
        .task { await reload() }
    }
    #endif

    // MARK: - Shared pieces

    /// Reminds the user what they're about to send — the sheet can be opened
    /// from a series, where the target is the next-up episode, not the title
    /// the fiche is showing.
    private var itemHeader: some View {
        Text(intent.title)
            .font(CinemaFont.body)
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .lineLimit(2)
    }

    @ViewBuilder
    private var targetList: some View {
        if model.isLoading {
            LoadingStateView()
        } else if let error = model.errorMessage {
            ErrorStateView(message: error, retryTitle: loc.localized("action.retry")) {
                Task { await reload() }
            }
        } else if model.targets.isEmpty {
            // Reachable even though the button is gated on a non-empty list: the
            // target can have gone to sleep between that probe and this one.
            EmptyStateView(
                systemImage: "tv.slash",
                title: loc.localized("remote.noTargets.title"),
                subtitle: loc.localized("remote.noTargets.subtitle")
            )
        } else {
            VStack(spacing: CinemaSpacing.spacing3) {
                ForEach(model.targets) { target in
                    targetRow(target)
                }
            }
        }
    }

    /// One device row. The tvOS treatment is the validated full-width-row
    /// pattern (`TVFilterRowButtonStyle` + effects disabled, as in
    /// `LibrarySortFilterSheet`), NOT the bare `.buttonStyle(.plain)` that
    /// `WatchTogetherSheet` uses — that sheet is gated off, so its focus
    /// rendering was never validated on a TV, and these rows are the only
    /// interactive elements here besides Done.
    @ViewBuilder
    private func targetRow(_ target: RemotePlayTarget) -> some View {
        let row = rowButton(target)
        #if os(tvOS)
        row.buttonStyle(TVFilterRowButtonStyle(accent: themeManager.accent))
            .focusEffectDisabled()
            .hoverEffectDisabled()
        #else
        row.buttonStyle(.plain)
        #endif
    }

    private func rowButton(_ target: RemotePlayTarget) -> some View {
        Button {
            send(to: target)
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "tv")
                    .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(target))
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurface)
                        .lineLimit(1)
                    Text(subtitle(target))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: CinemaSpacing.spacing2)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: CinemaScale.pt(22), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
            }
            .padding(CinemaSpacing.spacing4)
            .glassPanel()
        }
        .disabled(model.busy)
        .accessibilityLabel(displayName(target))
        .accessibilityHint(loc.localized("remote.title"))
    }

    private func displayName(_ target: RemotePlayTarget) -> String {
        target.name.isEmpty ? loc.localized("remote.unknownDevice") : target.name
    }

    /// Client name, plus what the target is already playing when it is —
    /// the warning that sending will interrupt something.
    private func subtitle(_ target: RemotePlayTarget) -> String {
        var parts: [String] = []
        if let client = target.clientName, !client.isEmpty { parts.append(client) }
        if let playing = target.nowPlayingTitle, !playing.isEmpty {
            parts.append(loc.localized("remote.nowPlaying", playing))
        }
        return parts.isEmpty ? loc.localized("remote.idle") : parts.joined(separator: " • ")
    }

    // MARK: - Actions

    private func reload() async {
        await model.load(userId: appState.currentUserId, api: appState.apiClient, loc: loc)
    }

    private func send(to target: RemotePlayTarget) {
        guard !model.busy, !intent.itemId.isEmpty else { return }
        Task {
            model.busy = true
            do {
                try await appState.apiClient.playOnSession(
                    sessionId: target.id,
                    itemIds: [intent.itemId],
                    startPositionTicks: intent.startPositionTicks,
                    mediaSourceId: intent.mediaSourceId
                )
                model.busy = false
                toast.success(loc.localized("remote.sent", displayName(target)))
                dismiss()
            } catch {
                // Sheet stays open so the user can retry or pick another device.
                model.busy = false
                toast.error(loc.userFacingMessage(for: error))
            }
        }
    }
}

// MARK: - Presentation

/// Presents the picker — a bottom sheet on iOS, a full-screen cover on tvOS
/// (`.sheet` renders as a broken narrow modal on tvOS 26). Environment objects
/// are re-injected so the sheet's own `@Environment` reads resolve regardless of
/// automatic propagation. Same shape as `WatchTogetherPresentation`.
struct RemotePlayPresentation: ViewModifier {
    @Binding var sheet: RemotePlayIntent?
    let appState: AppState
    let themeManager: ThemeManager
    let loc: LocalizationManager
    let toast: ToastCenter

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.fullScreenCover(item: $sheet) { intent in sheetView(intent) }
        #else
        content.sheet(item: $sheet) { intent in sheetView(intent) }
        #endif
    }

    private func sheetView(_ intent: RemotePlayIntent) -> some View {
        RemotePlaySheet(intent: intent)
            .environment(appState)
            .environment(themeManager)
            .environment(loc)
            .environment(toast)
    }
}
