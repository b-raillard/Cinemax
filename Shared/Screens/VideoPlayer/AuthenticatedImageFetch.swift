import Foundation

/// Shared authenticated GET for Jellyfin image endpoints (chapter thumbnails,
/// trickplay tiles, now-playing artwork). Attaches the `MediaBrowser Token=`
/// Authorization header and returns the raw response so each caller keeps its
/// own status/emptiness check, DEBUG logging, and generation guards.
///
/// Callers that also need the `api_key` query param (the VLC-path image
/// endpoints) apply `VLCStreamPresenter.authedURL(_:token:)` to the URL before
/// calling here — this helper only owns the header + session request.
enum AuthenticatedImageFetch {
    nonisolated static func data(from url: URL, token: String?) async -> (Data, HTTPURLResponse)? {
        var request = URLRequest(url: url)
        if let token, !token.isEmpty {
            request.setValue("MediaBrowser Token=\(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http)
    }
}
