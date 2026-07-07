#if os(iOS)
import Foundation
import CinemaxKit
import OSLog
import Observation

private let logger = Logger(subsystem: "com.cinemax", category: "Downloads")

/// Background URLSession orchestrator for offline media.
///
/// Lives on `MainActor` so SwiftUI screens can observe `items` directly. The
/// URLSession's delegate methods fire on the operation queue, not the main
/// actor, so an inner `Adapter` (`@unchecked Sendable`) bridges each callback
/// back via `Task { @MainActor in ... }`.
///
/// Resume contract — see `attach`:
///   1. Tasks left running by the OS during a background launch are
///      rediscovered via `getAllTasks` and re-bound to their `DownloadItem`s
///      by `taskDescription = itemId`.
///   2. Items whose status was `.downloading` but have no matching task got
///      killed mid-flight (force-quit, OOM). If their persisted `resumeData`
///      is present, we relaunch with it; otherwise we mark them `.paused`
///      and let the user trigger a fresh start from the Downloads screen.
@MainActor
@Observable
final class DownloadManager {
    static let maxConcurrent = 2
    static let sessionIdentifier = "com.cinemax.downloads"
    /// Fraction of runtime past which an offline session counts as fully
    /// watched — the position is then cleared and the server is told the item
    /// was played (rather than resumed) on the next reconnect flush.
    static let watchedThreshold = 0.92

    private(set) var items: [DownloadItem] = []

    private let store: DownloadStore
    /// Pending offline-playback progress awaiting a server reconnect. Owned here
    /// because this manager already holds the API client + user id and is the
    /// single hub for every offline concern; kept a standalone store so its
    /// queue logic stays testable and its disk file separate from the catalog.
    private let syncQueue = OfflinePlaybackSyncQueue()
    private weak var apiClientRef: AnyObject?
    private var apiClient: (any DownloadAPI)? {
        apiClientRef as? any DownloadAPI
    }
    /// The same underlying client narrowed to the slices the sync flush needs
    /// (`markItemPlayed` / `reportPlaybackStopped`). The concrete client
    /// conforms to every domain, so this cast succeeds whenever `apiClient` does.
    private var playbackLibraryClient: (any PlaybackAPI & LibraryAPI)? {
        apiClientRef as? (any PlaybackAPI & LibraryAPI)
    }
    /// Cached at `attach(apiClient:userId:)`. PlaybackInfo negotiation requires
    /// the signed-in user id, but the manager outlives any individual
    /// `enqueue` caller, so the user is held here for subsequent
    /// `promoteQueueIfPossible` / `resume` paths that don't have it in scope.
    private var cachedUserId: String?

    private var session: URLSession!
    private var adapter: Adapter!
    /// Task pointers keyed by item id so we can pause / cancel them. URLSession
    /// owns the lifetime; we only keep weak-equivalent references.
    private var tasksByItemId: [String: URLSessionDownloadTask] = [:]
    /// In-flight PlaybackInfo-negotiation `Task`s (one per `startTask`). Tracked
    /// so they can be cancelled on `removeAll()` / teardown — otherwise a
    /// detached prep task outlives the manager and writes to a dead instance.
    private var prepTasksByItemId: [String: Task<Void, Never>] = [:]

    init(store: DownloadStore = DownloadStore()) {
        self.store = store
        self.items = store.all()
        let adapter = Adapter()
        self.adapter = adapter

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: config, delegate: adapter, delegateQueue: queue)
        adapter.owner = self

