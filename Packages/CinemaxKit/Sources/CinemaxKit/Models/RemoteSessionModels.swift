import Foundation

// MARK: - Remote control, receiving side
//
// Value types for the commands another Jellyfin session sends *to this device*.
// The mirror image of `RemotePlayTarget` / `playOnSession`, which cover the
// sending side.
//
// Deliberately narrow: only the messages this app actually honors are
// modelled — `Play`, `DisplayMessage`, and (since #176) the `Playstate`
// commands the players execute. The rest of the `GeneralCommand` vocabulary is
// ignored, and modelling it without executing it would be worse than ignoring
// it — a sender would render controls that silently do nothing. See the
// capability declaration in `JellyfinAPIClient+RemoteControl.publishCapabilities`
// for the matching promise.

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

/// A `Playstate` message: another session driving THIS device's transport —
/// what the Jellyfin web dashboard's remote bar sends when someone presses
/// pause, drags the scrubber or asks for the next episode.
///
/// Only the commands the players execute are modelled. `Rewind` /
/// `FastForward` are dropped at parse time: a sender that shows them assumes a
/// rate-changing transport this app does not have, and mapping them onto a
/// fixed skip would be a guess.
public struct RemotePlaystateCommand: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case pause = "Pause"
        case unpause = "Unpause"
        case playPause = "PlayPause"
        case seek = "Seek"
        case stop = "Stop"
        case nextTrack = "NextTrack"
        case previousTrack = "PreviousTrack"
    }

    public let kind: Kind
    /// Set on `.seek` only, where it is required — a seek with no usable
    /// target is refused at parse time. Jellyfin ticks: 10 000 per millisecond.
    public let seekPositionTicks: Int?

    public init(kind: Kind, seekPositionTicks: Int? = nil) {
        self.kind = kind
        self.seekPositionTicks = seekPositionTicks
    }
}

