import Foundation
import Network
import Security
import OSLog

private let proxyLog = Logger(subsystem: "com.cinemax", category: "StreamProxy")

/// One-shot resume guard usable from concurrent `@Sendable` callbacks.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns true exactly once (to the first caller).
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

// MARK: - Transport policy (app-session decision)

/// Decides, per server + per network, whether libVLC's direct network path is
/// viable or whether stream bytes must be routed through the in-app loopback
/// proxy (which fetches via `URLSession` → Apple Happy-Eyeballs → working IP).
///
/// The problem it solves: a dual-stack server whose **IPv6 is black-holed**.
/// libVLC has no Happy-Eyeballs, tries the AAAA first, and stalls ~75 s on the
/// dead route before falling back to IPv4. `URLSession` instantly uses IPv4.
///
/// The verdict is computed once in the background (launch / network change) so
/// playback never pays a detection cost; the answer is cached for the session.
@MainActor
final class StreamTransportPolicy {
    static let shared = StreamTransportPolicy()
    private init() {}

    /// `true` ⇒ start playback through the loopback proxy immediately.
    private(set) var preferProxy = false

    private var serverURL: URL?
    private var probeTask: Task<Void, Never>?
    private let proxy = CinemaxStreamProxy()

    /// Point the policy at the active server (call on launch + server switch).
    func configure(serverURL: URL?) {
        let changed = self.serverURL != serverURL
        self.serverURL = serverURL
        if serverURL == nil {
            preferProxy = false
            proxy.stop()
            return
        }
        if changed { proxy.prestart() } // listener warm before first play
        refresh()
    }

    /// Re-run the probe (call on foreground / connectivity change).
    func refresh() {
        guard let url = serverURL, let host = url.host else { preferProxy = false; return }
        let useTLS = (url.scheme?.lowercased() != "http")
        let port = UInt16(url.port ?? (useTLS ? 443 : 80))
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            let prefer = await Self.shouldPreferProxy(host: host, port: port, useTLS: useTLS)
            guard !Task.isCancelled else { return }
            self?.preferProxy = prefer
            proxyLog.log("StreamTransport ▸ host=\(host, privacy: .public) preferProxy=\(prefer)")
        }
    }

    /// Loopback URL VLC should open for `target`, or nil if the proxy can't be
    /// brought up (caller then uses the direct URL). `target` must already carry
    /// auth (api_key query param); `token` is also sent as a header for servers
    /// that prefer it.
    func proxiedURL(for target: URL, token: String?) -> URL? {
        proxy.localURL(for: target, token: token)
    }

    // MARK: Probe

    /// Prefer the proxy only for the genuine black-hole case: the host is
    /// dual-stack (has a AAAA) AND a TLS session to that IPv6 neither completes
    /// nor fails within the budget — i.e. it hangs, exactly as it will for
    /// libVLC. A `.ready` (works) or a fast `.failed` (no route, e.g. an
    /// IPv4-only network where libVLC also fails fast) means the direct path is
    /// fine, so we leave it alone.
    nonisolated private static func shouldPreferProxy(host: String, port: UInt16, useTLS: Bool) async -> Bool {
        guard let v6 = firstIPv6(host: host) else { return false } // not dual-stack
        let resolvedQuickly = await ipv6ResolvesQuickly(address: v6, serverName: host, port: port, useTLS: useTLS)
        return !resolvedQuickly
    }

    nonisolated private static func firstIPv6(host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET6
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &res) == 0, let head = res else { return nil }
        defer { freeaddrinfo(head) }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var cur: UnsafeMutablePointer<addrinfo>? = head
        while let node = cur {
            if node.pointee.ai_family == AF_INET6,
               getnameinfo(node.pointee.ai_addr, node.pointee.ai_addrlen,
                           &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            }
            cur = node.pointee.ai_next
        }
        return nil
    }

    /// `true` if a TLS connection to the IPv6 literal reaches `.ready` OR fails
    /// fast within `timeout`; `false` if it just hangs (black-hole). SNI is set
    /// to the real host so a healthy server validates cleanly and reaches ready.
    nonisolated private static func ipv6ResolvesQuickly(
        address: String, serverName: String, port: UInt16, useTLS: Bool, timeout: TimeInterval = 4
    ) async -> Bool {
        guard let v6 = IPv6Address(address),
              let nwPort = NWEndpoint.Port(rawValue: port) else { return true } // can't test → assume fine
        let params: NWParameters
        if useTLS {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
            params = NWParameters(tls: tls)
        } else {
            params = NWParameters.tcp
        }
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v6
        }
        let conn = NWConnection(host: .ipv6(v6), port: nwPort, using: params)
        let queue = DispatchQueue(label: "com.cinemax.ipv6probe")
        let once = ResumeOnce()

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            @Sendable func finish(_ value: Bool) {
                guard once.claim() else { return }
                conn.cancel()
                cont.resume(returning: value)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)        // IPv6 works
                case .failed, .cancelled: finish(true) // fast fail → libVLC falls back fast too
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) } // hung → black-hole
            conn.start(queue: queue)
        }
    }
}

