import AVFoundation

/// Intercepts HLS requests via a `cinemax-https://` custom scheme:
/// 1. Strips `#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS` from playlists (in-band CEA-608/708 CC)
/// 2. Keeps `TYPE=SUBTITLES` so Jellyfin's WebVTT renditions appear in AVKit's native menu
/// 3. Strips ASS/SSA override tags (`{\i1}`, `{\b}`, `{\an8}`, etc.) from WebVTT segments
///    — Jellyfin's ASS→WebVTT conversion leaves these raw tags in the text
/// 4. Rewrites relative segment URIs to absolute `https://` (except `.vtt` segments,
///    which stay relative so they route through this delegate for tag stripping)
///
/// Key implementation note: `AVAssetResourceLoadingContentInformationRequest.contentType`
/// requires a **UTI**, not a MIME type. Passing the raw MIME string causes AVFoundation
/// to reject the response. Use `"public.m3u-playlist"` for M3U8 content.
final class HLSManifestLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

    static let schemePrefix = "cinemax-"
    let delegateQueue = DispatchQueue(label: "com.cinemax.manifestloader", qos: .userInitiated)

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let customURL = loadingRequest.request.url,
              let realURL = Self.realURL(from: customURL) else { return false }

        URLSession.shared.dataTask(with: URLRequest(url: realURL)) { data, response, error in
            guard let data, error == nil else {
                loadingRequest.finishLoading(with: error ?? URLError(.badServerResponse))
                return
            }
            let mime = (response as? HTTPURLResponse)?.mimeType ?? ""
            let isPlaylist = mime.contains("mpegurl") || mime.contains("m3u") || realURL.pathExtension == "m3u8"

            let isVTT = realURL.pathExtension.lowercased() == "vtt"
                || mime.contains("text/vtt")

            var responseData = data
            if isPlaylist, let text = String(data: data, encoding: .utf8) {
                responseData = Self.filterManifest(text, baseURL: realURL.deletingLastPathComponent())
                    .data(using: .utf8) ?? data
            } else if isVTT, let text = String(data: data, encoding: .utf8) {
                responseData = Self.stripASSTags(text).data(using: .utf8) ?? data
            }

            if let info = loadingRequest.contentInformationRequest {
                // contentType MUST be a UTI, not a MIME type.
                // Setting raw MIME strings causes "resource unavailable" on iOS
                // and -12881 on tvOS. Use proper UTIs for known types;
                // skip contentType for segments to let AVFoundation infer it.
                if isPlaylist {
                    info.contentType = "public.m3u-playlist"
                } else if isVTT {
                    info.contentType = "org.w3.webvtt"
                }
                info.contentLength = Int64(responseData.count)
                info.isByteRangeAccessSupported = false
            }
            loadingRequest.dataRequest?.respond(with: responseData)
            loadingRequest.finishLoading()
        }.resume()

        return true
    }

    static func realURL(from url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = c.scheme, scheme.hasPrefix(schemePrefix) else { return nil }
        c.scheme = String(scheme.dropFirst(schemePrefix.count))
        return c.url
    }

    static func filterManifest(_ manifest: String, baseURL: URL) -> String {
        manifest
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                // Only strip CLOSED-CAPTIONS (in-band CEA-608/708 from H.264 NAL units).
                // Keep TYPE=SUBTITLES — Jellyfin's WebVTT renditions appear natively in AVKit's menu.
                if t.hasPrefix("#EXT-X-MEDIA:") && t.contains("TYPE=CLOSED-CAPTIONS") {
                    return nil
                }
                // Bare URI lines (not tags, not empty)
                if !t.isEmpty, !t.hasPrefix("#") {
                    let isVTT = t.contains(".vtt")
                    if isVTT {
                        // Route VTT URLs through the delegate for ASS tag stripping.
                        // Absolute URLs need scheme rewrite; relative URLs stay as-is
                        // (they resolve against the custom-scheme base automatically).
                        if t.hasPrefix("https://") {
                            return schemePrefix + t
                        } else if t.hasPrefix("http://") {
                            return schemePrefix + t
                        }
                        return line
                    }
                    // Non-VTT relative URIs → make absolute so they bypass the delegate
                    if !t.hasPrefix("http://"), !t.hasPrefix("https://") {
                        return URL(string: t, relativeTo: baseURL)?.absoluteString ?? line
                    }
                }
                return line
            }
            .joined(separator: "\n")
    }

    /// Strips ASS/SSA artifacts from WebVTT text.
    /// Jellyfin's ASS→WebVTT conversion leaves:
    ///  - Override tags: `{\i1}`, `{\b0}`, `{\an8}`, `{\q2}`, `{\pos(x,y)}`
    ///  - Inline comments: `{TLC note: ...}`, `{I can't believe...}`
    /// This regex removes ALL `{...}` sequences from cue text lines,
    /// but preserves WebVTT structure lines (timestamps, WEBVTT header, NOTE blocks).
    static func stripASSTags(_ vtt: String) -> String {
        vtt.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
    }
}
