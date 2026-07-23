import Foundation
import Nuke

/// Shared authenticated GET for Jellyfin image endpoints (chapter thumbnails,
/// trickplay tiles, now-playing artwork). Attaches the `MediaBrowser Token=`
/// Authorization header and routes the request through Nuke's shared
/// `ImagePipeline`, so the bytes are served from — and warmed into — the app's
/// 500 MB on-disk cache (`AppNavigation.configurePipeline`). Chapter/trickplay/
/// artwork fetches no longer re-download on every playback session.
///
/// Uses the **data** API (`ImagePipeline.data(for:)`), never `image(for:)`, so
/// nothing is decoded into Nuke's in-memory `ImageCache`: callers want the raw
/// bytes (chapter JPEG for `AVMetadataItem`) or own their own decoded-image
/// cache (TrickplayController's cost-bounded `NSCache` holds the ~23 MB sheets).
/// Disk cache is the win.
///
/// Returns `nil` on any failure. Nuke's `DataLoader` already fails non-2xx
/// responses (it throws `statusCodeUnacceptable`) and never yields empty data,
/// so a non-nil `Data` here means a successful 2xx (or disk-cached) fetch — the
/// callers' former `statusCode`/`isEmpty` checks are subsumed. On a disk-cache
/// hit Nuke returns no `URLResponse`, which is why the contract is `Data?`
/// rather than the old `(Data, HTTPURLResponse)?`.
///
/// Cache-key note: Nuke keys on the URL (the Authorization header is not part of
/// the key). Chapter/artwork URLs carry no token; trickplay URLs already embed
/// `api_key` via `VLCStreamPresenter.authedURL(_:token:)` — the key stays stable
/// per item, no behavior change.
enum AuthenticatedImageFetch {
    nonisolated static func data(from url: URL, token: String?) async -> Data? {
        var request = URLRequest(url: url)
        if let token, !token.isEmpty {
            request.setValue("MediaBrowser Token=\(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, _) = try? await ImagePipeline.shared.data(for: ImageRequest(urlRequest: request)),
              !data.isEmpty else { return nil }
        return data
    }
}
