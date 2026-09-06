import Foundation

// MARK: - Remote control, receiving side
//
// Value types for the commands another Jellyfin session sends *to this device*.
// The mirror image of `RemotePlayTarget` / `playOnSession`, which cover the
// sending side.
//
// Deliberately narrow: only the two messages this app actually honors are
// modelled. Jellyfin's socket also carries `Playstate` (pause / unpause / seek /
// stop) and the full `GeneralCommand` vocabulary, and modelling those without
// executing them would be worse than ignoring them — a sender would render
// transport controls that silently do nothing. See the capability declaration in
// `JellyfinAPIClient+RemoteControl.publishCapabilities` for the matching promise.

/// A `Play` message: another session asking this device to start something.
public struct RemotePlayRequest: Sendable, Equatable {
    /// Items to play, server order preserved. This app honors the first only —
    /// it has no playback queue (see the CLAUDE.md note on `EpisodeNavigator`
    /// being the single next/prev authority).
    public let itemIds: [String]
    /// Raw `PlayCommand` (`PlayNow`, `PlayNext`, `PlayLast`, …). Kept as the raw
    /// string so an unknown future value is *ignored* rather than mis-mapped
    /// onto `PlayNow`.
    public let playCommand: String
    public let startPositionTicks: Int?
    public let mediaSourceId: String?

    public init(itemIds: [String], playCommand: String, startPositionTicks: Int?, mediaSourceId: String?) {
        self.itemIds = itemIds
        self.playCommand = playCommand
        self.startPositionTicks = startPositionTicks
        self.mediaSourceId = mediaSourceId
    }

    /// Whether this is the "start playing now" variant — the only one a
    /// queue-less client can honor faithfully.
    public var isPlayNow: Bool { playCommand.caseInsensitiveCompare("PlayNow") == .orderedSame }
}

/// A `GeneralCommand` of name `DisplayMessage` — a short text another session
/// asks this device to show. Rendered as a toast.
public struct RemoteDisplayMessage: Sendable, Equatable {
    public let header: String?
    public let text: String

    public init(header: String?, text: String) {
        self.header = header
        self.text = text
    }
}

