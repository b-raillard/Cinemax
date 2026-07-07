import Foundation
import JellyfinAPI

// MARK: - SyncPlay ("Watch Together")
//
// The Jellyfin SDK doesn't model the SyncPlay endpoints, so we hand-build the
// requests via `URLSession` — the same pattern as `rawPostPlaybackInfo`
// (`+Playback.swift`): the `MediaBrowser` auth header assembled from the
// client's configuration, `setEndpointPath` to preserve a reverse-proxy base
// path, a bounded timeout, and `notifyIfUnauthorized` on failure so a revoked
// token drives the shared session-expiry flow like every other call site.

extension JellyfinAPIClient: SyncPlayAPI {
    public func syncPlayListGroups() async throws -> [SyncPlayGroup] {
        let data = try await syncPlayRequest(path: "/SyncPlay/List", method: "GET")
        return (try? JSONDecoder().decode([SyncPlayGroup].self, from: data)) ?? []
    }

    public func syncPlayNewGroup(name: String) async throws {
        _ = try await syncPlayRequest(path: "/SyncPlay/New", method: "POST", jsonBody: ["GroupName": name])
    }

    public func syncPlayJoinGroup(groupId: String) async throws {
        _ = try await syncPlayRequest(path: "/SyncPlay/Join", method: "POST", jsonBody: ["GroupId": groupId])
    }

    public func syncPlayLeaveGroup() async throws {
        _ = try await syncPlayRequest(path: "/SyncPlay/Leave", method: "POST")
    }

    public func syncPlayPause() async throws {
        _ = try await syncPlayRequest(path: "/SyncPlay/Pause", method: "POST")
    }

    public func syncPlayUnpause() async throws {
        _ = try await syncPlayRequest(path: "/SyncPlay/Unpause", method: "POST")
    }

    public func syncPlayStop() async throws {
        _ = try await syncPlayRequest(path: "/SyncPlay/Stop", method: "POST")
    }

    public func syncPlaySeek(positionTicks: Int) async throws {
        _ = try await syncPlayRequest(path: "/SyncPlay/Seek", method: "POST", jsonBody: ["PositionTicks": positionTicks])
    }

    public func syncPlayReady(positionTicks: Int, isPlaying: Bool, playlistItemId: String?) async throws {
        _ = try await syncPlayRequest(
            path: "/SyncPlay/Ready", method: "POST",
            jsonBody: Self.readyBody(positionTicks: positionTicks, isPlaying: isPlaying, playlistItemId: playlistItemId)
        )
    }

    public func syncPlayBuffering(positionTicks: Int, isPlaying: Bool, playlistItemId: String?) async throws {
        _ = try await syncPlayRequest(
            path: "/SyncPlay/Buffering", method: "POST",
            jsonBody: Self.readyBody(positionTicks: positionTicks, isPlaying: isPlaying, playlistItemId: playlistItemId)
        )
    }

    public func syncPlaySetNewQueue(itemIds: [String], startPositionTicks: Int) async throws {
        // v1: a single-item queue built by the group creator when they start
        // playback. `Mode: "Play"` matches the web client's `PlayRequestDto`;
        // Jellyfin ignores unknown JSON keys so it's harmless on older servers.
        let body: [String: Any] = [
            "PlayingQueue": itemIds,
            "PlayingItemPosition": 0,
            "StartPositionTicks": startPositionTicks,
            "Mode": "Play"
        ]
        _ = try await syncPlayRequest(path: "/SyncPlay/SetNewQueue", method: "POST", jsonBody: body)
    }

    public func syncPlayGetUtcTime() async throws -> SyncPlayUtcTime {
        let data = try await syncPlayRequest(path: "/GetUtcTime", method: "GET")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recv = (obj["RequestReceptionTime"] as? String).flatMap(SyncPlayDateParser.date(from:)),
              let trans = (obj["ResponseTransmissionTime"] as? String).flatMap(SyncPlayDateParser.date(from:)) else {
            throw JellyfinError.playbackFailed("Invalid GetUtcTime response")
        }
        return SyncPlayUtcTime(requestReceptionTime: recv, responseTransmissionTime: trans)
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

    // MARK: - Raw request plumbing

    /// Issues a hand-built SyncPlay request and returns the response body.
    /// Mirrors `rawPostPlaybackInfo`'s auth + validation discipline.
    @discardableResult
    private func syncPlayRequest(path: String, method: String, jsonBody: [String: Any]? = nil) async throws -> Data {
        guard let client = getClient(), let serverURL = getServerURL() else {
            throw JellyfinError.notConnected
        }
        guard var comps = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw JellyfinError.invalidURL
        }
        comps.setEndpointPath(path, preservingBasePathOf: serverURL)
        guard let url = comps.url else { throw JellyfinError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.authorizationHeader(for: client), forHTTPHeaderField: "Authorization")
        // Short leash: SyncPlay commands are latency-sensitive and small; a
        // dead server should fail the action fast rather than stall the HUD.
        request.timeoutInterval = 15
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.validate(response)
            return data
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// Builds the same `MediaBrowser` auth header the SDK (and
    /// `rawPostPlaybackInfo`) uses.
    private static func authorizationHeader(for client: JellyfinClient) -> String {
        var fields = [
            "DeviceId": client.configuration.deviceID,
            "Device": client.configuration.deviceName,
            "Client": client.configuration.client,
            "Version": client.configuration.version,
        ]
        if let token = client.accessToken { fields["Token"] = token }
        let joined = fields.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        return "MediaBrowser \(joined)"
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.playbackFailed("SyncPlay: no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Surface a structured 401 so `isUnauthorized` matches it precisely.
            if http.statusCode == 401 { throw JellyfinError.unauthorized }
            throw JellyfinError.playbackFailed("SyncPlay returned \(http.statusCode)")
        }
    }

    private static func readyBody(positionTicks: Int, isPlaying: Bool, playlistItemId: String?) -> [String: Any] {
        var body: [String: Any] = [
            "When": SyncPlayDateParser.string(from: Date()),
            "PositionTicks": positionTicks,
            "IsPlaying": isPlaying,
        ]
        if let playlistItemId { body["PlaylistItemId"] = playlistItemId }
        return body
    }
}
