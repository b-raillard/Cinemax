import Foundation
import JellyfinAPI

/// Something this user is watching RIGHT NOW on another of their devices — the
/// model behind « Reprendre ici » (spec `2026-10-24-resume-here-design.md`).
/// A `Sendable` projection of `SessionInfoDto`, like `RemotePlayTarget`.
public struct ElsewherePlayback: Sendable, Equatable {
    /// Jellyfin session id — what `Stop` and the message address.
    public let sessionId: String
    /// The item open over there (an episode id for a series).
    public let itemId: String
    /// May be empty: the view localizes the fallback.
    public let deviceName: String
    public let isPaused: Bool
    public let positionTicks: Int?
    /// Only a session that declared remote control can be told to stop.
    public let canStop: Bool
    /// When the source last reported `positionTicks` — what lets a PLAYING
    /// source's position be carried forward to the moment of the tap.
    public let checkIn: Date?

    public init(sessionId: String, itemId: String, deviceName: String,
                isPaused: Bool, positionTicks: Int?, canStop: Bool, checkIn: Date? = nil) {
        self.sessionId = sessionId
        self.itemId = itemId
        self.deviceName = deviceName
        self.isPaused = isPaused
        self.positionTicks = positionTicks
        self.canStop = canStop
        self.checkIn = checkIn
    }

    /// The position the source REPORTED, in seconds; `nil` = nothing reported.
    public var startSeconds: Double? {
        guard let positionTicks, positionTicks > 0 else { return nil }
        return Double(positionTicks / 10_000_000)
    }

    /// How old a playing source's report may be and still be carried forward:
    /// the source reports every ~10 s and the probe behind the card can be up
    /// to ~20 s old (one poll). Older, the source has stopped reporting at its
    /// normal pace (stopped, sought, lost its network…), so the last reported
    /// point is used as is (user, 2026-10-26).
    public static let carryForwardWindow: TimeInterval = 30

    /// Where « Reprendre ici » starts when tapped at `now`. Paused: the
    /// reported position. Playing with a report at most `carryForwardWindow`
    /// old: the reported position plus the time since that report — without
    /// it the viewer went back up to ~30 s. Older report, or no check-in date:
    /// the reported position as is.
    public func startSeconds(at now: Date) -> Double? {
        guard let base = startSeconds else { return nil }
        guard !isPaused, let checkIn else { return base }
        let elapsed = max(0, now.timeIntervalSince(checkIn))
        guard elapsed <= Self.carryForwardWindow else { return base }
        return (base + elapsed).rounded(.down)
    }

    /// A check-in older than this is a session that stopped reporting.
    public static let staleAfter: TimeInterval = 600

    /// Keyed by item id. Pure: these rules decide what the user is told is
    /// playing on their TV, so they are locked by tests.
    ///
    /// **RULE — own user, re-checked here** (same defense in depth as
    /// `RemotePlayTarget.resolve`: a server that ignored `controllableByUserId`
    /// must not show — nor let us stop — someone else's film). A session with
    /// no `userID` is dropped. Our own device is never « elsewhere ».
    /// A `lastPlaybackCheckIn` older than `staleAfter` is stale; a missing one,
    /// or .NET's `DateTime.MinValue` (before 2001), is unknown and kept — the
    /// query's `activeWithinSeconds` already bounds it. Two devices on one
    /// item: the latest check-in wins, then the session id (total order).
    public static func resolve(
        sessions: [SessionInfoDto],
        currentUserId: String,
        excludingDeviceId: String?,
        now: Date = Date()
    ) -> [String: Self] {
        var best: [String: (entry: Self, checkIn: Date)] = [:]
        for session in sessions {
            guard let sessionId = session.id, !sessionId.isEmpty,
                  session.userID == currentUserId,
                  let itemId = session.nowPlayingItem?.id, !itemId.isEmpty else { continue }
            if let excludingDeviceId, session.deviceID == excludingDeviceId { continue }
            let checkIn = session.lastPlaybackCheckIn.flatMap { $0 > Date(timeIntervalSinceReferenceDate: 0) ? $0 : nil }
            if let checkIn, now.timeIntervalSince(checkIn) > staleAfter { continue }
            let entry = Self(
                sessionId: sessionId,
                itemId: itemId,
                deviceName: session.deviceName ?? "",
                isPaused: session.playState?.isPaused ?? false,
                positionTicks: session.playState?.positionTicks,
                canStop: session.isSupportsRemoteControl == true,
                checkIn: checkIn
            )
            let rank = checkIn ?? .distantPast
            if let current = best[itemId] {
                let newer = rank > current.checkIn
                    || (rank == current.checkIn && sessionId < current.entry.sessionId)
                guard newer else { continue }
            }
            best[itemId] = (entry, rank)
        }
        return best.mapValues(\.entry)
    }
}
