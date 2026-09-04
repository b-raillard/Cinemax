import Foundation
import JellyfinAPI

// MARK: - SyncPlay ("Watch Together") models
//
// Value types describing Jellyfin's SyncPlay surface. All are `Sendable` so
// they cross the app↔actor boundary freely (the socket receive loop runs
// nonisolated and hands parsed values to a `@MainActor` controller). Kept
// deliberately narrow to the v1 feature scope: list / join / create groups and
// broadcast play / pause / seek across participants.

/// A SyncPlay group (Jellyfin `GroupInfoDto`). `participants` are display
/// usernames, not user ids.
///
/// Reached by two paths that must both keep working:
/// - **REST** (`GET /SyncPlay/List`) hands back the SDK's typed `GroupInfoDto`,
///   mapped by `init(dto:)`.
/// - **Socket** (`GroupJoined` / `GroupLeft` updates) carries an untyped JSON
///   blob that `JellyfinSocket` decodes directly into this type — which is why
///   the hand-written `Decodable` conformance below survived the migration of
///   the REST layer onto the SDK. Do not drop it.
public struct SyncPlayGroup: Sendable, Identifiable, Decodable, Equatable {
    public let id: String
    public let name: String
    public let participants: [String]
    public let state: String?
    public let lastUpdatedAt: Date?

    public init(id: String, name: String, participants: [String], state: String? = nil, lastUpdatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.participants = participants
        self.state = state
        self.lastUpdatedAt = lastUpdatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case groupId = "GroupId"
        case groupName = "GroupName"
        case participants = "Participants"
        case state = "State"
        case lastUpdatedAt = "LastUpdatedAt"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .groupId) ?? ""
        self.name = try c.decodeIfPresent(String.self, forKey: .groupName) ?? ""
        self.participants = try c.decodeIfPresent([String].self, forKey: .participants) ?? []
        self.state = try c.decodeIfPresent(String.self, forKey: .state)
        if let raw = try c.decodeIfPresent(String.self, forKey: .lastUpdatedAt) {
            self.lastUpdatedAt = SyncPlayDateParser.date(from: raw)
        } else {
            self.lastUpdatedAt = nil
        }
    }

    /// Maps the SDK's `GroupInfoDto` onto this app-facing value. Every field is
    /// optional in the generated DTO, so the same "absent ⇒ empty" defaults the
    /// JSON path applies are repeated here — a group with no id is still
    /// rendered (and refused at join time) rather than silently dropped.
    public init(dto: GroupInfoDto) {
        self.id = dto.groupID ?? ""
        self.name = dto.groupName ?? ""
        self.participants = dto.participants ?? []
        self.state = dto.state?.rawValue
        self.lastUpdatedAt = dto.lastUpdatedAt
    }
}

/// A realtime transport command pushed by the server over the socket
/// (`SyncPlayCommand` message → Jellyfin `SendCommand`). Every participant —
/// including the one who triggered it — receives the echo; applying that echo
/// (not the local tap) is what keeps the group in lockstep.
public struct SyncPlayCommand: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case unpause = "Unpause"
        case pause = "Pause"
        case seek = "Seek"
        case stop = "Stop"
    }

    public let command: Kind
    /// Target position in Jellyfin ticks (1 tick = 100 ns). Present on
    /// Unpause / Pause / Seek; the client seeks here before/after applying.
    public let positionTicks: Int?
    /// Server UTC instant the command should take effect. The client converts
    /// it to its own clock via the estimated offset and schedules accordingly.
    public let when: Date?
    public let emittedAt: Date?
    public let playlistItemId: String?

    public init(command: Kind, positionTicks: Int?, when: Date?, emittedAt: Date?, playlistItemId: String?) {
        self.command = command
        self.positionTicks = positionTicks
        self.when = when
        self.emittedAt = emittedAt
        self.playlistItemId = playlistItemId
    }
}

