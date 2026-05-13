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
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
