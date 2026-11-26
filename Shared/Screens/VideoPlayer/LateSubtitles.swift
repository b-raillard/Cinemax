import CinemaxKit
import Foundation

/// The text subtitles of a server TRANSCODE, brought in AFTER the picture is
/// up (owner, 2026-11-26: « rien ne justifie qu'on attende longtemps pour
/// lancer le film »).
///
/// To serve an embedded text subtitle — burned into the picture or as a file —
/// Jellyfin first extracts it, which reads the WHOLE media: 2 min 13 on a
/// 19 GB MKV (13/11), and the first segment waits for it. Handing libVLC the
/// file's URL at open waits just the same (measured on the bench, 8.9 GB:
/// 8.7 s burned in, 9.5 s as a slave at open, 2.6 s once cached). So the
/// transcode starts with NO text subtitle, the app downloads the files itself
/// in the background, and each one is added to the running player when it
/// lands. Pure parts here; the player side is
/// `VLCStreamPresenter.attachLateSubtitles`.
enum LateSubtitles {
    /// The tracks brought in late: on a transcode, every subtitle the server
    /// offered a file for — in the server's order, which is the order they are
    /// added in, so their libVLC ordinals are their positions here. Image
    /// subtitles (no file) stay burned in by the server.
    static func tracks(of info: PlaybackInfo) -> [MediaTrackInfo] {
        guard info.playMethod == .transcode else { return [] }
        return info.subtitleTracks.filter { $0.deliveryURL != nil }
    }

    /// What one download is cached under: a re-open of the same source (error
    /// retry, re-negotiation) reuses the files, another source starts over.
    static func cacheKey(of info: PlaybackInfo, itemId: String) -> String {
        "\(info.mediaSourceId ?? itemId)|" + tracks(of: info).map { String($0.id) }.joined(separator: ",")
    }

    /// The local file a track is saved as. The extension is what libVLC picks
    /// its subtitle parser from: Jellyfin names SubRip `subrip`, which no
    /// parser claims.
    static func fileName(position: Int, deliveryURL: URL) -> String {
        let served = deliveryURL.pathExtension.lowercased()
        let known = ["srt", "ass", "ssa", "vtt"]
        let ext = served == "subrip" ? "srt" : (served == "webvtt" ? "vtt" : (known.contains(served) ? served : "srt"))
        return "\(position).\(ext)"
    }

    /// Stands in for a file that could not be downloaded: the track still
    /// takes its place in libVLC's list, so the tracks after it keep their
    /// ordinals — it shows nothing.
    static let placeholderFileName = "empty.srt"
    static let placeholder = Data("1\n00:00:00,000 --> 00:00:00,001\n \n".utf8)

    /// How long the wanted subtitle may be missing before the player says so.
    static let noticeDelay: Duration = .seconds(4)

    /// Ephemeral, like every session fetching token-bearing URLs
    /// (`HLSManifestLoader`), trusting the approved certificate. The request
    /// timeout covers the extraction itself: the server answers nothing until
    /// it has read the whole file.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15 * 60
        config.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: config, delegate: ServerTrustDelegate.shared, delegateQueue: nil)
    }()

    /// Downloads one subtitle into `directory`; nil when the server refused,
    /// failed, or the task was cancelled.
    static func download(_ url: URL, position: Int, into directory: URL) async -> URL? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        let file = directory.appendingPathComponent(fileName(position: position, deliveryURL: url))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    /// A request held open for minutes is what a reverse proxy cuts, and what
    /// iOS drops in the background — while the server goes on extracting and
    /// caches the result. So a failed download is asked again before the track
    /// is given up as empty.
    static let attempts = 3
    static let retryDelay: Duration = .seconds(5)

    static func downloadWithRetries(_ url: URL, position: Int, into directory: URL) async -> URL? {
        for attempt in 1...attempts {
            if let file = await download(url, position: position, into: directory) { return file }
            guard attempt < attempts, !Task.isCancelled else { return nil }
            try? await Task.sleep(for: retryDelay)
        }
        return nil
    }

    /// The placeholder, written once per directory.
    static func placeholderFile(in directory: URL) -> URL? {
        let file = directory.appendingPathComponent(placeholderFileName)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try placeholder.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
}