// MARK: - Loopback HTTP → URLSession proxy

/// Tiny on-device HTTP/1.1 proxy bound to `127.0.0.1`. libVLC connects to it in
/// plaintext over IPv4 loopback; the proxy re-fetches each request from the
/// real HTTPS origin with `URLSession` (Happy-Eyeballs picks the working IPv4),
/// streaming bytes back with `Range` preserved so scrubbing/seeking still work.
///
/// One request per connection (we answer `Connection: close`): read one request
/// head, stream one upstream response, close. VLC reopens a connection per
/// Range — negligible on loopback.
final class CinemaxStreamProxy: @unchecked Sendable {
    private let netQueue = DispatchQueue(label: "com.cinemax.streamproxy", qos: .userInitiated)
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var listenerPort: UInt16?
    private var listenerStarting = false
    private var pathCounter: UInt64 = 0
    // Each loopback URL carries a unique id resolving to its own target, so an
    // in-flight request for a previous media (retry / episode swap) can never
    // read the new target. Bounded — old media is gone within a couple swaps.
    private var targets: [UInt64: (url: URL, token: String?)] = [:]
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = .infinity // long media streams
        cfg.waitsForConnectivity = false
        // CRITICAL: a CONCURRENT delegate queue. The default serial queue would
        // head-of-line block — our per-task `didReceive` blocks (backpressure)
        // until the loopback send lands, and MKV demuxing fires several
        // simultaneous Range/seek requests (read the SeekHead/Cues near EOF
        // while the bytes=0- stream is still open). On a serial queue the seek
        // request's callbacks can't run while the main stream is mid-send, so
        // VLC times the seek out and reports "cannot seek / damaged file".
        // URLSession still serializes callbacks *per task*, so this is safe.
        let dq = OperationQueue()
        dq.maxConcurrentOperationCount = 8
        dq.name = "com.cinemax.streamproxy.delegate"
        session = URLSession(configuration: cfg, delegate: nil, delegateQueue: dq)
    }

    /// Warm the loopback listener so it's ready before the first play.
    /// Fully async — never blocks the caller. Idempotent.
    func prestart() {
        startListenerIfNeeded()
    }

    /// Registers `target` and returns the loopback URL VLC should open, or nil
    /// if the listener isn't up yet (caller uses the direct URL; the listener is
    /// warmed for next time). Never blocks — safe on the MainActor hot path.
    func localURL(for target: URL, token: String?) -> URL? {
        let port: UInt16? = stateLock.withLock { listenerPort }
        guard let port else {
            startListenerIfNeeded()
            return nil
        }
        let id: UInt64 = stateLock.withLock {
            pathCounter &+= 1
            targets[pathCounter] = (target, token)
            if targets.count > 6, let oldest = targets.keys.min() { targets[oldest] = nil }
            return pathCounter
        }
        return URL(string: "http://127.0.0.1:\(port)/s/\(id)")
    }

    func stop() {
        stateLock.withLock {
            listener?.cancel()
            listener = nil
            listenerPort = nil
            listenerStarting = false
            targets.removeAll()
        }
    }

    // MARK: Listener

    /// Brings the loopback listener up asynchronously (state cached on `.ready`
    /// via the update handler — no semaphore, no blocking, no self-deadlock on
    /// `netQueue`). Idempotent and concurrency-safe.
    private func startListenerIfNeeded() {
        let proceed: Bool = stateLock.withLock {
            if listenerPort != nil || listenerStarting { return false }
            listenerStarting = true
            return true
        }
        guard proceed else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else {
            proxyLog.error("StreamProxy ▸ listener init failed")
            stateLock.withLock { listenerStarting = false }
            return
        }
        stateLock.withLock { listener = l } // hold a strong ref during bring-up
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = l?.port?.rawValue
                self.stateLock.withLock { self.listenerPort = port; self.listenerStarting = false }
                if let port { proxyLog.log("StreamProxy ▸ listening on 127.0.0.1:\(port)") }
            case .failed, .cancelled:
                self.stateLock.withLock {
                    self.listenerStarting = false
                    if self.listener === l { self.listener = nil; self.listenerPort = nil }
                }
                proxyLog.error("StreamProxy ▸ listener down (\(String(describing: state), privacy: .public))")
            default:
                break
            }
        }
        l.start(queue: netQueue)
    }

    // MARK: Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: netQueue)
        readRequestHead(conn, accumulated: Data())
    }

    /// Reads until the end of the HTTP request head, then forwards upstream.
    private func readRequestHead(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = accumulated
            if let data { buf.append(data) }
            if let term = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[buf.startIndex..<term.lowerBound], as: UTF8.self)
                self.forward(conn, head: head)
                return
            }
            if error != nil || isComplete || buf.count > 64 * 1024 { conn.cancel(); return }
            self.readRequestHead(conn, accumulated: buf)
        }
    }

    private func forward(_ conn: NWConnection, head: String) {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        let requestLine = lines.first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init)?.uppercased() ?? "GET"
        let path = parts.count > 1 ? String(parts[1]) : "/"
        var range: String?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            range = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
        }
        // Resolve THIS connection's target by the id baked into the path
        // (/s/<id>) — never a shared "current target", so a retry/episode swap
        // can't make an in-flight request read the wrong stream.
        let id = UInt64(path.split(separator: "/").last ?? "")
        let entry = stateLock.withLock { id.flatMap { targets[$0] } }
        guard let entry else {
            conn.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8),
                      isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        var req = URLRequest(url: entry.url)
        req.httpMethod = method
        if let range { req.setValue(range, forHTTPHeaderField: "Range") }
        if let t = entry.token { req.setValue("MediaBrowser Token=\(t)", forHTTPHeaderField: "Authorization") }
        let label = "\(method) \(range ?? "full")"
        let handler = UpstreamHandler(conn: conn, isHead: method == "HEAD", label: label)
        let task = session.dataTask(with: req)
        handler.task = task
        task.delegate = handler
        task.resume()
    }
}