/// A group-membership / state change pushed over the socket
/// (`SyncPlayGroupUpdate` → Jellyfin `GroupUpdate`). The nested `Data` is
/// polymorphic (a `GroupInfoDto`, a username string, or a state blob depending
/// on `Type`); the socket parser flattens whatever it can into these fields.
public struct SyncPlayGroupUpdate: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case groupJoined = "GroupJoined"
        case groupLeft = "GroupLeft"
        case userJoined = "UserJoined"
        case userLeft = "UserLeft"
        case stateUpdate = "StateUpdate"
        case playQueue = "PlayQueue"
        case notInGroup = "NotInGroup"
        case groupDoesNotExist = "GroupDoesNotExist"
        /// The group is watching something this account cannot see. A real
        /// outcome on a server with per-user library access, and one that used
        /// to reach the user as nothing at all.
        case libraryAccessDenied = "LibraryAccessDenied"
    }

    public let type: Kind?
    public let rawType: String
    public let groupId: String?
    /// Present for `GroupJoined` (`Data` is a full group info blob).
    public let group: SyncPlayGroup?
    /// Present for `UserJoined` / `UserLeft` (`Data` is a bare username string).
    public let userName: String?
    /// Present for `StateUpdate` (`Data.State`).
    public let state: String?
    /// Present for `PlayQueue` — **what the group is watching**, as Jellyfin's
    /// `PlayQueueUpdate.Playlist` (an array of `SyncPlayQueueItem`, flattened to
    /// its `ItemId`s here).
    ///
    /// Jellyfin syncs the transport and the queue over the same socket, but only
    /// the transport was ever read, so a participant who joined a group got a
    /// synchronised play/pause/seek and was never told which item to apply it
    /// to. That is the whole of defect n°1: the information was always arriving
    /// and the parser dropped it on the floor.
    public let playlist: [String]
    /// Index into `playlist` of the item actually playing.
    public let playingItemIndex: Int?
    /// Where in that item the group stands, in Jellyfin ticks.
    public let startPositionTicks: Int?
    /// Whether the group is playing rather than paused, at the moment of the update.
    public let isPlaying: Bool?

    /// The one item a joiner should open. `playingItemIndex` is authoritative;
    /// a queue with no valid index falls back to its first entry rather than to
    /// nothing, since an empty answer here means a black screen for the user.
    public var playingItemId: String? {
        if let i = playingItemIndex, playlist.indices.contains(i) { return playlist[i] }
        return playlist.first
    }

    public init(
        type: Kind?,
        rawType: String,
        groupId: String?,
        group: SyncPlayGroup?,
        userName: String?,
        state: String?,
        playlist: [String] = [],
        playingItemIndex: Int? = nil,
        startPositionTicks: Int? = nil,
        isPlaying: Bool? = nil
    ) {
        self.type = type
        self.rawType = rawType
        self.groupId = groupId
        self.group = group
        self.userName = userName
        self.state = state
        self.playlist = playlist
        self.playingItemIndex = playingItemIndex
        self.startPositionTicks = startPositionTicks
        self.isPlaying = isPlaying
    }
}

/// The group's transport state (`GroupStateType`).
///
/// **This is a GROUP state, never a per-participant one.** Jellyfin's
/// `GroupStateUpdate` is `{ State, Reason }` — it says the group is waiting, it
/// does not say who for. Any UI that names the participant it is waiting on
/// would be inventing that name.
public enum SyncPlayGroupState: String, Sendable, Equatable {
    case idle = "Idle"
    case waiting = "Waiting"
    case paused = "Paused"
    case playing = "Playing"
}

/// The two server timestamps returned by `GET /GetUtcTime`, used to estimate
/// the client↔server clock offset (NTP-style round-trip averaging).
public struct SyncPlayUtcTime: Sendable {
    public let requestReceptionTime: Date
    public let responseTransmissionTime: Date

    public init(requestReceptionTime: Date, responseTransmissionTime: Date) {
        self.requestReceptionTime = requestReceptionTime
        self.responseTransmissionTime = responseTransmissionTime
    }
}

// MARK: - Date parsing

/// Shared ISO-8601 parsing for SyncPlay payloads. Jellyfin emits UTC timestamps
/// with fractional seconds but the precision varies, so we fall back to the
/// no-fraction parser. Uses `Date.ISO8601FormatStyle` — a `Sendable` value type
/// — so the statics are provably race-free across the socket actor and the
/// URLSession decode paths that hit this concurrently (a shared
/// `ISO8601DateFormatter` here would need `nonisolated(unsafe)`).
enum SyncPlayDateParser {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let noFraction = Date.ISO8601FormatStyle()

    static func date(from raw: String) -> Date? {
        if let d = try? withFraction.parse(raw) { return d }
        if let d = try? noFraction.parse(raw) { return d }
        // Last resort: Jellyfin can emit 7-digit ("tick") fractions that the
        // parser rejects — truncate to milliseconds and retry.
        if let dot = raw.firstIndex(of: ".") {
            let tail = raw[raw.index(after: dot)...]
            let digits = tail.prefix { $0.isNumber }
            let suffix = tail[tail.index(tail.startIndex, offsetBy: digits.count)...]
            let ms = digits.prefix(3)
            let normalized = "\(raw[..<dot]).\(ms)\(suffix)"
            return try? withFraction.parse(normalized)
        }
        return nil
    }

    static func string(from date: Date) -> String {
        withFraction.format(date)
    }
}
