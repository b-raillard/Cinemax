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
    /// The server refused a self-service credential change — in practice, a
    /// wrong current password.
    ///
    /// Distinct from `.unauthorized`, which means the SESSION is invalid and
    /// feeds the expiry coordinator. Conflating the two would sign a user out
    /// for mistyping their own password.
    case invalidCredentials
    /// A record the client holds is missing the id an operation addresses it
    /// by — a playlist entry with no `playlistItemID`, say. Refusing beats
    /// acting on the wrong occurrence.
    case malformedRecord

    public var errorDescription: String? {
        switch self {
        case .notConnected:            "Not connected to a server"
        case .authenticationFailed:    "Authentication failed"
        case .invalidURL:              "Invalid server URL"
        case .playbackFailed(let reason): "Playback failed: \(reason)"
        case .unauthorized:            "Session expired"
        case .invalidCredentials:      "The current password is incorrect"
        case .malformedRecord:         "This entry is missing the identifier the server needs"
        }
    }
}
