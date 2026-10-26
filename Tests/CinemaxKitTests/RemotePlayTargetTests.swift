import Testing
import Foundation
import JellyfinAPI
import CinemaxKit

/// Minimal builder — `SessionInfoDto` carries ~28 optional fields and the
/// resolver reads six of them. Free function so the `@Suite` stays readable.
private func makeSession(
    id: String? = "s1",
    userId: String? = "user-1",
    deviceId: String? = "device-tv",
    deviceName: String? = "Salon",
    client: String? = "Jellyfin for Apple TV",
    supportsRemoteControl: Bool? = true,
    playableMediaTypes: [MediaType]? = [.video],
    nowPlaying: BaseItemDto? = nil
) -> SessionInfoDto {
    var session = SessionInfoDto()
    session.id = id
    session.userID = userId
    session.deviceID = deviceId
    session.deviceName = deviceName
    session.client = client
    session.isSupportsRemoteControl = supportsRemoteControl
    session.playableMediaTypes = playableMediaTypes
    session.nowPlayingItem = nowPlaying
    return session
}

@Suite("RemotePlayTarget resolution")
struct RemotePlayTargetTests {
    @Test("keeps a controllable video session belonging to the current user")
    func keepsValidSession() {
        let out = RemotePlayTarget.resolve(
            sessions: [makeSession()],
            currentUserId: "user-1",
            excludingDeviceId: "device-phone"
        )
        #expect(out.count == 1)
        #expect(out.first?.id == "s1")
        #expect(out.first?.name == "Salon")
        #expect(out.first?.clientName == "Jellyfin for Apple TV")
        #expect(out.first?.nowPlayingTitle == nil)
    }

    @Test("drops our own device — sending to ourselves is the Play button")
    func dropsOwnDevice() {
        let out = RemotePlayTarget.resolve(
            sessions: [makeSession(deviceId: "device-phone")],
            currentUserId: "user-1",
            excludingDeviceId: "device-phone"
        )
        #expect(out.isEmpty)
    }

