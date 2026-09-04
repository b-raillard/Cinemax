import Foundation
import CinemaxKit
import OSLog

private let syncLogger = Logger(subsystem: "com.cinemax", category: "SyncPlay")

/// Drives a SyncPlay ("Regarder ensemble") session: owns the current group, the
/// subscription to the shared realtime socket, the client↔server clock offset,
/// and the bridge to whatever player surface is on screen.
///
/// When `isInGroup`, the presenter routes the user's play / pause / seek through
/// this controller (which hits the REST endpoint) instead of applying them
/// locally; the server echoes the command back over the socket and *that* echo
/// is what moves the playhead, so every participant stays in lockstep.
///
/// **What the protocol does and does not give us**, because two pieces of UI
/// depend on knowing the difference:
/// - Who is in the group: yes (`participants`, usernames).
/// - What the group is watching: yes, but only over the socket
///   (`PlayQueue`) — `GET /SyncPlay/List` returns `GroupInfoDto`, which carries
///   no item at all. A group's title is therefore unknowable until you join.
/// - Per-participant transport state: **no**. `GroupStateUpdate` is
///   `{ State, Reason }`: it says the group is waiting, never who for. Any
///   "waiting for Paul" would be inventing that name, so the UI says "waiting
///   for a participant".
@MainActor
@Observable
final class SyncPlayController {
    static let shared = SyncPlayController()

    // MARK: Observable state

    private(set) var group: SyncPlayGroup?
    private(set) var participants: [String] = []
    /// Group-level transport state. Drives the "waiting" affordance.
    private(set) var groupState: SyncPlayGroupState = .idle
    /// The item the group is watching, learned from `PlayQueue`.
    private(set) var currentItemId: String?
    /// Where the group stands in that item, in Jellyfin ticks.
    private(set) var currentStartTicks: Int?

    var isInGroup: Bool { group != nil }
    var participantCount: Int { participants.count }
    var groupName: String? { group?.name }
    /// The group is held while a participant finishes buffering. Everyone's
    /// picture is frozen; this is what lets the player say so instead of
    /// looking broken.
    var isWaitingForParticipants: Bool { isInGroup && groupState == .waiting }

    // MARK: Dependencies (set on activation)

    @ObservationIgnored private var api: (any SyncPlayAPI)?
    @ObservationIgnored private var loc: LocalizationManager?
    @ObservationIgnored private var toast: ToastCenter?
    /// The signed-in user's Jellyfin username. Read by the player HUD so the
    /// viewer's own chip says "You" rather than showing them their own name.
    @ObservationIgnored private(set) var currentUserName: String?
    /// An item this client itself just queued. The server echoes `PlayQueue`
    /// back to the sender like every other participant, and announcing our own
    /// echo would ask the app to open what it is already opening.
    @ObservationIgnored private var selfQueuedItemId: String?

    // MARK: Socket + clock

    /// Our handle on the app's single realtime socket. `JellyfinSocketHub` owns
    /// the connection; remote control subscribes to the same one.
    @ObservationIgnored private var subscription: UUID?
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

    /// How long after applying a remote command the engine's own state changes
    /// are treated as that command's echo rather than as the user's doing.
    ///
    /// This used to be a `defer`-reset boolean around the synchronous bridge
    /// calls — which suppressed nothing, because the engine reports buffering
    /// and readiness *asynchronously*, long after the `defer` had already put
    /// the flag back. A window is the honest shape: the echo arrives later, so
    /// the guard has to still be up later.
    private static let remoteEchoWindow: TimeInterval = 1.0
    @ObservationIgnored private var remoteEchoUntil: Date = .distantPast

    /// True while an inbound command's echo is still expected — lets the
    /// presenter suppress the buffering/ready reports the command induces.
    var isApplyingRemoteCommand: Bool { Date() < remoteEchoUntil }

    /// Notified whenever the session's shape changes — participants, group
    /// state, membership — so a UIKit HUD can repaint without observation.
    @ObservationIgnored var onSessionChanged: (@MainActor () -> Void)?

    /// Notified when the group's queue names an item, with its position in
    /// ticks. This is how a participant learns **what to open**; nothing else
    /// tells them.
    @ObservationIgnored var onQueueChanged: (@MainActor (String, Int) -> Void)?

    private init() {}

    private static let ticksPerMillisecond = 10_000

    /// Whether the engine currently selected can actually synchronise.
    ///
    /// Only `VLCStreamPresenter` binds a `PlaybackBridge`; `NativeVideoPresenter`
    /// has no SyncPlay integration at all. With the native player forced, a
    /// group would form server-side and nothing would ever move — a silent
    /// no-op, which is precisely the failure mode this feature had too much of.
    /// Callers refuse with an explanation rather than hiding the button, because
    /// a documented feature that is simply absent teaches the user nothing.
    static var isEngineSupported: Bool {
        !UserDefaults.standard.bool(forKey: SettingsKey.forceNativeAVPlayer)
    }

    // MARK: - Group lifecycle (driven by the UI)

