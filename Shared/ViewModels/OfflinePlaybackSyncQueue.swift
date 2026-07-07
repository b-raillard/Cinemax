#if os(iOS)
import Foundation
import CinemaxKit
import OSLog
import Observation

private let logger = Logger(subsystem: "com.cinemax", category: "OfflineSync")

/// One offline playback session's worth of progress that the server hasn't
/// learned about yet. Keyed by `itemId` (update-in-place; only the latest
/// position per item matters). `positionTicks` is in Jellyfin ticks (ms ×
/// 10 000). `failedFlushes` bounds retries so a permanently-rejected entry
/// (deleted item, changed permissions) eventually drops instead of retrying
/// forever on every reconnect.
struct PendingPlaybackSync: Codable, Identifiable, Sendable {
    let itemId: String
    var positionTicks: Int
    var watched: Bool
    var updatedAt: Date
    var failedFlushes: Int
    var id: String { itemId }
}

/// Durable queue of offline playback progress waiting to be synced back to the
/// Jellyfin server.
///
/// Recorded into while the user watches a downloaded item offline (no network),
/// then flushed on the next online transition / app-start-online: `watched`
/// entries become `markItemPlayed`, the rest `reportPlaybackStopped` at the
/// stored position. Owned and driven by `DownloadManager` (which holds the API
/// client + user id); kept a standalone type so the queue logic is testable in
/// isolation and its disk file stays separate from the download catalog.
///
/// Persisted as a small JSON file in the downloads storage tree (atomic write,
/// same discipline as `index.json`) so a mid-playback force-quit doesn't lose
/// the pending sync.
@MainActor
@Observable
final class OfflinePlaybackSyncQueue {
    /// Drop an entry after this many consecutive failed flush attempts.
    private static let maxFailedFlushes = 5
    /// Coalesce disk writes for the high-churn per-tick `record` path.
    private static let persistInterval: TimeInterval = 5

    private(set) var pending: [PendingPlaybackSync] = []

    private let url: URL?
    private var lastPersist = Date.distantPast
    /// Guards against overlapping flushes (a Wi-Fi flap can fire the online
    /// transition twice in quick succession).
    private var isFlushing = false

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()

    init() {
        self.url = try? DownloadStorage.syncQueueURL()
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? Self.decoder.decode([PendingPlaybackSync].self, from: data) {
            self.pending = decoded
        }
    }

    // MARK: - Recording

    /// Records (or updates) the pending sync for an item. Called from the VLC
    /// offline player's tick (`persistImmediately == false`, throttled) and at
    /// teardown (`persistImmediately == true`, forces a write so a clean exit
    /// is durable). Fresh activity resets the retry budget.
    func record(itemId: String, positionTicks: Int, watched: Bool, persistImmediately: Bool = false) {
        if let idx = pending.firstIndex(where: { $0.itemId == itemId }) {
            pending[idx].positionTicks = positionTicks
            // Sticky: once a session crossed the watched threshold, a slightly
            // earlier tail position must not downgrade it back to "in progress".
            pending[idx].watched = watched || pending[idx].watched
            pending[idx].updatedAt = Date()
            pending[idx].failedFlushes = 0
        } else {
            pending.append(PendingPlaybackSync(
                itemId: itemId, positionTicks: positionTicks,
                watched: watched, updatedAt: Date(), failedFlushes: 0
            ))
        }
        let now = Date()
        if persistImmediately || now.timeIntervalSince(lastPersist) >= Self.persistInterval {
            lastPersist = now
            persist()
        }
    }

    /// Drops the entry for an item — used when its download is removed before we
    /// could flush (nothing left to sync).
    func drop(itemId: String) {
        guard pending.contains(where: { $0.itemId == itemId }) else { return }
        pending.removeAll { $0.itemId == itemId }
        persist()
    }

    /// Clears the whole queue (bulk "remove all downloads").
    func clear() {
        guard !pending.isEmpty else { return }
        pending.removeAll()
        persist()
    }

    // MARK: - Flushing

    /// Flushes every pending entry to the server. `watched` → `markItemPlayed`;
    /// otherwise `reportPlaybackStopped` at the stored position (playSessionId
    /// nil is tolerated by the Jellyfin stop-info endpoint). Entries that succeed
    /// are removed; a `markItemPlayed` that throws is retained with its retry
    /// count bumped, and dropped once it exhausts `maxFailedFlushes`.
    ///
    /// `reportPlaybackStopped` is fire-and-forget (never throws — matches the
    /// online reporter's contract), so its entries are always cleared on a flush;
    /// callers gate the flush on connectivity so this only runs while online.
    func flush(apiClient: any PlaybackAPI & LibraryAPI, userId: String) async {
        guard !isFlushing, !pending.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }

        let snapshot = pending
        var toRemove: Set<String> = []
        var bumpedFailures: [String: Int] = [:]

        for entry in snapshot {
            if entry.watched {
                do {
                    try await apiClient.markItemPlayed(itemId: entry.itemId, userId: userId)
                    toRemove.insert(entry.itemId)
                } catch {
                    let next = entry.failedFlushes + 1
                    if next >= Self.maxFailedFlushes {
                        logger.error("Dropping offline-sync entry \(entry.itemId, privacy: .public) after \(next) failed flushes: \(error.localizedDescription, privacy: .public)")
                        toRemove.insert(entry.itemId)
                    } else {
                        bumpedFailures[entry.itemId] = next
                    }
                }
            } else {
                // Fire-and-forget; assumed delivered while online.
                await apiClient.reportPlaybackStopped(
                    itemId: entry.itemId, userId: userId,
                    mediaSourceId: entry.itemId, playSessionId: nil,
                    positionTicks: entry.positionTicks
                )
                toRemove.insert(entry.itemId)
            }
        }

        // Reconcile against the CURRENT queue, not the snapshot — a fresh
        // `record` may have landed mid-flush (its 0-count reset is preserved).
        var changed = false
        pending.removeAll { entry in
            if toRemove.contains(entry.itemId) { changed = true; return true }
            return false
        }
        for idx in pending.indices {
            if let bumped = bumpedFailures[pending[idx].itemId], pending[idx].failedFlushes < bumped {
                pending[idx].failedFlushes = bumped
                changed = true
            }
        }
        if changed { persist() }
    }

    // MARK: - Persistence

    private func persist() {
        guard let url else { return }
        do {
            let data = try Self.encoder.encode(pending)
            try data.write(to: url, options: .atomic)
        } catch {
            // Recoverable — a lost queue only costs a resume-point sync, and the
            // local resume position is still persisted in the download catalog.
        }
    }
}
#endif
