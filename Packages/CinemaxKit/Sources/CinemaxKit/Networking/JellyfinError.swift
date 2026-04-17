import Foundation

/// Domain errors surfaced by `JellyfinAPIClient`. Conforms to `LocalizedError` so that
/// `error.localizedDescription` is meaningful when surfaced in the UI.
public enum JellyfinError: LocalizedError, Sendable {
    case notConnected
    case authenticationFailed
    case invalidURL
    case playbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:            "Not connected to a server"
        case .authenticationFailed:    "Authentication failed"
        case .invalidURL:              "Invalid server URL"
        case .playbackFailed(let reason): "Playback failed: \(reason)"
        }
    }
}
