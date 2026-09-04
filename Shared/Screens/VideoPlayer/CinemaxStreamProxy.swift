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

/// Decides whether libVLC's direct network path is viable or whether streams
/// must go through the loopback proxy — for dual-stack servers whose IPv6 is
/// black-holed (libVLC has no Happy-Eyeballs, so it stalls on the dead AAAA).
/// Computed once in the background and cached per session. See CLAUDE.md.
@MainActor
final class StreamTransportPolicy {
    static let shared = StreamTransportPolicy()
    private init() {}

    /// `true` ⇒ start playback through the loopback proxy immediately.
    private(set) var preferProxy = false

    /// Set once a *direct* playback attempt fails this session (e.g. an IPv4-only
    /// server published behind a dual-stack DNS record that libVLC intermittently
    /// stalls on — our connect-only probe can't see sustained-flow flakiness). The
    /// loopback proxy (URLSession → Happy-Eyeballs → IPv4, robust HTTP/2) is the
    /// reliable path, so once direct has failed we stop re-rolling the dice on it
    /// for the rest of the session. Reset on server switch.
    private(set) var directFailedThisSession = false

    /// Whether a fresh playback should open through the proxy from the first
    /// frame: either the probe flagged a black-hole, or direct already failed.
    var shouldStartOnProxy: Bool { preferProxy || directFailedThisSession }

    private var serverURL: URL?
    private var probeTask: Task<Void, Never>?
    private let proxy = CinemaxStreamProxy()

    /// Point the policy at the active server (call on launch + server switch).
    func configure(serverURL: URL?) {
        let changed = self.serverURL != serverURL
        self.serverURL = serverURL
        if changed { directFailedThisSession = false } // re-evaluate per server
        if serverURL == nil {
            probeTask?.cancel()
            probeTask = nil
            preferProxy = false
            proxy.stop()
            return
        }
        if changed { proxy.prestart() } // listener warm before first play
        refresh()
    }

