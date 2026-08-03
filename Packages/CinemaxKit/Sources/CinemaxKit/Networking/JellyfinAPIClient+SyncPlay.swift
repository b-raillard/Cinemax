import Foundation
import Get
import JellyfinAPI

// MARK: - SyncPlay ("Watch Together")
//
// Routed through the SDK's generated `Paths.syncPlay*` operations. This file
// used to hand-build every request over a private `URLSession` on the premise
// that "the SDK doesn't model the SyncPlay endpoints" — that premise was wrong
// for jellyfin-sdk-swift 0.6.0, which ships all of them (`SyncPlayGetGroups`,
// `SyncPlayCreateGroup`, `SyncPlayJoinGroup`, `SyncPlayLeaveGroup`,
// `SyncPlayPause/Unpause/Stop/Seek/Ready/Buffering/SetNewQueue`) plus
// `Paths.getUtcTime` with a typed `UtcTimeResponse`.
//
// The two properties the hand-built path existed to guarantee are preserved by
// the SDK client itself:
//   - **No response caching.** `GET /SyncPlay/List` and `GET /GetUtcTime` are
//     authenticated, and a cached `GetUtcTime` would silently poison the
//     clock-offset math. Every `JellyfinClient` we hand out is built with
//     `fastFailSessionConfiguration`, whose `urlCache = nil` makes an HTTP
//     cache entry structurally impossible.
//   - **401 handling.** Each call keeps the `notifyIfUnauthorized` + rethrow
//     discipline of every other session-scoped method, so a revoked token
//     drives the shared session-expiry flow.
//
// One property is deliberately NOT preserved: the old private session set a
// 15 s per-request leash ("SyncPlay commands are latency-sensitive"), where the
// shared client uses 30 s idle / 60 s total. `Get` has no per-request timeout
// hook, and standing up a second session just for that would re-introduce the
// duplication this migration removes. The practical effect is bounded — a dead
// server stalls a transport action for 30 s instead of 15 s before surfacing.
//
// `makeSyncPlaySocket()` stays hand-built: the SDK models REST only, and the
// realtime `/socket` endpoint has no generated counterpart.

extension JellyfinAPIClient: SyncPlayAPI {
    public func syncPlayListGroups() async throws -> [SyncPlayGroup] {
        try await syncPlaySend(Paths.syncPlayGetGroups).map(SyncPlayGroup.init(dto:))
    }

    public func syncPlayNewGroup(name: String) async throws {
        // The response carries the authoritative `GroupInfoDto`, but it is
        // deliberately discarded: `SyncPlayController` brings the socket up
        // FIRST and treats the server's `GroupJoined` echo as the single source
        // of truth for group identity (see the SyncPlay section in CLAUDE.md).
        // Consuming the REST result here would create a second, racing writer.
        _ = try await syncPlaySend(Paths.syncPlayCreateGroup(NewGroupRequestDto(groupName: name)))
    }

    public func syncPlayJoinGroup(groupId: String) async throws {
        try await syncPlaySend(Paths.syncPlayJoinGroup(JoinGroupRequestDto(groupID: groupId)))
    }

    public func syncPlayLeaveGroup() async throws {
        try await syncPlaySend(Paths.syncPlayLeaveGroup)
    }

    public func syncPlayPause() async throws {
        try await syncPlaySend(Paths.syncPlayPause)
    }

    public func syncPlayUnpause() async throws {
        try await syncPlaySend(Paths.syncPlayUnpause)
    }

    public func syncPlayStop() async throws {
        try await syncPlaySend(Paths.syncPlayStop)
    }

    public func syncPlaySeek(positionTicks: Int) async throws {
        try await syncPlaySend(Paths.syncPlaySeek(SeekRequestDto(positionTicks: positionTicks)))
    }

    public func syncPlayReady(positionTicks: Int, isPlaying: Bool, playlistItemId: String?) async throws {
        try await syncPlaySend(Paths.syncPlayReady(ReadyRequestDto(
            isPlaying: isPlaying,
            playlistItemID: playlistItemId,
            positionTicks: positionTicks,
            when: Date()
        )))
    }

    public func syncPlayBuffering(positionTicks: Int, isPlaying: Bool, playlistItemId: String?) async throws {
        try await syncPlaySend(Paths.syncPlayBuffering(BufferRequestDto(
            isPlaying: isPlaying,
            playlistItemID: playlistItemId,
            positionTicks: positionTicks,
            when: Date()
        )))
    }

    public func syncPlaySetNewQueue(itemIds: [String], startPositionTicks: Int) async throws {
        // v1: a single-item queue built by the group creator when they start
        // playback. The hand-built body also sent `Mode: "Play"`; `PlayRequestDto`
        // has no such field in the official schema, and Jellyfin defaults the
        // mode server-side — so the key was decorative and is dropped here.
        try await syncPlaySend(Paths.syncPlaySetNewQueue(PlayRequestDto(
            playingItemPosition: 0,
            playingQueue: itemIds,
            startPositionTicks: startPositionTicks
        )))
    }

    public func syncPlayGetUtcTime() async throws -> SyncPlayUtcTime {
        let response = try await syncPlaySend(Paths.getUtcTime)
        guard let received = response.requestReceptionTime,
              let transmitted = response.responseTransmissionTime else {
            throw JellyfinError.playbackFailed("Invalid GetUtcTime response")
        }
        return SyncPlayUtcTime(requestReceptionTime: received, responseTransmissionTime: transmitted)
    }

    public func makeSyncPlaySocket() -> SyncPlaySocket? {
        guard let client = getClient(),
              let serverURL = getServerURL(),
              let token = client.accessToken else { return nil }
        guard var comps = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.setEndpointPath("/socket", preservingBasePathOf: serverURL)
        // Derive the WebSocket scheme from the server's, preserving the base
        // path already set above (never assign `path` directly — see
        // URLComponents+ServerPath).
        comps.scheme = (serverURL.scheme?.lowercased() == "https") ? "wss" : "ws"
        comps.queryItems = [
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "deviceId", value: deviceID)
        ]
        guard let url = comps.url else { return nil }
        return SyncPlaySocket(url: url)
    }

    // MARK: - Send helpers

    /// Sends a value-returning SyncPlay request, keeping the shared 401
    /// discipline. Two overloads because `Get` types empty-bodied operations as
    /// `Request<Void>` and `Void` is not `Decodable`, so one generic can't cover
    /// both.
    private func syncPlaySend<T: Decodable>(_ request: Request<T>) async throws -> T {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        do {
            return try await client.send(request).value
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    private func syncPlaySend(_ request: Request<Void>) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        do {
            _ = try await client.send(request)
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }
}
