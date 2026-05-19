import Foundation

/// JSON-backed catalog of `DownloadItem`s persisted to Application Support.
///
/// Designed as a thin, lock-protected facade — `DownloadManager` owns the
/// state machine and calls in for atomic reads + writes. Same locking
/// invariant as `JellyfinAPIClient`: every access goes through one of the
/// accessor methods. Saves are debounced via direct synchronous writes;
/// the catalog is tiny (one entry per download), so writing on every mutation
/// is fine.
public final class DownloadStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: DownloadItem] = [:]
    private let url: URL?
    /// Throttle window for progress-only writes. Status transitions still
    /// persist immediately; only the sub-second byte-count churn is coalesced.
    private static let progressPersistInterval: TimeInterval = 5
    private var lastProgressPersist = Date.distantPast

    public init() {
        let resolved = (try? DownloadStorage.indexURL())
        self.url = resolved
        if let url = resolved, let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder.cinemax.decode([DownloadItem].self, from: data) {
                self.items = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
            }
        }
    }

    public func all() -> [DownloadItem] {
        lock.lock(); defer { lock.unlock() }
        return Array(items.values)
    }

    public func item(id: String) -> DownloadItem? {
        lock.lock(); defer { lock.unlock() }
        return items[id]
    }

    /// Inserts or replaces an item. Persists to disk synchronously.
    @discardableResult
    public func upsert(_ item: DownloadItem) -> DownloadItem {
        lock.lock()
        items[item.id] = item
        let snapshot = Array(items.values)
        lock.unlock()
        persist(snapshot)
        return item
    }

    /// Mutates an existing item in place. No-op if the id isn't tracked.
    @discardableResult
    public func update(id: String, _ mutation: (inout DownloadItem) -> Void) -> DownloadItem? {
        lock.lock()
        guard var current = items[id] else {
            lock.unlock()
            return nil
        }
        mutation(&current)
        items[id] = current
        let snapshot = Array(items.values)
        lock.unlock()
        persist(snapshot)
        return current
    }

    /// Progress-only mutation from the per-tick download delegate. Updates the
    /// in-memory catalog every call but writes to disk at most once per
    /// `progressPersistInterval` — the old code re-encoded + atomically
    /// rewrote the whole catalog on every URLSession byte callback (several
    /// times/sec/download), which was pure write amplification. Interrupted
    /// progress is recoverable from resume blobs / disk scan on next launch.
    @discardableResult
    public func updateProgress(id: String, received: Int64, total: Int64) -> DownloadItem? {
        lock.lock()
        guard var current = items[id] else {
            lock.unlock()
            return nil
        }
        current.bytesReceived = received
        if total > 0 { current.totalBytes = total }
        current.status = .downloading
        items[id] = current
        let now = Date()
        let due = now.timeIntervalSince(lastProgressPersist) >= Self.progressPersistInterval
        let snapshot: [DownloadItem]? = due ? Array(items.values) : nil
        if due { lastProgressPersist = now }
        lock.unlock()
        if let snapshot { persist(snapshot) }
        return current
    }

    public func remove(id: String) {
        lock.lock()
        items.removeValue(forKey: id)
        let snapshot = Array(items.values)
        lock.unlock()
        persist(snapshot)
    }

    /// Items downloading or queued — used to compute concurrency.
    public func active() -> [DownloadItem] {
        lock.lock(); defer { lock.unlock() }
        return items.values.filter { $0.status == .downloading || $0.status == .queued }
    }

    // MARK: - Persistence

    private func persist(_ snapshot: [DownloadItem]) {
        guard let url else { return }
        do {
            let data = try JSONEncoder.cinemax.encode(snapshot.sorted(by: { $0.createdAt < $1.createdAt }))
            try data.write(to: url, options: .atomic)
        } catch {
            // Loss of catalogue is recoverable from disk scan on next launch,
            // so swallow rather than crash.
        }
    }
}

extension JSONDecoder {
    static let cinemax: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let cinemax: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        // On-disk machine file — no need for pretty/sorted output; keeping it
        // compact avoids needless encode cost on catalog writes.
        e.outputFormatting = []
        return e
    }()
}
