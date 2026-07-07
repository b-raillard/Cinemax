import Foundation
import CinemaxKit
import OSLog

private let syncLogger = Logger(subsystem: "com.cinemax", category: "SyncPlay")

/// Drives a SyncPlay ("Watch Together") session: owns the current group, the
/// realtime socket, the client↔server clock offset, and the bridge to whatever
/// player surface is on screen. A single shared instance is consulted by the
/// VLC presenter (online path) — when `isInGroup`, the presenter routes the
/// user's play / pause / seek through this controller (which hits the REST
/// endpoint) instead of applying them locally; the server echoes the command
/// back over the socket and *that* echo is what actually moves the playhead, so
/// every participant stays in lockstep.
///
/// v1 scope: single shared group, transport sync only (play / pause / seek),
/// ~100 ms tolerance. Content selection is not synced — each participant opens
/// the item themselves; the group syncs the transport across whoever has a
/// player open.
@MainActor
@Observable
final class SyncPlayController {
    static let shared = SyncPlayController()

    // MARK: Observable state

    private(set) var group: SyncPlayGroup?
    private(set) var participants: [String] = []

    var isInGroup: Bool { group != nil }
    var participantCount: Int { participants.count }
    var groupName: String? { group?.name }

    // MARK: Dependencies (set on activation)

    @ObservationIgnored private var api: (any SyncPlayAPI)?
    @ObservationIgnored private var loc: LocalizationManager?
    @ObservationIgnored private var toast: ToastCenter?
    @ObservationIgnored private var currentUserName: String?

    // MARK: Socket + clock

    @ObservationIgnored private var socket: SyncPlaySocket?
    @ObservationIgnored private var socketTask: Task<Void, Never>?
    /// Estimated `serverClock - localClock`, in seconds. A command's server
    /// `When` maps to local time via `When - clockOffset`.
    @ObservationIgnored private var clockOffset: TimeInterval = 0
    @ObservationIgnored private var scheduledCommandTask: Task<Void, Never>?

    // MARK: Playback bridge (injected by the presenter)

    /// The player surface's transport hooks. All `@MainActor` — the controller
    /// only ever calls them on the main actor. They call the engine directly
    /// (never re-emit), so applying an inbound command can't loop back out.
    struct PlaybackBridge {
        let play: @MainActor () -> Void
        let pause: @MainActor () -> Void
        let seekMs: @MainActor (Int) -> Void
        let positionMs: @MainActor () -> Int
        /// Server `Stop` handling. v1: pause in place (don't tear down).
        let stop: @MainActor () -> Void
    }

    @ObservationIgnored private var bridge: PlaybackBridge?

    /// True while an inbound command is being applied — lets the presenter
    /// suppress the buffering/ready reports it would otherwise fire from the
    /// engine state change the command induces (avoids a feedback echo).
    @ObservationIgnored private(set) var isApplyingRemoteCommand = false

    /// Notified whenever the participant count changes so a UIKit HUD (the VLC
    /// presenter's "Watch Together" pill) can repaint without observation.
    @ObservationIgnored var onParticipantsChanged: (@MainActor (Int) -> Void)?

    private init() {}

    private static let ticksPerMillisecond = 10_000

    // MARK: - Group lifecycle (driven by the UI)

    /// Creates a group and starts a session. The realtime socket + clock are
    /// spun up first so we're ready for the server's `GroupJoined` echo.
    func createGroup(
        named name: String,
        api: any SyncPlayAPI,
        loc: LocalizationManager,
        toast: ToastCenter,
        currentUserName: String?
    ) async -> Bool {
        prepare(api: api, loc: loc, toast: toast, currentUserName: currentUserName)
        // Bring the socket up FIRST so we're listening when the server echoes
        // `GroupJoined` (which refines the optimistic group below).
        startSession()
        do {
            try await api.syncPlayNewGroup(name: name)
            // Optimistic placeholder until the socket's GroupJoined refines it.
            group = SyncPlayGroup(id: "", name: name, participants: currentUserName.map { [$0] } ?? [])
            participants = group?.participants ?? []
            notifyParticipants()
            return true
        } catch {
            reportError(error)
            teardownSession()
            return false
        }
    }

