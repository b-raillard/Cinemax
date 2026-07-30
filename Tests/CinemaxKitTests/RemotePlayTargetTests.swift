import Testing
import Foundation
@preconcurrency import JellyfinAPI
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