    @Test("drops a session belonging to another user even if the server returned it")
    func dropsOtherUser() {
        let out = RemotePlayTarget.resolve(
            sessions: [makeSession(userId: "user-2")],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        #expect(out.isEmpty)
    }

    @Test("drops a session with no user id — it can't be verified")
    func dropsUnknownUser() {
        let out = RemotePlayTarget.resolve(
            sessions: [makeSession(userId: nil)],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        #expect(out.isEmpty)
    }

    @Test("drops a session that doesn't support remote control")
    func dropsNonControllable() {
        let out = RemotePlayTarget.resolve(
            sessions: [
                makeSession(supportsRemoteControl: false),
                makeSession(id: "s2", supportsRemoteControl: nil)
            ],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        #expect(out.isEmpty)
    }

    @Test("drops a session with no id — it can't be addressed")
    func dropsMissingId() {
        let out = RemotePlayTarget.resolve(
            sessions: [makeSession(id: nil), makeSession(id: "")],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        #expect(out.isEmpty)
    }

    @Test("drops an audio-only session but keeps one that reports nothing")
    func videoCapability() {
        let out = RemotePlayTarget.resolve(
            sessions: [
                makeSession(id: "audio", playableMediaTypes: [.audio]),
                makeSession(id: "unknown", playableMediaTypes: nil),
                makeSession(id: "empty", playableMediaTypes: [])
            ],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        #expect(out.map(\.id).sorted() == ["empty", "unknown"])
    }

    @Test("falls back to the client name when the device has none")
    func nameFallback() {
        let out = RemotePlayTarget.resolve(
            sessions: [
                makeSession(deviceName: nil),
                makeSession(id: "s2", deviceId: "d2", deviceName: "", client: nil)
            ],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        #expect(out.first(where: { $0.id == "s1" })?.name == "Jellyfin for Apple TV")
        #expect(out.first(where: { $0.id == "s2" })?.name == "")
    }

    @Test("surfaces what the target is already playing")
    func nowPlaying() {
        var playing = BaseItemDto()
        playing.name = "Dune"
        let out = RemotePlayTarget.resolve(
            sessions: [makeSession(nowPlaying: playing)],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        #expect(out.first?.nowPlayingTitle == "Dune")
    }

    @Test("sorts by device name, diacritic- and case-insensitively, then by id")
    func sorting() {
        let out = RemotePlayTarget.resolve(
            sessions: [
                makeSession(id: "c", deviceId: "d1", deviceName: "Zèbre"),
                makeSession(id: "b", deviceId: "d2", deviceName: "salon"),
                makeSession(id: "a", deviceId: "d3", deviceName: "Salon")
            ],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        // "Salon" == "salon" under the fold, so the session id breaks the tie.
        #expect(out.map(\.id) == ["a", "b", "c"])
    }
}

// MARK: - « Reprendre ici » (spec 2026-10-24)

private func playingSession(
    id: String? = "s-tv",
    userId: String? = "user-1",
    deviceId: String? = "device-tv",
    deviceName: String? = "Apple TV",
    itemId: String? = "movie-1",
    positionTicks: Int? = 25_330_000_000,
    isPaused: Bool? = true,
    checkIn: Date? = Date(timeIntervalSince1970: 2_000_000_000),
    supportsRemoteControl: Bool? = true
) -> SessionInfoDto {
    var session = makeSession(
        id: id, userId: userId, deviceId: deviceId, deviceName: deviceName,
        supportsRemoteControl: supportsRemoteControl,
        nowPlaying: itemId.map { BaseItemDto(id: $0, name: "Sprite Fright") }
    )
    var state = PlayerStateInfo()
    state.positionTicks = positionTicks
    state.isPaused = isPaused
    session.playState = state
    session.lastPlaybackCheckIn = checkIn
    return session
}

@Suite("Lecture en cours ailleurs")
struct ElsewherePlaybackTests {
    let now = Date(timeIntervalSince1970: 2_000_000_060)

    func resolve(_ sessions: [SessionInfoDto]) -> [String: ElsewherePlayback] {
        ElsewherePlayback.resolve(
            sessions: sessions, currentUserId: "user-1",
            excludingDeviceId: "device-phone", now: now
        )
    }

    @Test("my item paused on my Apple TV is keyed by its item id")
    func keepsOwnOtherDevice() {
        let entry = resolve([playingSession()])["movie-1"]
        #expect(entry?.sessionId == "s-tv")
        #expect(entry?.deviceName == "Apple TV")
        #expect(entry?.isPaused == true)
        #expect(entry?.positionTicks == 25_330_000_000)
        #expect(entry?.canStop == true)
    }

    @Test("our own device, another user, no user, no id, nothing playing are dropped")
    func dropsWhatIsNotElsewhere() {
        let out = resolve([
            playingSession(id: "a", deviceId: "device-phone"),
            playingSession(id: "b", userId: "user-2"),
            playingSession(id: "c", userId: nil),
            playingSession(id: nil),
            playingSession(id: "e", itemId: nil)
        ])
        #expect(out.isEmpty)
    }

    @Test("a check-in older than ten minutes is stale; a missing or sentinel one is unknown and kept")
    func staleness() {
        #expect(resolve([playingSession(checkIn: now.addingTimeInterval(-601))]).isEmpty)
        #expect(resolve([playingSession(checkIn: now.addingTimeInterval(-599))]).count == 1)
        #expect(resolve([playingSession(checkIn: nil)]).count == 1)
        // .NET's DateTime.MinValue, as a server that never saw a check-in sends it.
        #expect(resolve([playingSession(checkIn: Date(timeIntervalSinceReferenceDate: -63_113_904_000))]).count == 1)
    }

    @Test("two devices on the same item: the latest check-in wins")
    func latestCheckInWins() {
        let out = resolve([
            playingSession(id: "old", deviceId: "d-ipad", deviceName: "iPad", checkIn: now.addingTimeInterval(-120)),
            playingSession(id: "new", deviceName: "Apple TV", checkIn: now.addingTimeInterval(-5))
        ])
        #expect(out["movie-1"]?.sessionId == "new")
    }

    @Test("a session that cannot be driven is shown but never stopped")
    func cannotStop() {
        #expect(resolve([playingSession(supportsRemoteControl: false)])["movie-1"]?.canStop == false)
    }

    @Test("no device name stays empty, for the view to localize")
    func emptyName() {
        #expect(resolve([playingSession(deviceName: nil)])["movie-1"]?.deviceName == "")
    }

    @Test("start seconds come from the reported position, nil when there is none")
    func startSeconds() {
        #expect(resolve([playingSession()])["movie-1"]?.startSeconds == 2533)
        #expect(resolve([playingSession(positionTicks: nil)])["movie-1"]?.startSeconds == nil)
        #expect(resolve([playingSession(positionTicks: 0)])["movie-1"]?.startSeconds == nil)
    }

    @Test("a PLAYING source is carried forward to the tap while its report is fresh; an old report, or a paused source, is not")
    func carriedForward() throws {
        // Reported 2533 s at `checkIn`, 60 s before `now`.
        let checkIn = now.addingTimeInterval(-60)
        let playing = try #require(resolve([playingSession(isPaused: false, checkIn: checkIn)])["movie-1"])
        #expect(playing.startSeconds(at: checkIn.addingTimeInterval(25)) == 2558)  // normal cadence: + 25 s
        #expect(playing.startSeconds(at: checkIn.addingTimeInterval(30)) == 2563)  // still fresh at the threshold
        #expect(playing.startSeconds(at: checkIn.addingTimeInterval(31)) == 2533)  // older: the last point as is
        #expect(playing.startSeconds(at: now) == 2533)
        #expect(playing.startSeconds(at: checkIn.addingTimeInterval(-5)) == 2533)

        let paused = try #require(resolve([playingSession(isPaused: true, checkIn: checkIn)])["movie-1"])
        #expect(paused.startSeconds(at: now) == 2533)

        let undated = try #require(resolve([playingSession(isPaused: false, checkIn: nil)])["movie-1"])
        #expect(undated.startSeconds(at: now) == 2533)
    }
}