        // Wipe files that aren't referenced by any catalog entry. Catches the
        // "I cleared the catalog but the file was already on disk" drift we
        // saw in the field (banner reported 6 GB used while the catalog only
        // showed a 2 GB entry).
        DownloadStorage.reconcileOrphans(against: Set(items.map(\.id)))
        refreshDiskUsage()
    }

    /// Wires the API client + signed-in user id so we can negotiate fresh
    /// PlaybackInfo sessions for queued or resumed downloads, and reconciles
    /// any tasks already running in the background session.
    func attach(apiClient: any DownloadAPI, userId: String?) {
        self.apiClientRef = apiClient as AnyObject
        self.cachedUserId = userId
        Task { await self.reconcile() }
    }

    // MARK: - Offline playback sync

    /// Records the offline playhead for a downloaded item: persists a local
    /// resume position (throttled ≤1 disk write/5 s inside `DownloadStore`, forced
    /// on `final`) AND mirrors it into the pending server-sync queue. Called from
    /// the VLC offline player's 1 s tick (`final: false`) and at teardown
    /// (`final: true`). Crossing `watchedThreshold` marks the item watched and
    /// clears the resume position.
    func recordOfflinePlaybackProgress(itemId: String, positionMs: Int, durationMs: Int, final: Bool) {
        guard positionMs > 0 else { return }
        let watched = durationMs > 0 && Double(positionMs) >= Double(durationMs) * Self.watchedThreshold
        guard let updated = store.updatePlaybackPosition(
            id: itemId, positionMs: positionMs, watched: watched, persistImmediately: final
        ) else { return }
        // Reflect into the observable catalog in place so the offline detail
        // screen's resume progress bar updates without a full list rebuild.
        if let idx = items.firstIndex(where: { $0.id == itemId }) {
            items[idx] = updated
        }
        syncQueue.record(
            itemId: itemId, positionTicks: positionMs * 10_000,
            watched: watched, persistImmediately: final
        )
    }

    /// Flushes queued offline progress to the server. No-op until an API client
    /// + user id are attached (offline launch / logged out). Callers gate on
    /// connectivity — the queue is only meant to drain while online.
    func flushPendingPlaybackSync() {
        guard let client = playbackLibraryClient, let userId = cachedUserId else { return }
        Task { await syncQueue.flush(apiClient: client, userId: userId) }
    }

    // MARK: - Queries

    func item(for id: String) -> DownloadItem? {
        items.first { $0.id == id }
    }

    func isDownloaded(itemId: String) -> Bool {
        item(for: itemId)?.status == .completed
    }

    /// Returns every completed (or in-flight) episode download whose
    /// `seriesId` matches `id`. Used by offline-mode detail screens to render
    /// a season-grouped episode list without hitting the API.
    func episodes(forSeriesId id: String) -> [DownloadItem] {
        items.filter { $0.seriesId == id }
            .sorted { lhs, rhs in
                (lhs.seasonIndex ?? 0, lhs.episodeIndex ?? 0)
                    < (rhs.seasonIndex ?? 0, rhs.episodeIndex ?? 0)
            }
    }

    /// True when the user has *any* completed download — used to decide
    /// whether to render an offline library or an empty / error state.
    var hasAnyCompletedDownload: Bool {
        items.contains { $0.status == .completed }
    }

    /// Every completed download split by kind. Ordered by completion date
    /// (most recent first) so "newest" works as the natural ordering for
    /// offline library listings.
    func completedItems() -> (movies: [DownloadItem], series: [(seriesId: String, title: String, episodes: [DownloadItem])]) {
        let completed = items.filter { $0.status == .completed }
        let movies = completed.filter { $0.kind == .movie }
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
        var bySeries: [String: [DownloadItem]] = [:]
        var seriesOrder: [String] = []
        for entry in completed where entry.kind == .episode {
            let key = entry.seriesId ?? entry.id
            if bySeries[key] == nil { seriesOrder.append(key) }
            bySeries[key, default: []].append(entry)
        }
        let series = seriesOrder.compactMap { key -> (String, String, [DownloadItem])? in
            guard let eps = bySeries[key]?.sorted(by: {
                ($0.seasonIndex ?? 0, $0.episodeIndex ?? 0) < ($1.seasonIndex ?? 0, $1.episodeIndex ?? 0)
            }) else { return nil }
            let title = eps.first?.seriesTitle ?? eps.first?.title ?? ""
            return (key, title, eps)
        }
        return (movies, series)
    }

    /// Local file URL for a completed download, if any. Returns `nil` for
    /// queued / downloading / paused / failed entries — the caller falls
    /// back to streaming.
    func localURL(forItemId itemId: String) -> URL? {
        guard let item = item(for: itemId),
              item.status == .completed,
              let name = item.localFileName,
              let dir = try? DownloadStorage.filesDirectory() else { return nil }
        let url = dir.appendingPathComponent(name, isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Cached on-disk footprint. `DownloadStorage.totalDiskUsage()` is a
    /// blocking recursive walk of the multi-GB media tree — never compute it
    /// in a SwiftUI `body`. Refreshed off-main only on catalog lifecycle
    /// events (finish / remove / wipe / enqueue), never on progress ticks.
    private(set) var totalDiskBytes: Int64 = 0

    private func refreshDiskUsage() {
        Task.detached(priority: .utility) { [weak self] in
            let bytes = DownloadStorage.totalDiskUsage()
            await self?.applyDiskUsage(bytes)
        }
    }

    /// Main-actor sink for the off-main disk walk. Going through a method (vs.
    /// `MainActor.run { self?... }`) keeps `self` touched only on the main actor,
    /// satisfying Swift 6 region isolation while staying weak.
    private func applyDiskUsage(_ bytes: Int64) {
        totalDiskBytes = bytes
    }

    /// Returns the on-disk poster file URL when we've already cached the
    /// artwork during enqueue. Offline screens prefer this over a remote URL
    /// so airplane-mode users still see thumbnails.
    func localPosterURL(forItemId id: String) -> URL? {
        guard let url = try? DownloadStorage.artFileURL(itemId: id, kind: .poster),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func localBackdropURL(forItemId id: String) -> URL? {
        guard let url = try? DownloadStorage.artFileURL(itemId: id, kind: .backdrop),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - Mutations

    /// Adds an item to the queue. If concurrency is below `maxConcurrent` it
    /// starts immediately; otherwise it sits as `.queued`.
    ///
    /// `posterURL` / `backdropURL` are optional artwork sources the manager
    /// fetches in the background so the user can see thumbnails offline.
    /// Callers that don't have them ready can pass `nil` and the offline
    /// screens fall back to a styled placeholder.
    func enqueue(_ item: DownloadItem, posterURL: URL? = nil, backdropURL: URL? = nil) {
        if items.contains(where: { $0.id == item.id }) {
            // Already tracked — surface as a no-op so callers can be idempotent.
            return
        }
        store.upsert(item)
        items = store.all()
        cachePoster(for: item.id, posterURL: posterURL, backdropURL: backdropURL)
        promoteQueueIfPossible()
        refreshDiskUsage()
    }

    /// Wipes everything: cancels in-flight tasks, drops the catalog, deletes
    /// every file under the downloads tree. Exposed to the user as
    /// "Remove all downloads" in Settings → Downloads.
    func removeAll() {
        for (_, task) in prepTasksByItemId {
            task.cancel()
        }
        prepTasksByItemId.removeAll()
        for (_, task) in tasksByItemId {
            task.cancel()
        }
        tasksByItemId.removeAll()
        for entry in items {
            store.remove(id: entry.id)
        }
        syncQueue.clear()
        DownloadStorage.wipeEverything()
        items = []
        refreshDiskUsage()
    }

    // MARK: - Artwork prefetch

    /// Fetches poster + backdrop JPEGs and writes them next to the media
    /// file. Fire-and-forget — failure leaves the offline screens to render
    /// a placeholder rather than blocking the actual media download.
    private func cachePoster(for id: String, posterURL: URL?, backdropURL: URL?) {
        let work: [(URL, DownloadStorage.ArtKind)] = [
            posterURL.map { ($0, .poster) },
            backdropURL.map { ($0, .backdrop) }
        ].compactMap { $0 }
        guard !work.isEmpty else { return }
        Task.detached {
            for (url, kind) in work {
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { continue }
                guard let dest = try? DownloadStorage.artFileURL(itemId: id, kind: kind) else { continue }
                try? data.write(to: dest, options: .atomic)
            }
        }
    }

    func pause(_ id: String) {
        guard let task = tasksByItemId[id] else {
            // No live task — just flip status. Nothing to cancel.
            store.update(id: id) { $0.status = .paused }
            items = store.all()
            return
        }
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                self?.applyPause(id: id, resumeData: data)
            }
        })
    }

    private func applyPause(id: String, resumeData: Data?) {
        store.update(id: id) { item in
            item.status = .paused
            item.resumeData = resumeData
        }
        tasksByItemId.removeValue(forKey: id)
        items = store.all()
        promoteQueueIfPossible()
    }

    /// Resumes a paused / failed download. If we have resume data, the
    /// URLSession picks up where it left off; otherwise we start fresh.
    func resume(_ id: String) {
        guard let entry = items.first(where: { $0.id == id }) else { return }
        if entry.status == .downloading || entry.status == .queued { return }
        // Throttle: if at capacity, mark queued and let promotion fire later.
        let activeCount = items.filter { $0.status == .downloading }.count
        if activeCount >= Self.maxConcurrent {
            store.update(id: id) { $0.status = .queued; $0.errorMessage = nil }
            items = store.all()
            return
        }
        startTask(for: entry)
    }

    /// Cancels and removes the entry entirely. Deletes the partial / finished
    /// file from disk too.
    func remove(_ id: String) {
        if let prep = prepTasksByItemId.removeValue(forKey: id) {
            prep.cancel()
        }
        if let task = tasksByItemId.removeValue(forKey: id) {
            task.cancel()
        }
        if let entry = items.first(where: { $0.id == id }) {
            if let name = entry.localFileName,
               let dir = try? DownloadStorage.filesDirectory() {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
            if let resumeURL = try? DownloadStorage.resumeFileURL(itemId: id) {
                try? FileManager.default.removeItem(at: resumeURL)
            }
        }
        store.remove(id: id)
        // Item is gone — a pending resume/watched sync for it is now moot.
        syncQueue.drop(itemId: id)
        items = store.all()
        promoteQueueIfPossible()
        refreshDiskUsage()
    }

    // MARK: - Internal task plumbing

    private func startTask(for entry: DownloadItem) {
        guard let apiClient else {
            logger.error("startTask: no API client yet — leaving \(entry.id, privacy: .public) queued")
            store.update(id: entry.id) { $0.status = .queued }
            items = store.all()
            return
        }
        if let data = entry.resumeData {
            // Resume tasks don't need a fresh PlaybackInfo session — the
            // URLSession resume blob already carries the in-flight URL.
            let task = session.downloadTask(withResumeData: data)
            task.taskDescription = entry.id
            tasksByItemId[entry.id] = task
            store.update(id: entry.id) { item in
                item.status = .downloading
                item.errorMessage = nil
                item.resumeData = nil
            }
            items = store.all()
            task.resume()
            return
        }
        guard let userId = cachedUserId else {
            logger.error("startTask: no userId yet — leaving \(entry.id, privacy: .public) queued")
            store.update(id: entry.id) { $0.status = .queued }
            items = store.all()
            return
        }
        // PlaybackInfo negotiation is async — fire a detached task and bridge
        // the result back through the main actor.
        store.update(id: entry.id) { item in
            item.status = .downloading
            item.errorMessage = nil
        }
        items = store.all()
        let entryId = entry.id
        let task = Task { [weak self] in
            defer { self?.prepTasksByItemId[entryId] = nil }
            guard let self else { return }
            do {
                let req = try await apiClient.buildDownloadRequest(itemId: entryId, userId: userId)
                if Task.isCancelled { return }
                self.launchTask(itemId: entryId, request: req)
            } catch {
                if Task.isCancelled { return }
                self.markFailed(itemId: entryId, error: error)
            }
        }
        prepTasksByItemId[entryId] = task
    }

    private func launchTask(itemId: String, request: DownloadStreamRequest) {
        let task = session.downloadTask(with: request.asURLRequest())
        task.taskDescription = itemId
        tasksByItemId[itemId] = task
        task.resume()
    }

    private func markFailed(itemId: String, error: Error) {
        store.update(id: itemId) { item in
            item.status = .failed
            item.errorMessage = error.localizedDescription
        }
        items = store.all()
        promoteQueueIfPossible()
    }

    private func promoteQueueIfPossible() {
        let activeCount = items.filter { $0.status == .downloading }.count
        guard activeCount < Self.maxConcurrent else { return }
        let queued = items.filter { $0.status == .queued }.sorted { $0.createdAt < $1.createdAt }
        for entry in queued.prefix(Self.maxConcurrent - activeCount) {
            startTask(for: entry)
        }
    }

    private func reconcile() async {
        let running = await session.allTasks
        var attached: Set<String> = []
        for task in running {
            guard let id = task.taskDescription, let dl = task as? URLSessionDownloadTask else { continue }
            tasksByItemId[id] = dl
            attached.insert(id)
        }
        // Items marked downloading whose task didn't survive: try resume data,
        // else flip to paused so the user can retry.
        for entry in items where entry.status == .downloading && !attached.contains(entry.id) {
            if entry.resumeData != nil {
                startTask(for: entry)
            } else {
                store.update(id: entry.id) { item in
                    item.status = .paused
                    item.errorMessage = nil
                }
            }
        }
        items = store.all()
        promoteQueueIfPossible()
    }

    // MARK: - Delegate callbacks (called by Adapter, on MainActor)

    fileprivate func didWrite(taskId: String, received: Int64, total: Int64) {
        // Throttled disk write inside the store — no full catalog re-encode
        // on every byte callback.
        store.updateProgress(id: taskId, received: received, total: total)
        // Avoid rebuilding the full list on every progress tick — replace in place.
        if let idx = items.firstIndex(where: { $0.id == taskId }) {
            var copy = items[idx]
            copy.bytesReceived = received
            if total > 0 { copy.totalBytes = total }
            copy.status = .downloading
            items[idx] = copy
        }
    }

    fileprivate func didFinish(taskId: String, sourceURL: URL) {
        guard let entry = store.item(id: taskId) else {
            try? FileManager.default.removeItem(at: sourceURL)
            return
        }
        // Container detection order (server is authoritative — we never
        // re-encode locally, so this needs to match the actual file bytes):
        //   1. `Content-Disposition: attachment; filename="…ext"` — Jellyfin's
        //      `/Items/{id}/Download` always sets this.
        //   2. `Content-Type` mime mapping.
        //   3. Fall back to the catalog's initial guess.
        let response = tasksByItemId[taskId]?.response as? HTTPURLResponse
        let disposition = response?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let mime = response?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let ext = Self.extensionFromDisposition(disposition)
            ?? Self.extensionForMime(mime)
            ?? entry.containerExt
        let fileName = "\(taskId).\(ext)"
        do {
            let dest = try DownloadStorage.filesDirectory().appendingPathComponent(fileName, isDirectory: false)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: sourceURL, to: dest)
            // Belt-and-braces: per-file backup exclusion in case the parent
            // tree wasn't fully marked.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = dest
            try? mutable.setResourceValues(values)

            // `Content-Length` is missing on chunked transfer responses, so
            // the in-flight `totalBytes` is 0. The on-disk size is the only
            // reliable source after move — read it explicitly so the row
            // doesn't show "Zéro ko".
            let onDiskSize: Int64 = {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
                      let size = attrs[.size] as? Int64 else { return 0 }
                return size
            }()

            store.update(id: taskId) { item in
                item.status = .completed
                item.localFileName = fileName
                item.containerExt = ext
                if onDiskSize > 0 {
                    item.totalBytes = onDiskSize
                    item.bytesReceived = onDiskSize
                } else {
                    // Last-resort safeguard — keep whatever the last delegate
                    // tick reported instead of nuking it to 0.
                    item.bytesReceived = max(item.bytesReceived, item.totalBytes)
                }
                item.completedAt = Date()
                item.resumeData = nil
                item.errorMessage = nil
            }
        } catch {
            store.update(id: taskId) { item in
                item.status = .failed
                item.errorMessage = error.localizedDescription
            }
        }
        tasksByItemId.removeValue(forKey: taskId)
        items = store.all()
        promoteQueueIfPossible()
        refreshDiskUsage()
    }

    fileprivate func didFail(taskId: String, error: Error?) {
        // Successful completion arrives here too, after didFinish — so only
        // touch the entry if it isn't already terminal.
        guard let entry = store.item(id: taskId) else { return }
        if entry.status == .completed { return }
        if let error {
            let ns = error as NSError
            let resumeData = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            store.update(id: taskId) { item in
                if ns.code == NSURLErrorCancelled {
                    // User-initiated cancel — already handled via pause path.
                    if item.status != .paused { item.status = .paused }
                } else {
                    item.status = .failed
                    item.errorMessage = error.localizedDescription
                }
                item.resumeData = resumeData
            }
        }
        tasksByItemId.removeValue(forKey: taskId)
        items = store.all()
        promoteQueueIfPossible()
    }

    // MARK: - Helpers

    /// Parses `filename="movie.mkv"` out of a `Content-Disposition` header.
    /// Returns the extension (without the dot) lowercased, or `nil` if the
    /// header is missing / malformed.
    private static func extensionFromDisposition(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        // Tolerate `filename=`, `filename="…"`, and the `filename*=` variant.
        let lower = value.lowercased()
        guard let range = lower.range(of: "filename") else { return nil }
        let tail = String(value[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop optional `*=` / `=` then strip quotes.
        let stripped = tail
            .replacingOccurrences(of: "*=", with: "=")
            .drop(while: { $0 == "=" || $0.isWhitespace })
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        // `filename*=UTF-8''movie.mkv` style — drop locale prefix.
        let candidate = stripped.split(separator: ";").first.map(String.init) ?? String(stripped)
        let name = candidate.split(separator: "/").last.map(String.init) ?? candidate
        guard let dot = name.lastIndex(of: "."), dot < name.index(before: name.endIndex) else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        // Sanity: an extension shouldn't be longer than 5 chars or contain weird bytes.
        guard ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return ext
    }

    private static func extensionForMime(_ mime: String) -> String? {
        let lower = mime.lowercased()
        if lower.contains("matroska") || lower.contains("mkv") { return "mkv" }
        if lower.contains("mp4") { return "mp4" }
        if lower.contains("quicktime") { return "mov" }
        if lower.contains("webm") { return "webm" }
        if lower.contains("mpegts") || lower.contains("mp2t") { return "ts" }
        if lower.contains("x-msvideo") { return "avi" }
        return nil
    }

    // MARK: - Delegate adapter

    private final class Adapter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        /// Write-once: set exactly once on the MainActor in `DownloadManager.init`
        /// before the session issues any callback, then only read (each read
        /// immediately hops via `Task { @MainActor [weak owner] }`). Never
        /// mutated after wiring — same single-assignment invariant as the
        /// lock-protected `JellyfinClient` reference.
        weak var owner: DownloadManager?

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard let id = downloadTask.taskDescription else { return }
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
            Task { @MainActor [weak owner] in
                owner?.didWrite(taskId: id, received: totalBytesWritten, total: total)
            }
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // The session destroys `location` on return, so move synchronously
            // to a staging path before hopping actors.
            guard let id = downloadTask.taskDescription else { return }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cinemax-dl-\(UUID().uuidString)"
            )
            do {
                try FileManager.default.moveItem(at: location, to: staging)
            } catch {
                // Couldn't even stage — let didComplete surface the error.
                return
            }
            Task { @MainActor [weak owner] in
                owner?.didFinish(taskId: id, sourceURL: staging)
            }
        }

        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        didCompleteWithError error: (any Error)?) {
            guard let id = task.taskDescription else { return }
            Task { @MainActor [weak owner] in
                owner?.didFail(taskId: id, error: error)
            }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            Task { @MainActor in
                let handler = CinemaxAppDelegate.backgroundSessionCompletion
                CinemaxAppDelegate.backgroundSessionCompletion = nil
                handler?()
            }
        }
    }
}

#endif
