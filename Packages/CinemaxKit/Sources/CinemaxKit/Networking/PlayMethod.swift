/// Indicates how a media item is being delivered from the Jellyfin server.
public enum PlayMethod: String, Sendable, Hashable, CustomStringConvertible {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
    case transcode = "Transcode"

    public var description: String { rawValue }
}
