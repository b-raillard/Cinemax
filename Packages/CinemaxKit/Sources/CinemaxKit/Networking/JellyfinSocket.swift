import Foundation
import OSLog

private let socketLogger = Logger(subsystem: "com.cinemax", category: "JellyfinSocket")

// MARK: - Unified message

/// Everything this app consumes from Jellyfin's realtime `/socket`, in one
/// vocabulary.
///
/// It used to be two — `SyncPlaySocketMessage` and `RemoteSessionMessage`, each
/// with its own actor parsing its own subset of the same frames. They were not
/// variants of one idea; they were the *same* idea written twice, which is
/// exactly what made running both at once a defect rather than a feature.
public enum JellyfinSocketMessage: Sendable, Equatable {
    /// SyncPlay transport echo — the thing that actually moves every
    /// participant's playhead.
    case syncPlayCommand(SyncPlayCommand)
    /// SyncPlay group membership / queue change.
    case syncPlayGroupUpdate(SyncPlayGroupUpdate)
    /// Inbound "play this now" from another client's « Lire sur… » picker.
    case play(RemotePlayRequest)
    /// Inbound `DisplayMessage` general command.
    case displayMessage(RemoteDisplayMessage)
}

// MARK: - Socket

/// A `URLSessionWebSocketTask` client for Jellyfin's realtime `/socket`.
///
/// **RULE — one socket per session, and this type is how that rule is kept.**
/// Jellyfin keys a session on device + client + user, so two concurrent
/// `/socket` connections from this app are the *same* session server-side and
/// every message is delivered twice. Remote control and Watch Together used to
/// own a socket each and could only coexist because Watch Together was behind a
/// compile-time kill-switch. Nothing opens a socket directly any more: both go
/// through `JellyfinSocketHub`, which owns exactly one of these and fans its
/// messages out.
///
/// Lifecycle:
///   1. `start()` opens the socket and begins a receive loop.
///   2. The server sends `ForceKeepAlive` with a timeout; we reply `KeepAlive`
///      every `timeout / 2` seconds to keep the connection alive.
///   3. On a drop we reconnect with bounded exponential backoff (up to ~30 s).
///   4. `stop()` tears everything down and finishes the stream.
public actor JellyfinSocket {
    private let url: URL
    private let session: URLSession
    private let stream: AsyncStream<JellyfinSocketMessage>
    private let continuation: AsyncStream<JellyfinSocketMessage>.Continuation

    private var task: URLSessionWebSocketTask?
    private var connectTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var isStopped = false
    private var reconnectAttempts = 0

    public init(url: URL) {
        self.url = url
        self.session = URLSession(configuration: .default)
        let (s, c) = AsyncStream<JellyfinSocketMessage>.makeStream()
        self.stream = s
        self.continuation = c
    }

    /// The message stream. `AsyncStream` of a `Sendable` element is itself
    /// `Sendable`, and `stream` is an immutable `let`, so this is safe to read
    /// without hopping onto the actor.
    public nonisolated var messages: AsyncStream<JellyfinSocketMessage> { stream }

    public func start() {
        guard connectTask == nil, !isStopped else { return }
        connectTask = Task { await self.connectLoop() }
    }

    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        keepAliveTask?.cancel(); keepAliveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectTask?.cancel(); connectTask = nil
        session.invalidateAndCancel()
        continuation.finish()
    }

    // MARK: - Connection loop

    private func connectLoop() async {
        while !isStopped {
            let ws = session.webSocketTask(with: url)
            task = ws
            ws.resume()
            do {
                while !isStopped {
                    let frame = try await ws.receive()
                    // A successful frame means the connection is healthy again —
                    // reset the backoff so a long-lived session that drops once
                    // reconnects fast rather than inheriting an old penalty.
                    reconnectAttempts = 0
                    handleFrame(frame)
                }
            } catch {
                if !isStopped {
                    socketLogger.debug("Socket dropped: \(error.localizedDescription, privacy: .public)")
                }
            }
            keepAliveTask?.cancel(); keepAliveTask = nil
            task = nil
            if isStopped { break }
            reconnectAttempts += 1
            let delay = min(30.0, pow(2.0, Double(min(reconnectAttempts, 5))))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        continuation.finish()
    }

    // MARK: - Frame handling

    private func handleFrame(_ frame: URLSessionWebSocketTask.Message) {
        let data: Data
        switch frame {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["MessageType"] as? String else { return }

        switch type {
        case "ForceKeepAlive":
            let seconds = (obj["Data"] as? NSNumber)?.doubleValue ?? 60
            startKeepAlive(interval: max(1, seconds / 2))
        case "KeepAlive":
            break // server echo — nothing to do
        case "SyncPlayCommand":
            if let d = obj["Data"] as? [String: Any], let cmd = Self.parseCommand(d) {
                continuation.yield(.syncPlayCommand(cmd))
            }
        case "SyncPlayGroupUpdate":
            if let d = obj["Data"] as? [String: Any] {
                continuation.yield(.syncPlayGroupUpdate(Self.parseGroupUpdate(d)))
            }
        case "Play":
            if let d = obj["Data"] as? [String: Any], let request = Self.parsePlay(d) {
                continuation.yield(.play(request))
            }
        case "GeneralCommand":
            if let d = obj["Data"] as? [String: Any], let message = Self.parseDisplayMessage(d) {
                continuation.yield(.displayMessage(message))
            }
        default:
            // `Playstate`, `UserDataChanged`, `LibraryChanged`, `Sessions`, … —
            // deliberately unhandled. Adding a case here is how a new consumer
            // joins, not by opening a second socket.
            break
        }
    }

    // MARK: - Parsing (pure + static, so it is unit testable without a live socket)

    static func parseCommand(_ d: [String: Any]) -> SyncPlayCommand? {
        guard let raw = d["Command"] as? String,
              let kind = SyncPlayCommand.Kind(rawValue: raw) else { return nil }
        return SyncPlayCommand(
            command: kind,
            positionTicks: (d["PositionTicks"] as? NSNumber)?.intValue,
            when: (d["When"] as? String).flatMap(SyncPlayDateParser.date(from:)),
            emittedAt: (d["EmittedAt"] as? String).flatMap(SyncPlayDateParser.date(from:)),
            playlistItemId: d["PlaylistItemId"] as? String
        )
    }

    static func parseGroupUpdate(_ d: [String: Any]) -> SyncPlayGroupUpdate {
        let rawType = d["Type"] as? String ?? ""
        let groupId = d["GroupId"] as? String
        var group: SyncPlayGroup?
        var userName: String?
        var state: String?
        var playlist: [String] = []
        var playlistItemIds: [String] = []
        var playingItemIndex: Int?
        var startPositionTicks: Int?
        var isPlaying: Bool?

        let inner = d["Data"]
        if let dict = inner as? [String: Any] {
            state = dict["State"] as? String
            // GroupJoined / GroupLeft carry a GroupInfoDto; decode it if the
            // shape matches (has a group id / name).
            if dict["GroupId"] != nil || dict["GroupName"] != nil,
               let blob = try? JSONSerialization.data(withJSONObject: dict) {
                group = try? JSONDecoder().decode(SyncPlayGroup.self, from: blob)
            }
            // PlayQueue — the update that says WHAT the group is watching.
            // The payload is `PlayQueueUpdate`: the queue lives under
            // `Playlist` as `SyncPlayQueueItem { ItemId, PlaylistItemId }`,
            // never a bare `ItemIds` array.
            if let items = dict["Playlist"] as? [[String: Any]] {
                // Kept positionally aligned — `PlayingItemIndex` addresses both
                // lists, so an entry dropped from one must drop from the other.
                let entries = items.compactMap { entry -> (String, String)? in
                    guard let itemId = entry["ItemId"] as? String, !itemId.isEmpty else { return nil }
                    return (itemId, entry["PlaylistItemId"] as? String ?? "")
                }
                playlist = entries.map(\.0)
                playlistItemIds = entries.map(\.1)
            }
            playingItemIndex = (dict["PlayingItemIndex"] as? NSNumber)?.intValue
            startPositionTicks = (dict["StartPositionTicks"] as? NSNumber)?.intValue
            isPlaying = (dict["IsPlaying"] as? NSNumber)?.boolValue
        } else if let s = inner as? String {
            userName = s // UserJoined / UserLeft → bare username
        }

        return SyncPlayGroupUpdate(
            type: SyncPlayGroupUpdate.Kind(rawValue: rawType),
            rawType: rawType,
            groupId: groupId,
            group: group,
            userName: userName,
            state: state,
            playlist: playlist,
            playlistItemIds: playlistItemIds,
            playingItemIndex: playingItemIndex,
            startPositionTicks: startPositionTicks,
            isPlaying: isPlaying
        )
    }

    static func parsePlay(_ d: [String: Any]) -> RemotePlayRequest? {
        guard let ids = d["ItemIds"] as? [String], !ids.isEmpty else { return nil }
        return RemotePlayRequest(
            itemIds: ids,
            playCommand: d["PlayCommand"] as? String ?? "",
            startPositionTicks: (d["StartPositionTicks"] as? NSNumber)?.intValue,
            mediaSourceId: d["MediaSourceId"] as? String
        )
    }

    static func parseDisplayMessage(_ d: [String: Any]) -> RemoteDisplayMessage? {
        guard let name = d["Name"] as? String,
              name.caseInsensitiveCompare("DisplayMessage") == .orderedSame else { return nil }
        // `Arguments` is a string→string map in Jellyfin's `GeneralCommand`.
        guard let arguments = d["Arguments"] as? [String: Any] else { return nil }
        guard let text = (arguments["Text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let header = (arguments["Header"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteDisplayMessage(header: (header?.isEmpty == false) ? header : nil, text: text)
    }

    // MARK: - Keep-alive

    private func startKeepAlive(interval: TimeInterval) {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.sendKeepAlive()
            }
        }
    }

    private func sendKeepAlive() async {
        guard let task, !isStopped else { return }
        try? await task.send(.string(#"{"MessageType":"KeepAlive","Data":""}"#))
    }
}

// MARK: - Hub

/// Owns the app's **single** realtime socket and fans its messages out to every
/// consumer that asks for them.
///
/// This exists because of the one-socket rule above. Remote control (always on
/// by default) and Watch Together (on only during a session) both need the same
/// `/socket`, they come and go independently, and neither may assume it is
/// alone. The hub reference-counts: the socket opens on the first subscriber
/// and closes when the last one leaves, so a device with Watch Together idle
/// costs exactly what it costs today.
///
/// A subscriber that asks for a **different** URL than the live one — a server
/// switch, a re-login that mints a new token — rebuilds the socket for
/// everybody, which is correct: the old URL points at a session that no longer
/// exists.
public actor JellyfinSocketHub {
    public static let shared = JellyfinSocketHub()

    /// A consumer's handle. Hold the `id` to unsubscribe; iterate `messages`.
    public struct Subscription: Sendable {
        public let id: UUID
        public let messages: AsyncStream<JellyfinSocketMessage>
    }

    private var socket: JellyfinSocket?
    private var activeURL: URL?
    private var pump: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<JellyfinSocketMessage>.Continuation] = [:]

    init() {}

    /// Number of live consumers. Test seam — and the thing the one-socket rule
    /// is actually about.
    public var subscriberCount: Int { subscribers.count }

    public func subscribe(url: URL) -> Subscription {
        let id = UUID()
        let (stream, continuation) = AsyncStream<JellyfinSocketMessage>.makeStream()
        subscribers[id] = continuation
        ensureSocket(url: url)
        return Subscription(id: id, messages: stream)
    }

    public func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
        if subscribers.isEmpty { teardown() }
    }

    // MARK: - Private

    private func ensureSocket(url: URL) {
        if let activeURL, activeURL == url, socket != nil { return }
        // Close-before-open, and the ordering is load-bearing: a detached
        // `stop()` leaves the outgoing `URLSessionWebSocketTask` resumed and
        // connected until it wins its hop, so for that window the app holds TWO
        // `/socket` connections against the same server-side session — the exact
        // condition this hub exists to make impossible. The pump awaits the
        // closer before starting.
        //
        // `teardown` stays synchronous on purpose: making it `async` would open
        // a suspension point inside `ensureSocket`, letting two concurrent
        // `subscribe` calls both pass the `activeURL` check and both build a
        // socket — trading one race for a worse one.
        let closing = teardown()
        let socket = JellyfinSocket(url: url)
        self.socket = socket
        self.activeURL = url
        pump = Task { [weak self] in
            await closing.value
            await socket.start()
            for await message in socket.messages {
                await self?.broadcast(message)
            }
        }
    }

    private func broadcast(_ message: JellyfinSocketMessage) {
        for continuation in subscribers.values {
            continuation.yield(message)
        }
    }

    /// Drops the socket but NOT the subscribers — a URL change rebuilds under
    /// them and they keep receiving, which is what makes a server switch
    /// invisible to a consumer that is still interested.
    @discardableResult
    private func teardown() -> Task<Void, Never> {
        pump?.cancel()
        pump = nil
        let outgoing = socket
        socket = nil
        activeURL = nil
        return Task { await outgoing?.stop() }
    }
}
