import Foundation
import OSLog

private let socketLogger = Logger(subsystem: "com.cinemax", category: "SessionSocket")

/// A `URLSessionWebSocketTask` client for Jellyfin's realtime `/socket`
/// endpoint, scoped to **inbound remote-control messages** — the transport that
/// makes this device appear in, and respond to, another client's "Play on…"
/// picker. Declaring capabilities (`publishCapabilities`) is what puts the
/// device in the list; this socket is what makes tapping it do something,
/// because Jellyfin delivers session commands over the socket and nowhere else.
///
/// Structure mirrors `SyncPlaySocket` deliberately (actor-isolated connection
/// state, `Sendable` value types out through an `AsyncStream`, `ForceKeepAlive`
/// handling, bounded exponential backoff) — the two are siblings, not variants.
///
/// **RULE — one socket per session.** Jellyfin keys a session on
/// device + client + user, so two concurrent `/socket` connections from this app
/// are the *same* session server-side and every message is delivered twice.
/// Today that can't happen: Watch Together is behind a compile-time kill-switch
/// (`MediaDetailScreen.watchTogetherEnabled`) and never opens `SyncPlaySocket`.
/// Re-enabling it means merging the two into one socket that fans out to both
/// consumers — not running both.
public actor SessionSocket {
    private let url: URL
    private let session: URLSession
    private let stream: AsyncStream<RemoteSessionMessage>
    private let continuation: AsyncStream<RemoteSessionMessage>.Continuation

    private var task: URLSessionWebSocketTask?
    private var connectTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var isStopped = false
    private var reconnectAttempts = 0

    public init(url: URL) {
        self.url = url
        self.session = URLSession(configuration: .default)
        let (s, c) = AsyncStream<RemoteSessionMessage>.makeStream()
        self.stream = s
        self.continuation = c
    }

    /// The message stream. `AsyncStream` of a `Sendable` element is itself
    /// `Sendable`, and `stream` is an immutable `let`, so this is safe to read
    /// without hopping onto the actor.
    public nonisolated var messages: AsyncStream<RemoteSessionMessage> { stream }

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
                    socketLogger.debug("Session socket dropped: \(error.localizedDescription, privacy: .public)")
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
            // all deliberately unhandled here. See the type doc: this socket
            // exists for the remote-control receive path only.
            break
        }
    }

    /// Internal rather than private, and `static`, so the frame parsing is unit
    /// testable without a live socket — same treatment as
    /// `CinemaxStreamProxy.admission`. Pure: no actor state is touched.
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