    /// Creates a group and starts a session. The realtime subscription + clock
    /// are spun up first so we're ready for the server's `GroupJoined` echo.
    func createGroup(
        named name: String,
        api: any SyncPlayAPI,
        loc: LocalizationManager,
        toast: ToastCenter,
        currentUserName: String?
    ) async -> Bool {
        prepare(api: api, loc: loc, toast: toast, currentUserName: currentUserName)
        startSession()
        do {
            try await api.syncPlayNewGroup(name: name)
            // Optimistic placeholder until the socket's GroupJoined refines it.
            group = SyncPlayGroup(id: "", name: name, participants: currentUserName.map { [$0] } ?? [])
            participants = group?.participants ?? []
            notifySessionChanged()
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
            notifySessionChanged()
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
        selfQueuedItemId = itemId
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

    /// Binds a player surface. Called **unconditionally** when a player opens,
    /// not only when a group already exists.
    ///
    /// It used to be guarded on `isInGroup` and run once, at open — so a player
    /// that was already running when the user joined a group never received the
    /// bridge at all: the group formed server-side, the transport stayed local,
    /// nothing synchronised, and no error was raised anywhere. Binding always
    /// and letting the group's absence be the no-op removes the whole class of
    /// ordering bug, and is what makes joining from an open player possible.
    func bindPlayback(_ bridge: PlaybackBridge) {
        self.bridge = bridge
        notifySessionChanged()
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
        guard let api, let url = api.makeRealtimeSocketURL() else {
            syncLogger.error("SyncPlay: no realtime socket URL (not connected?)")
            return
        }
        socketTask?.cancel()
        let previous = subscription
        subscription = nil
        if let previous { Task { await JellyfinSocketHub.shared.unsubscribe(previous) } }

        socketTask = Task { @MainActor [weak self] in
            let handle = await JellyfinSocketHub.shared.subscribe(url: url)
            guard let controller = self else {
                await JellyfinSocketHub.shared.unsubscribe(handle.id)
                return
            }
            controller.subscription = handle.id
            for await message in handle.messages {
                guard let self else { return }
                self.handle(message)
            }
        }
    }

    private func teardownSession() {
        group = nil
        participants = []
        groupState = .idle
        currentItemId = nil
        currentStartTicks = nil
        selfQueuedItemId = nil
        scheduledCommandTask?.cancel(); scheduledCommandTask = nil
        socketTask?.cancel(); socketTask = nil
        if let subscription {
            // Drops only OUR subscription; the hub keeps the socket up for
            // remote control, which is on by default.
            Task { await JellyfinSocketHub.shared.unsubscribe(subscription) }
        }
        subscription = nil
        clockOffset = 0
        remoteEchoUntil = .distantPast
        notifySessionChanged()
    }

    private func notifySessionChanged() {
        onSessionChanged?()
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

    /// The hub delivers every frame to every consumer, so remote-control
    /// traffic arrives here too and is ignored — `RemoteControlListener` owns
    /// that half.
    private func handle(_ message: JellyfinSocketMessage) {
        switch message {
        case .syncPlayCommand(let command): schedule(command)
        case .syncPlayGroupUpdate(let update): apply(update)
        case .play, .displayMessage: break
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
        // Raise the echo window BEFORE touching the engine: its state-change
        // events arrive asynchronously, after this function has returned.
        remoteEchoUntil = Date().addingTimeInterval(Self.remoteEchoWindow)

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
                applyState(g.state)
            }
            notifySessionChanged()
        case .userJoined:
            if let name = update.userName, !participants.contains(name) {
                participants.append(name)
                notifySessionChanged()
            }
        case .userLeft:
            if let name = update.userName {
                participants.removeAll { $0 == name }
                notifySessionChanged()
            }
        case .stateUpdate:
            applyState(update.state)
            notifySessionChanged()
        case .playQueue:
            applyQueue(update)
        case .groupLeft, .notInGroup, .groupDoesNotExist:
            handleServerRemoval(message: "syncplay.groupEnded")
        case .libraryAccessDenied:
            // The group is watching something this account cannot see. Saying
            // so is the whole value: the alternative is a session that joins
            // and then shows nothing, with no reason given.
            handleServerRemoval(message: "syncplay.libraryAccessDenied")
        case .none:
            break
        }
    }

    private func applyState(_ raw: String?) {
        guard let raw, let parsed = SyncPlayGroupState(rawValue: raw) else { return }
        groupState = parsed
    }

    /// The `PlayQueue` update — the only thing that says what the group is
    /// watching. Dropping it is what left a joiner synchronised to nothing.
    private func applyQueue(_ update: SyncPlayGroupUpdate) {
        guard let itemId = update.playingItemId else { return }
        let ticks = max(0, update.startPositionTicks ?? 0)
        let changed = itemId != currentItemId
        currentItemId = itemId
        currentStartTicks = ticks
        if let isPlaying = update.isPlaying {
            groupState = isPlaying ? .playing : .paused
        }
        notifySessionChanged()

        // Announce only a genuine change of item: the server re-sends the queue
        // on several unrelated events, and re-opening the media the user is
        // already watching would restart it under them.
        guard changed else { return }
        // …and never our own echo, which would double-open what the creator is
        // already opening.
        if selfQueuedItemId == itemId {
            selfQueuedItemId = nil
            return
        }
        // A bound bridge means a player is already on screen. Switching the
        // media under it is deliberately out of v1 scope — the group's transport
        // still applies, and the mismatch is logged rather than acted on, since
        // silently restarting someone's player is worse than a divergence they
        // can see and fix by rejoining.
        guard bridge == nil else {
            syncLogger.notice("SyncPlay: group moved to a different item while a player was open — not switching in v1")
            return
        }
        onQueueChanged?(itemId, ticks)
    }

    /// The server removed us (group disbanded, kicked, we left elsewhere, or
    /// the library is out of reach).
    private func handleServerRemoval(message key: String) {
        let wasIn = isInGroup
        teardownSession()
        if wasIn, let loc, let toast {
            toast.info(loc.localized(key))
        }
    }
}
