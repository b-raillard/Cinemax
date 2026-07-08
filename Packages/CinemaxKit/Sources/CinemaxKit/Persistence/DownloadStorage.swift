import Foundation

/// File system layout for offline downloads.
///
///   Application Support/
///     Cinemax/
///       Downloads/
///         index.json                  ← `DownloadStore` JSON catalog
///         files/
///           <itemId>.<ext>            ← finished media
///         resume/
///           <itemId>.resume           ← URLSession resume blobs for paused / interrupted tasks
///
/// Whole `Downloads` subtree is marked `isExcludedFromBackup` so a 30 GB
/// offline library doesn't end up in iCloud.
public enum DownloadStorage {
    public static func downloadsRoot() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = appSupport.appendingPathComponent("Cinemax/Downloads", isDirectory: true)
        try ensureDirectory(at: root, excludeFromBackup: true)
        try ensureDirectory(at: root.appendingPathComponent("files", isDirectory: true), excludeFromBackup: false)
        try ensureDirectory(at: root.appendingPathComponent("resume", isDirectory: true), excludeFromBackup: false)
        try ensureDirectory(at: root.appendingPathComponent("art", isDirectory: true), excludeFromBackup: false)
        return root
    }

    public static func indexURL() throws -> URL {
        try downloadsRoot().appendingPathComponent("index.json", isDirectory: false)
    }

    /// JSON file backing the pending offline-playback → server sync queue
    /// (`OfflinePlaybackSyncQueue`). Kept separate from `index.json` so the
    /// high-churn queue writes don't rewrite the whole download catalog.
    public static func syncQueueURL() throws -> URL {
        try downloadsRoot().appendingPathComponent("playback-sync.json", isDirectory: false)
    }

    public static func filesDirectory() throws -> URL {
        try downloadsRoot().appendingPathComponent("files", isDirectory: true)
    }

    public static func resumeDirectory() throws -> URL {
        try downloadsRoot().appendingPathComponent("resume", isDirectory: true)
    }

    public static func artDirectory() throws -> URL {
        try downloadsRoot().appendingPathComponent("art", isDirectory: true)
    }

    public static func mediaFileURL(itemId: String, ext: String) throws -> URL {
        try filesDirectory().appendingPathComponent("\(itemId).\(ext)", isDirectory: false)
    }

    public static func resumeFileURL(itemId: String) throws -> URL {
        try resumeDirectory().appendingPathComponent("\(itemId).resume", isDirectory: false)
    }

    /// Local cache path for an item's poster artwork. `kind` keys the file so
    /// a movie poster and a series backdrop can coexist without clobbering
    /// each other.
    public enum ArtKind: String, Sendable {
        case poster   // 2:3 primary image
        case backdrop // 16:9 hero image
    }

    public static func artFileURL(itemId: String, kind: ArtKind) throws -> URL {
        try artDirectory().appendingPathComponent("\(itemId)-\(kind.rawValue).jpg", isDirectory: false)
    }

    /// Removes every downloaded file (media, resume blobs, posters, and the
    /// catalog itself). Used by "Remove all downloads" in Settings.
    public static func wipeEverything() {
        guard let root = try? downloadsRoot() else { return }
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for url in contents {
                try? fm.removeItem(at: url)
            }
        }
        // Re-create the empty subtree so subsequent downloads have somewhere
        // to land without a crash.
        _ = try? downloadsRoot()
    }

    /// Deletes files in `files/` whose itemId isn't referenced by any of the
    /// passed-in catalog entries. Used at app launch to drop orphaned media
    /// left behind by aborted downloads or interrupted catalog writes.
    public static func reconcileOrphans(against trackedIDs: Set<String>) {
        guard let dir = try? filesDirectory(),
              let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents {
            let stem = url.deletingPathExtension().lastPathComponent
            if !trackedIDs.contains(stem) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    public static func totalDiskUsage() -> Int64 {
        // Walk both the media and art subtrees so the surfaced number matches
        // what `wipeEverything` would free — otherwise the banner reads less
        // than the actual on-disk footprint.
        var total: Int64 = 0
        for dir in [try? filesDirectory(), try? artDirectory()].compactMap({ $0 }) {
            guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in enumerator {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Helpers

    private static func ensureDirectory(at url: URL, excludeFromBackup: Bool) throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        if excludeFromBackup {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(values)
        }
        #if os(iOS)
        // Offline media + the catalog hold viewing history and metadata.
        // `completeUntilFirstUserAuthentication` keeps them readable for
        // background-download writes after the first post-boot unlock while
        // still protecting them on a powered-off lost/stolen device. Files
        // created inside inherit the directory's protection class.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}