/// Per-request bridge: streams a `URLSession` response into the VLC-facing
/// `NWConnection`, applying backpressure by blocking this task's delegate
/// callback until each loopback send completes. Runs on the proxy session's
/// CONCURRENT delegate queue, so blocking one request never stalls another
/// (essential for MKV's simultaneous seek requests).
private final class UpstreamHandler: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let conn: NWConnection
    private let isHead: Bool
    private let label: String
    weak var task: URLSessionTask?
    private var headerSent = false

    init(conn: NWConnection, isHead: Bool, label: String) {
        self.conn = conn
        self.isHead = isHead
        self.label = label
        super.init()
        // If VLC drops the connection, stop pulling bytes from the origin.
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.task?.cancel()
            default: break
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        sendHead(response as? HTTPURLResponse)
        if isHead {
            completionHandler(.cancel)
            finish()
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isHead else { return }
        let sem = DispatchSemaphore(value: 0)
        conn.send(content: data, completion: .contentProcessed { _ in sem.signal() })
        // Bounded: if a loopback send's completion never fires (peer wedged),
        // don't pin this thread forever — abort the request instead.
        if sem.wait(timeout: .now() + 20) == .timedOut {
            proxyLog.error("StreamProxy ▸ \(self.label, privacy: .public) send stalled — aborting")
            conn.cancel()
            task?.cancel()
            return
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as? URLError)?.code != .cancelled {
            proxyLog.error("StreamProxy ▸ \(self.label, privacy: .public) upstream error: \(error.localizedDescription, privacy: .public)")
        }
        if error != nil, !headerSent {
            conn.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8),
                      isComplete: true, completion: .contentProcessed { [conn] _ in conn.cancel() })
            return
        }
        finish()
    }

    private func sendHead(_ http: HTTPURLResponse?) {
        guard !headerSent else { return }
        headerSent = true
        let status = http?.statusCode ?? 200
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        if let http {
            for key in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"] {
                if let v = http.value(forHTTPHeaderField: key) { head += "\(key): \(v)\r\n" }
            }
        }
        head += "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    private func finish() {
        conn.send(content: nil, isComplete: true, completion: .contentProcessed { [conn] _ in conn.cancel() })
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 416: return "Range Not Satisfiable"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        default: return "Status"
        }
    }
}