    /// Called by the player when a *direct* online attempt fails and it falls
    /// back to the proxy — pins subsequent plays this session to the proxy.
    func noteDirectPlaybackFailed() {
        guard !directFailedThisSession else { return }
        directFailedThisSession = true
        proxyLog.log("StreamTransport ▸ direct playback failed — proxy is now sticky for this session")
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
    /// auth (`ApiKey` query param); `token` is also sent as a header for servers
    /// that prefer it.
    func proxiedURL(for target: URL, token: String?) -> URL? {
        proxy.localURL(for: target, token: token)
    }

    // MARK: Probe

    /// Proxy only for the genuine black-hole: dual-stack host AND a TLS session
    /// to its IPv6 that *hangs* (neither `.ready` nor a fast `.failed` within the
    /// budget). A fast fail (IPv4-only network) means libVLC falls back fine too.
    nonisolated private static func shouldPreferProxy(host: String, port: UInt16, useTLS: Bool) async -> Bool {
        // libVLC resolves through `getaddrinfo`. Where that fails, NOTHING it
        // opens directly can work — so start on the proxy rather than rediscover
        // it through a failed open plus a retry (~7s of dead time) on every
        // single playback. Measured on one corporate Wi-Fi: `getaddrinfo`
        // returns EAI_NONAME for the server host while URLSession fetches the
        // very same URL with 200 in the same second, so the proxy (URLSession +
        // a literal 127.0.0.1 peer, no DNS at all) is the only working path.
        guard hostResolvesForLibVLC(host) else { return true }
        guard let v6 = firstIPv6(host: host) else { return false } // not dual-stack
        let resolvedQuickly = await ipv6ResolvesQuickly(address: v6, serverName: host, port: port, useTLS: useTLS)
        return !resolvedQuickly
    }

    /// Whether the BSD resolver — the one libVLC uses — can resolve `host` right
    /// now. Deliberately not `URLSession`/Network.framework: the whole point is
    /// that those two disagree on some networks, and libVLC only gets this one.
    /// Internal so `StreamProxyTests` can pin both outcomes.
    nonisolated static func hostResolvesForLibVLC(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &res) == 0 else { return false }
        freeaddrinfo(res)
        return true
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

// MARK: - Origin directory mapping (pure — unit-tested)

/// The origin side of one proxied stream: everything up to and including the
/// directory that holds it, so any sibling name can be re-attached.
///
/// This is what makes the proxy serve a whole HLS tree from a single
/// registration. `/s/<id>/<rest>?<query>` maps to `<scheme>://<host>/<dir>/<rest>?<query>`,
/// so the master playlist, the variant playlist libVLC resolves from it, and
/// every segment under it all resolve without ever rewriting a manifest body.
///
/// `dir` is taken from the target's OWN path, so a server hosted under a
/// sub-path (`https://host/jellyfin/videos/…`) keeps it — the base-path rule in
/// CLAUDE.md applies here as everywhere.
struct OriginDirectory: Sendable, Equatable {
    let scheme: String
    let host: String
    let port: Int?
    /// Percent-encoded, leading slash, NO trailing slash (e.g. `/videos/<uuid>`).
    let encodedDirectory: String

    /// Splits an absolute origin URL into (directory, last path component).
    /// Returns nil when there is no name to re-attach (empty or trailing-slash
    /// path), which never happens for a Jellyfin stream URL but must not be
    /// guessed at.
    static func split(_ url: URL) -> (origin: OriginDirectory, name: String)? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme, let host = comps.host else { return nil }
        let encodedPath = comps.percentEncodedPath
        guard let slash = encodedPath.lastIndex(of: "/") else { return nil }
        let name = String(encodedPath[encodedPath.index(after: slash)...])
        guard !name.isEmpty else { return nil }
        return (OriginDirectory(scheme: scheme, host: host, port: comps.port,
                                encodedDirectory: String(encodedPath[..<slash])),
                name)
    }

    /// Rebuilds the origin URL for a loopback sub-path and its query, both
    /// taken verbatim off the wire (already percent-encoded).
    ///
    /// `rest` is validated by `CinemaxStreamProxy.route` before reaching here —
    /// in particular it can contain no `..`, so a crafted loopback request can
    /// never climb out of this directory and replay elsewhere on the origin
    /// **with the account's token attached**.
    func url(forRest rest: String, encodedQuery: String?) -> URL? {
        var out = URLComponents()
        out.scheme = scheme
        out.host = host
        out.port = port
        out.percentEncodedPath = encodedDirectory + "/" + rest
        out.percentEncodedQuery = encodedQuery
        return out.url
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
    // Each loopback URL carries a unique UNGUESSABLE id → its own origin, so an
    // in-flight request for a previous media (retry / episode swap) can't read
    // the wrong stream, and a co-resident app port-scanning loopback can't
    // enumerate `/s/<id>` paths to read the active stream. Bounded (see
    // localURL); `targetOrder` preserves insertion order for eviction.
    //
    // The registered value is the origin's **directory**, not one URL: the
    // loopback URL is `/s/<id>/<name>?<query>`, so libVLC resolves a playlist's
    // relative children against it on its own and they arrive here as
    // `/s/<id>/<child>?<their query>`. One registration therefore serves a whole
    // HLS tree — master, variant, and every segment — with no manifest
    // rewriting, and the 6-entry bound stays per-STREAM rather than per-segment.
    private var targets: [String: (origin: OriginDirectory, token: String?)] = [:]
    private var targetOrder: [String] = []
    // Live per-request bridges, cancelled deterministically in stop() so a
    // server switch mid-stream doesn't keep pulling origin bytes.
    private let liveHandlers = NSHashTable<UpstreamHandler>.weakObjects()
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = .infinity // long media streams
        cfg.waitsForConnectivity = false
        // CRITICAL: a CONCURRENT delegate queue. didReceive blocks (backpressure)
        // until each loopback send lands; MKV fires simultaneous seek requests, so
        // a serial queue would head-of-line block them → "cannot seek". URLSession
        // still serializes callbacks per-task, so this is safe. See CLAUDE.md.
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

    /// Registers `target`'s origin directory and returns the loopback URL VLC
    /// should open, or nil if the listener isn't up yet (caller uses the direct
    /// URL; the listener is warmed for next time) or the URL can't be split.
    /// Never blocks — safe on the MainActor hot path.
    ///
    /// The returned URL **keeps the target's last path component and query**
    /// (`/s/<id>/master.m3u8?…`) — that is what makes relative resolution work:
    /// libVLC turns the master's `main.m3u8?…` into `/s/<id>/main.m3u8?…` by
    /// itself. Dropping the name (the old `/s/<id>` form) is precisely why HLS
    /// could not be proxied.
    func localURL(for target: URL, token: String?) -> URL? {
        let port: UInt16? = stateLock.withLock { listenerPort }
        guard let port else {
            startListenerIfNeeded()
            return nil
        }
        guard let (origin, name) = OriginDirectory.split(target) else { return nil }
        let id = UUID().uuidString
        stateLock.withLock {
            targets[id] = (origin, token)
            targetOrder.append(id)
            if targetOrder.count > 6 { targets[targetOrder.removeFirst()] = nil }
        }
        var local = URLComponents()
        local.scheme = "http"
        local.host = "127.0.0.1"
        local.port = Int(port)
        local.percentEncodedPath = "/s/\(id)/\(name)"
        local.percentEncodedQuery = URLComponents(url: target, resolvingAgainstBaseURL: false)?
            .percentEncodedQuery
        return local.url
    }

    func stop() {
        let handlers: [UpstreamHandler] = stateLock.withLock {
            listener?.cancel()
            listener = nil
            listenerPort = nil
            listenerStarting = false
            targets.removeAll()
            targetOrder.removeAll()
            let live = liveHandlers.allObjects
            liveHandlers.removeAllObjects()
            return live
        }
        handlers.forEach { $0.cancel() }
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
        let hostLine = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }
        let hostHeader = hostLine.map { String($0.dropFirst("host:".count)) }
        if case .reject(let status) = Self.admission(method: method, path: path, hostHeader: hostHeader) {
            conn.send(content: Data("HTTP/1.1 \(status)\r\nConnection: close\r\n\r\n".utf8),
                      isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        var range: String?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            range = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
        }
        // Resolve THIS connection's origin by the id baked into the path
        // (/s/<id>/<rest>) — never a shared "current target", so a retry/episode
        // swap can't make an in-flight request read the wrong stream. `rest` is
        // re-attached to the registered directory, which is how one registration
        // serves a whole HLS tree.
        guard let route = Self.route(path: path),
              let entry = stateLock.withLock({ targets[route.id] }),
              let upstream = entry.origin.url(forRest: route.rest, encodedQuery: route.query) else {
            conn.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8),
                      isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        var req = URLRequest(url: upstream)
        req.httpMethod = method
        if let range { req.setValue(range, forHTTPHeaderField: "Range") }
        if let t = entry.token { req.setValue("MediaBrowser Token=\(t)", forHTTPHeaderField: "Authorization") }
        let label = "\(method) \(range ?? "full")"
        let (rangeStart, rangeEnd) = Self.parseRange(range)
        let handler = UpstreamHandler(conn: conn, isHead: method == "HEAD", label: label,
                                      session: session, url: upstream, token: entry.token,
                                      rangeStart: rangeStart, rangeEnd: rangeEnd)
        let task = session.dataTask(with: req)
        handler.task = task
        task.delegate = handler
        stateLock.withLock { liveHandlers.add(handler) }
        // The handler's stateUpdateHandler only sees transitions that happen
        // after install — if VLC already dropped the connection (we run on
        // netQueue, same as the connection's state changes), skip the fetch.
        switch conn.state {
        case .failed, .cancelled:
            task.cancel()
            return
        default:
            break
        }
        task.resume()
    }

    // MARK: Request routing (pure — unit-tested)

    /// Splits a loopback request-target `/s/<id>/<rest>?<query>` into its parts.
    /// Returns nil for anything that isn't that exact shape — the caller answers
    /// 502 rather than guessing.
    ///
    /// `rest` may contain slashes (HLS segments live under `hls1/main/0.mp4`),
    /// but **never** a `..` component: `rest` is re-attached to the registered
    /// origin directory and fetched WITH the account's token, so path traversal
    /// would let a co-resident process read arbitrary origin paths as the user.
    /// Percent-encoded dot-segments are rejected too — the check runs on the
    /// lowercased raw text, so `%2e%2e` can't smuggle one past it.
    static func route(path: String) -> (id: String, rest: String, query: String?)? {
        let query: String?
        let pathOnly: String
        if let mark = path.firstIndex(of: "?") {
            pathOnly = String(path[..<mark])
            query = String(path[path.index(after: mark)...])
        } else {
            pathOnly = path
            query = nil
        }
        let parts = pathOnly.split(separator: "/", omittingEmptySubsequences: false)
        // ["", "s", "<id>", "<rest>"…] — at least one rest component, all non-empty.
        guard parts.count >= 4, parts[0].isEmpty, parts[1] == "s" else { return nil }
        let id = String(parts[2])
        let restParts = parts.dropFirst(3)
        guard !id.isEmpty, restParts.allSatisfy({ !$0.isEmpty }) else { return nil }
        guard restParts.allSatisfy({ isSafeComponent($0) }) else { return nil }
        return (id, restParts.joined(separator: "/"), query)
    }

    /// Whether one path component of `rest` is safe to re-attach to the
    /// registered origin directory.
    ///
    /// Refuses dot-segments AND any component that DECODES to something
    /// containing a separator. The second half is not theoretical: checking only
    /// for a decoded `".."` lets `%2E%2E%2Fsecret` — one component on the wire,
    /// `../secret` once decoded — walk straight through, and origins differ on
    /// whether they treat `%2F` as a separator. Since `rest` is fetched from the
    /// origin **with the account's token attached**, the decision must not
    /// depend on the origin's decoding quirks.
    ///
    /// Components that merely CONTAIN dots (`..foo.mp4`, `main..m3u8`) are
    /// legitimate names and stay allowed.
    private static func isSafeComponent(_ component: Substring) -> Bool {
        let decoded = component.removingPercentEncoding ?? String(component)
        if decoded == "." || decoded == ".." { return false }
        return !decoded.contains("/") && !decoded.contains("\\")
    }

    // MARK: Request admission (pure — unit-tested)

    /// Whether a loopback request may be forwarded upstream, and if not, the
    /// HTTP status line to answer with.
    enum Admission: Equatable {
        case accept
        /// Status line fragment, e.g. `"400 Bad Request"`.
        case reject(status: String)
    }

    /// Defense-in-depth admission check for the loopback listener; the listener
    /// already binds to 127.0.0.1 only, but a co-resident process (or a browser
    /// page doing DNS rebinding) can still reach it. Three rules, none of which
    /// touches the legitimate path — every real stream URL is
    /// `http://127.0.0.1:<port>/s/<uuid>` fetched with `GET`/`HEAD`:
    ///   1. the path must be a well-formed `/s/<id>/<rest>` (`route` enforces
    ///      the full shape, including refusing `..` traversal out of the
    ///      registered origin directory);
    ///   2. the `Host`, **when present**, must be an EXACT loopback name — a
    ///      `hasPrefix` test is precisely what `localhost.evil.com` /
    ///      `127.evil.com` slip through, which is the rebinding case this
    ///      check exists to stop. A missing `Host` stays allowed (libVLC's
    ///      access module doesn't always send one);
    ///   3. the method must be a read. Anything else would be forwarded to the
    ///      real origin with the account's token attached, so it is refused.
    /// Pure + `static` so `StreamProxyTests` can exercise it without an
    /// `NWConnection` (same rationale as `parseRange`).
    static func admission(method: String, path: String, hostHeader: String?) -> Admission {
        guard path.hasPrefix("/s/") else { return .reject(status: "400 Bad Request") }
        if let hostHeader, !isLoopbackHost(hostHeader) { return .reject(status: "400 Bad Request") }
        guard allowedMethods.contains(method.uppercased()) else {
            return .reject(status: "405 Method Not Allowed")
        }
        return .accept
    }

    /// Only reads are ever proxied — the upstream request carries the Jellyfin
    /// token, so a forwarded write would act on the user's account.
    private static let allowedMethods: Set<String> = ["GET", "HEAD"]

    /// Exact-match loopback test for a `Host` header value: strips an optional
    /// `:port` (and the brackets of an IPv6 literal), then compares the bare
    /// name against the three loopback forms. Never a prefix match.
    static func isLoopbackHost(_ rawHeaderValue: String) -> Bool {
        let host = rawHeaderValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty else { return false }
        let name: String
        if host.hasPrefix("[") {
            // Bracketed IPv6 literal, optionally with a port: `[::1]`, `[::1]:8080`.
            guard let close = host.firstIndex(of: "]") else { return false }
            let after = host[host.index(after: close)...]
            guard after.isEmpty || isPortSuffix(after) else { return false }
            name = String(host[host.index(after: host.startIndex)..<close])
        } else if host.filter({ $0 == ":" }).count > 1 {
            // Unbracketed IPv6 literal — illegal in a Host header, but accept
            // the bare loopback form rather than guessing a port boundary.
            name = host
        } else if let colon = host.lastIndex(of: ":") {
            guard isPortSuffix(host[colon...]) else { return false }
            name = String(host[..<colon])
        } else {
            name = host
        }
        return name == "127.0.0.1" || name == "localhost" || name == "::1"
    }

    private static func isPortSuffix(_ suffix: Substring) -> Bool {
        guard suffix.hasPrefix(":") else { return false }
        let digits = suffix.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Parses a `bytes=START-END` / `bytes=START-` Range header into
    /// `(start, end?)` for the transparent-reconnect offset math. A missing or
    /// odd header is treated as a full GET `(0, nil)`. A suffix range
    /// (`bytes=-N`, no start) returns `start = -1` so the handler declines to
    /// transparently reconnect it (offset math isn't safe without a start).
    static func parseRange(_ header: String?) -> (start: Int, end: Int?) {
        guard let header, let eq = header.firstIndex(of: "="),
              header[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "bytes" else {
            return (0, nil)
        }
        // Only the first range matters for our single-stream proxy.
        let spec = (header[header.index(after: eq)...].split(separator: ",").first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard let dash = spec.firstIndex(of: "-") else { return (0, nil) }
        let startStr = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let endStr = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        let start = startStr.isEmpty ? -1 : (Int(startStr) ?? -1)
        let end = endStr.isEmpty ? nil : Int(endStr)
        return (start, end)
    }
}

/// Per-request bridge: streams a `URLSession` response into the VLC-facing
/// `NWConnection`, applying backpressure by blocking this task's delegate
/// callback until each loopback send completes. Runs on the proxy session's
/// CONCURRENT delegate queue, so blocking one request never stalls another
/// (essential for MKV's simultaneous seek requests).
///
/// Transparent reconnect: a reverse-proxied / HTTP-2 origin routinely RSTs a
/// long-lived range request mid-stream. Rather than close the loopback
/// connection (which makes libVLC re-buffer / re-open — a visible gap), we
/// silently re-issue the origin request at the next un-delivered byte and keep
/// feeding the SAME connection. libVLC only sees a brief pause in its byte
/// feed, absorbed by its network-caching buffer — so a transient drop is
/// invisible. Bounded by `reconnectsLeft`, which RESETS on any progress, so a
/// flaky-but-working stream recovers indefinitely while a truly dead origin
/// still gives up (closes → libVLC re-opens → player shows its spinner/error).
private final class UpstreamHandler: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let conn: NWConnection
    private let isHead: Bool
    private let label: String
    private let session: URLSession
    private let url: URL
    private let token: String?
    /// Start byte of the original request (so a reconnect resumes at
    /// `rangeStart + bytesDelivered`). -1 ⇒ a suffix range we won't resume.
    private let rangeStart: Int
    private let rangeEnd: Int?
    // `task` is read on the netQueue (conn state handler) and written on the
    // delegate queue (reconnect), so it needs its own lock; the remaining
    // counters are touched only from per-task delegate callbacks, which are
    // serialized and strictly sequential across a reconnect (the old task fully
    // completes before the new one starts) — no lock needed.
    private let taskLock = NSLock()
    private weak var _task: URLSessionTask?
    private var headerSent = false
    private var finished = false
    private var bytesDelivered = 0
    private var bytesAtLastReconnect = 0
    private var reconnectsLeft = maxReconnects
    private var awaitingResumeHead = false
    private static let maxReconnects = 5
    /// Bytes that must stream since the last reconnect before the budget renews.
    /// A flaky-but-feeding origin clears this each spell and recovers forever; a
    /// "connect, trickle, RST" loop never does, so it depletes the budget.
    private static let progressRenewBytes = 256 * 1024

    var task: URLSessionTask? {
        get { taskLock.withLock { _task } }
        set { taskLock.withLock { _task = newValue } }
    }

    init(conn: NWConnection, isHead: Bool, label: String, session: URLSession,
         url: URL, token: String?, rangeStart: Int, rangeEnd: Int?) {
        self.conn = conn
        self.isHead = isHead
        self.label = label
        self.session = session
        self.url = url
        self.token = token
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        super.init()
        // If VLC drops the connection, stop pulling bytes from the origin.
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.task?.cancel()
            default: break
            }
        }
    }

    /// Deterministic teardown (proxy.stop on server switch): abort both sides.
    func cancel() {
        task?.cancel()
        conn.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if awaitingResumeHead {
            awaitingResumeHead = false
            // Resume only works if the origin honored the Range with a 206 from
            // our offset; a 200 (Range ignored) would replay from the start and
            // corrupt the body, so bail to a clean close (libVLC re-opens).
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 206 else {
                proxyLog.error("StreamProxy ▸ \(self.label, privacy: .public) reconnect not resumable (status \(status)) — closing")
                completionHandler(.cancel)
                finish()
                return
            }
            completionHandler(.allow) // splice the body into the same conn, no new head
            return
        }
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
        bytesDelivered += data.count
        // Renew the reconnect budget only on SUBSTANTIAL progress since the last
        // reconnect, so a flaky-but-working stream recovers indefinitely while a
        // pathological trickle-then-RST origin depletes the budget and gives up
        // (closes → libVLC re-opens) instead of looping and pinning threads.
        if bytesDelivered - bytesAtLastReconnect >= Self.progressRenewBytes {
            reconnectsLeft = Self.maxReconnects
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let code = (error as? URLError)?.code
        if let error, code != .cancelled {
            proxyLog.error("StreamProxy ▸ \(self.label, privacy: .public) upstream error: \(error.localizedDescription, privacy: .public)")
        }
        // Never started (no head yet): surface a gateway error so libVLC retries.
        if error != nil, !headerSent {
            conn.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8),
                      isComplete: true, completion: .contentProcessed { [conn] _ in conn.cancel() })
            return
        }
        // Mid-stream drop AFTER we'd begun streaming (origin RST), VLC still
        // wants it (not a cancel), and the request is resumable → re-stitch the
        // upstream invisibly at the next byte.
        if error != nil, code != .cancelled, headerSent, !isHead,
           rangeStart >= 0, reconnectsLeft > 0 {
            reconnect()
            return
        }
        // Clean EOF, VLC walked away (cancel), or budget exhausted → done.
        finish()
    }

    /// Re-issue the origin GET at the next un-delivered byte and keep streaming
    /// into the same loopback connection. The response head is NOT forwarded —
    /// libVLC already has the original head and just keeps reading body bytes.
    private func reconnect() {
        reconnectsLeft -= 1
        bytesAtLastReconnect = bytesDelivered // measure progress of this attempt
        let resumeFrom = rangeStart + bytesDelivered
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if let rangeEnd {
            req.setValue("bytes=\(resumeFrom)-\(rangeEnd)", forHTTPHeaderField: "Range")
        } else {
            req.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
        }
        if let token { req.setValue("MediaBrowser Token=\(token)", forHTTPHeaderField: "Authorization") }
        awaitingResumeHead = true
        proxyLog.log("StreamProxy ▸ \(self.label, privacy: .public) reconnecting at byte \(resumeFrom) (\(self.reconnectsLeft) retries left)")
        let t = session.dataTask(with: req)
        task = t
        t.delegate = self
        t.resume()
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
        guard !finished else { return } // a .cancel disposition re-fires didComplete → don't double-close
        finished = true
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
