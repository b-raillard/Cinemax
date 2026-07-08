import Foundation
import OSLog

private let socketLogger = Logger(subsystem: "com.cinemax", category: "SyncPlaySocket")

/// A `URLSessionWebSocketTask` client for Jellyfin's realtime `/socket`
/// endpoint, scoped to the SyncPlay use case (transport commands + group
/// membership updates). Built as an `actor` so its mutable connection state is
/// isolated without a manual lock; parsed frames are handed to consumers through
/// a `Sendable` `AsyncStream` of value types.
///
/// Lifecycle:
///   1. `start()` opens the socket and begins a receive loop.
///   2. The server sends `ForceKeepAlive` with a timeout; we reply `KeepAlive`
///      every `timeout / 2` seconds to keep the connection alive.
///   3. On a drop we reconnect with bounded exponential backoff (up to ~30 s).
///   4. `stop()` tears everything down and finishes the stream.
public actor SyncPlaySocket {
    private let url: URL
    private let session: URLSession
    private let stream: AsyncStream<SyncPlaySocketMessage>
    private let continuation: AsyncStream<SyncPlaySocketMessage>.Continuation

    private var task: URLSessionWebSocketTask?
    private var connectTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var isStopped = false
    private var reconnectAttempts = 0

    public init(url: URL) {
        self.url = url
        self.session = URLSession(configuration: .default)
        let (s, c) = AsyncStream<SyncPlaySocketMessage>.makeStream()
        self.stream = s
        self.continuation = c
    }

    /// The message stream. `AsyncStream` of a `Sendable` element is itself
    /// `Sendable`, and `stream` is an immutable `let`, so this is safe to read
    /// without hopping onto the actor.
    public nonisolated var messages: AsyncStream<SyncPlaySocketMessage> { stream }

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
                    socketLogger.debug("SyncPlay socket dropped: \(error.localizedDescription, privacy: .public)")
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
                continuation.yield(.command(cmd))
            }
        case "SyncPlayGroupUpdate":
            if let d = obj["Data"] as? [String: Any] {
                continuation.yield(.groupUpdate(Self.parseGroupUpdate(d)))
            }
        default:
            break
        }
    }

    private static func parseCommand(_ d: [String: Any]) -> SyncPlayCommand? {
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

    private static func parseGroupUpdate(_ d: [String: Any]) -> SyncPlayGroupUpdate {
        let rawType = d["Type"] as? String ?? ""
        let groupId = d["GroupId"] as? String
        var group: SyncPlayGroup?
        var userName: String?
        var state: String?

        let inner = d["Data"]
        if let dict = inner as? [String: Any] {
            state = dict["State"] as? String
            // GroupJoined / GroupLeft carry a GroupInfoDto; decode it if the
            // shape matches (has a group id / name).
            if dict["GroupId"] != nil || dict["GroupName"] != nil,
               let blob = try? JSONSerialization.data(withJSONObject: dict) {
                group = try? JSONDecoder().decode(SyncPlayGroup.self, from: blob)
            }
        } else if let s = inner as? String {
            userName = s // UserJoined / UserLeft → bare username
        }

        return SyncPlayGroupUpdate(
            type: SyncPlayGroupUpdate.Kind(rawValue: rawType),
            rawType: rawType,
            groupId: groupId,
            group: group,
            userName: userName,
            state: state
        )
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