    /// Joins an existing group and starts a session.
    func joinGroup(
        _ target: SyncPlayGroup,
        api: any SyncPlayAPI,
        loc: LocalizationManager,
        toast: ToastCenter,
        currentUserName: String?
    ) async -> Bool {
        prepare(api: api, loc: loc, toast: toast, currentUserName: currentUserName)
        startSession()
        do {
            try await api.syncPlayJoinGroup(groupId: target.id)
            group = target
            participants = target.participants
            notifyParticipants()
            toast.info(loc.localized("syncplay.joined"))
            return true
        } catch {
            reportError(error)
            teardownSession()
            return false
        }
    }

    /// Sets the group's queue to a single item (the creator, at Play time).
    func setQueue(itemId: String, startPositionTicks: Int) async {
        guard let api else { return }
        do {
            try await api.syncPlaySetNewQueue(itemIds: [itemId], startPositionTicks: startPositionTicks)
        } catch {
            syncLogger.error("SyncPlay setQueue failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Leaves the group and tears the session down (user-initiated).
    func leaveGroup() {
        let api = self.api
        let loc = self.loc
        let toast = self.toast
        teardownSession()
        Task { try? await api?.syncPlayLeaveGroup() }
        if let loc, let toast { toast.info(loc.localized("syncplay.left")) }
    }

    /// Called by the presenter when its player is dismissed by the user. v1
    /// ties the group's lifetime to the player: closing playback leaves.
    func playbackDidDismiss() {
        guard isInGroup else { return }
        leaveGroup()
    }

    // MARK: - Playback bridge

    func bindPlayback(_ bridge: PlaybackBridge) {
        self.bridge = bridge
        notifyParticipants()
    }

    func unbindPlayback() {
        bridge = nil
        scheduledCommandTask?.cancel()
        scheduledCommandTask = nil
    }

    // MARK: - Outbound (user actions → server; the echo applies locally)

    func userDidPlay() {
        guard isInGroup, let api else { return }
        Task { try? await api.syncPlayUnpause() }
    }

    func userDidPause() {
        guard isInGroup, let api else { return }
        Task { try? await api.syncPlayPause() }
    }

    func userDidSeek(toMs ms: Int) {
        guard isInGroup, let api else { return }
        let ticks = max(0, ms) * Self.ticksPerMillisecond
        Task { try? await api.syncPlaySeek(positionTicks: ticks) }
    }

    // MARK: - Buffering / ready reporting

    func reportBuffering() {
        guard isInGroup, !isApplyingRemoteCommand, let api, let bridge else { return }
        let ticks = max(0, bridge.positionMs()) * Self.ticksPerMillisecond
        Task { try? await api.syncPlayBuffering(positionTicks: ticks, isPlaying: false, playlistItemId: nil) }
    }

    func reportReady(isPlaying: Bool) {
        guard isInGroup, !isApplyingRemoteCommand, let api, let bridge else { return }
        let ticks = max(0, bridge.positionMs()) * Self.ticksPerMillisecond
        Task { try? await api.syncPlayReady(positionTicks: ticks, isPlaying: isPlaying, playlistItemId: nil) }
    }

    // MARK: - Session plumbing

    private func prepare(
        api: any SyncPlayAPI,
        loc: LocalizationManager,
        toast: ToastCenter,
        currentUserName: String?
    ) {
        self.api = api
        self.loc = loc
        self.toast = toast
        self.currentUserName = currentUserName
    }

    private func startSession() {
        startSocket()
        Task { await self.sampleClock() }
    }

    private func startSocket() {
        guard let api else { return }
        socketTask?.cancel()
        // Capture the outgoing socket into a local so the detached stop Task
        // doesn't touch the MainActor-isolated `self.socket` off-actor.
        let previous = self.socket
        Task { await previous?.stop() }
        guard let socket = api.makeSyncPlaySocket() else {
            syncLogger.error("SyncPlay: could not open socket (not connected?)")
            return
        }
        self.socket = socket
        Task { await socket.start() }
        socketTask = Task { @MainActor [weak self] in
            for await message in socket.messages {
                self?.handle(message)
            }
        }
    }

    private func teardownSession() {
        group = nil
        participants = []
        scheduledCommandTask?.cancel(); scheduledCommandTask = nil
        socketTask?.cancel(); socketTask = nil
        let socket = self.socket
        self.socket = nil
        Task { await socket?.stop() }
        clockOffset = 0
        notifyParticipants()
    }

    private func notifyParticipants() {
        onParticipantsChanged?(participantCount)
    }

    private func reportError(_ error: Error) {
        syncLogger.error("SyncPlay error: \(error.localizedDescription, privacy: .public)")
        guard let loc, let toast else { return }
        toast.error(loc.localized("syncplay.error"), message: loc.userFacingMessage(for: error))
    }

    // MARK: - Clock offset

    /// Averages a few `GetUtcTime` round-trips (NTP-style) to estimate the
    /// server↔client offset. ~100 ms accuracy is plenty for v1.
    private func sampleClock() async {
        guard let api else { return }
        var samples: [TimeInterval] = []
        for _ in 0..<3 {
            let t0 = Date()
            guard let utc = try? await api.syncPlayGetUtcTime() else { continue }
            let t3 = Date()
            // offset = ((serverRecv - t0) + (serverTrans - t3)) / 2
            let offset = (utc.requestReceptionTime.timeIntervalSince(t0)
                          + utc.responseTransmissionTime.timeIntervalSince(t3)) / 2
            samples.append(offset)
        }
        guard !samples.isEmpty else { return }
        clockOffset = samples.reduce(0, +) / Double(samples.count)
        syncLogger.debug("SyncPlay clock offset ≈ \(String(format: "%.0f", self.clockOffset * 1000)) ms")
    }

    // MARK: - Inbound handling

    private func handle(_ message: SyncPlaySocketMessage) {
        switch message {
        case .command(let command): schedule(command)
        case .groupUpdate(let update): apply(update)
        }
    }

    private func schedule(_ command: SyncPlayCommand) {
        scheduledCommandTask?.cancel()
        let offset = clockOffset
        scheduledCommandTask = Task { @MainActor [weak self] in
            if let when = command.when {
                let target = when.addingTimeInterval(-offset)
                let delay = target.timeIntervalSinceNow
                if delay > 0 {
                    // Cap the wait so a bogus far-future timestamp can't wedge us.
                    try? await Task.sleep(nanoseconds: UInt64(min(delay, 30) * 1_000_000_000))
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.applyCommand(command)
        }
    }

    private func applyCommand(_ command: SyncPlayCommand) {
        guard let bridge else { return }
        isApplyingRemoteCommand = true
        defer { isApplyingRemoteCommand = false }

        switch command.command {
        case .unpause:
            if let ticks = command.positionTicks { bridge.seekMs(ticks / Self.ticksPerMillisecond) }
            bridge.play()
        case .pause:
            bridge.pause()
            if let ticks = command.positionTicks { bridge.seekMs(ticks / Self.ticksPerMillisecond) }
        case .seek:
            if let ticks = command.positionTicks { bridge.seekMs(ticks / Self.ticksPerMillisecond) }
        case .stop:
            bridge.stop()
        }
    }

    private func apply(_ update: SyncPlayGroupUpdate) {
        switch update.type {
        case .groupJoined:
            if let g = update.group {
                group = g
                participants = g.participants
            }
            notifyParticipants()
        case .userJoined:
            if let name = update.userName, !participants.contains(name) {
                participants.append(name)
                notifyParticipants()
            }
        case .userLeft:
            if let name = update.userName {
                participants.removeAll { $0 == name }
                notifyParticipants()
            }
        case .groupLeft, .notInGroup, .groupDoesNotExist:
            handleServerRemoval()
        case .stateUpdate, .playQueue, .none:
            break
        }
    }

    /// The server removed us (group disbanded, kicked, or we left elsewhere).
    private func handleServerRemoval() {
        let wasIn = isInGroup
        teardownSession()
        if wasIn, let loc, let toast {
            toast.info(loc.localized("syncplay.groupEnded"))
        }
    }
}
