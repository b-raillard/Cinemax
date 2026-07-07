import Foundation

// MARK: - SyncPlay ("Watch Together") models
//
// Value types describing Jellyfin's SyncPlay surface. All are `Sendable` so
// they cross the app↔actor boundary freely (the socket receive loop runs
// nonisolated and hands parsed values to a `@MainActor` controller). Kept
// deliberately narrow to the v1 feature scope: list / join / create groups and
// broadcast play / pause / seek across participants.

/// A SyncPlay group as returned by `GET /SyncPlay/List` (Jellyfin
/// `GroupInfoDto`). `participants` are display usernames, not user ids.
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

    public init(type: Kind?, rawType: String, groupId: String?, group: SyncPlayGroup?, userName: String?, state: String?) {
        self.type = type
        self.rawType = rawType
        self.groupId = groupId
        self.group = group
        self.userName = userName
        self.state = state
    }
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

/// A parsed frame delivered by `SyncPlaySocket.messages`.
public enum SyncPlaySocketMessage: Sendable {
    case command(SyncPlayCommand)
    case groupUpdate(SyncPlayGroupUpdate)
}

// MARK: - Date parsing

/// Shared ISO-8601 parsing for SyncPlay payloads. Jellyfin emits UTC timestamps
/// with fractional seconds (`.withFractionalSeconds`) but the precision varies,
/// so we fall back to the no-fraction parser. The formatters are read-only after
/// construction — safe to share as immutable statics.
enum SyncPlayDateParser {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let noFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(from raw: String) -> Date? {
        if let d = withFraction.date(from: raw) { return d }
        if let d = noFraction.date(from: raw) { return d }
        // Last resort: Jellyfin can emit 7-digit ("tick") fractions that the
        // formatter rejects — truncate to milliseconds and retry.
        if let dot = raw.firstIndex(of: ".") {
            let tail = raw[raw.index(after: dot)...]
            let digits = tail.prefix { $0.isNumber }
            let suffix = tail[tail.index(tail.startIndex, offsetBy: digits.count)...]
            let ms = digits.prefix(3)
            let normalized = "\(raw[..<dot]).\(ms)\(suffix)"
            return withFraction.date(from: normalized)
        }
        return nil
    }

    static func string(from date: Date) -> String {
        withFraction.string(from: date)
    }
}
