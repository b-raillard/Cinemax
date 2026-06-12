import Foundation

/// Domain errors surfaced by `JellyfinAPIClient`. Conforms to `LocalizedError` so that
/// `error.localizedDescription` is meaningful when surfaced in the UI.
public enum JellyfinError: LocalizedError, Sendable {
    case notConnected
    case authenticationFailed
    case invalidURL
    case playbackFailed(String)
    /// A structured HTTP 401 surfaced from a raw (non-`Get`) request path —
    /// notably the raw PlaybackInfo POST. Carrying it as its own case lets
    /// `JellyfinAPIClient.isUnauthorized` match it precisely instead of
    /// string-sniffing a `playbackFailed("… 401")` message.
    case unauthorized

    public var errorDescription: String? {
        switch self {
        case .notConnected:            "Not connected to a server"
        case .authenticationFailed:    "Authentication failed"
        case .invalidURL:              "Invalid server URL"
        case .playbackFailed(let reason): "Playback failed: \(reason)"
        case .unauthorized:            "Session expired"
        }
    }
}
