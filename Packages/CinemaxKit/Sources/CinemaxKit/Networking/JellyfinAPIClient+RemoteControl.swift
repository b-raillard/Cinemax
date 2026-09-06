import Foundation
@preconcurrency import JellyfinAPI

// MARK: - Remote control ("Play on…")
//
// The two calls that let this device drive another Jellyfin session. Both are
// plain SDK-routed requests — no hand-built URLs — so the server's base path is
// handled for us (see the `URLComponents+ServerPath` RULE in CLAUDE.md).

// The conformance is declared here rather than in the aggregate list in
// `APIClientProtocol.swift`, matching `JellyfinAPIClient+SyncPlay.swift`: a
// feature slice whose implementation lives in one file declares its own
// conformance there, so adding the slice to `APIClientProtocol` can't leave the
// real client silently non-conforming.
extension JellyfinAPIClient: RemoteControlAPI {
    /// `GET /Sessions?controllableByUserId=…&activeWithinSeconds=300`
    ///
    /// `controllableByUserId` is what makes this callable by a regular user:
    /// the server returns only sessions this account may drive, so the feature
    /// needs none of the elevated rights the unfiltered `getActiveSessions`
    /// implies. The caller still re-filters — see `RemotePlayTarget.resolve`.
    ///
    /// The 5-minute window bounds staleness explicitly rather than trusting the
    /// server's own idea of "active": a device that checked in within five
    /// minutes is realistically still there, and a stale entry costs only a
    /// no-op command the server drops.
    ///
    /// Deliberately uncached: the whole point of a target list is that it
    /// reflects which devices are awake *right now*, and a 10 s TTL would keep
    /// hiding an Apple TV the user just switched on.
    public func getControllableSessions(userId: String) async throws -> [SessionInfoDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetSessionsParameters(
            controllableByUserID: userId,
            activeWithinSeconds: 300
        )
        do {
            let response = try await client.send(Paths.getSessions(parameters: params))
            return response.value
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// `POST /Sessions/{id}/Playing?playCommand=PlayNow`
    ///
    /// One-shot: the target starts pulling the stream from the server itself and
    /// this device is out of the loop from here on.
    public func playOnSession(
        sessionId: String,
        itemIds: [String],
        startPositionTicks: Int? = nil,
        mediaSourceId: String? = nil
    ) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.PlayParameters(
            playCommand: .playNow,
            itemIDs: itemIds,
            startPositionTicks: startPositionTicks,
            mediaSourceID: mediaSourceId
        )
        do {
            _ = try await client.send(Paths.play(sessionID: sessionId, parameters: params))
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    // MARK: - Receiving side

    /// `POST /Sessions/Capabilities/Full`
    ///
    /// Declares what this device can do, which is the **only** thing that sets
    /// `SessionInfoDto.supportsRemoteControl` server-side. Without it a Cinemax
    /// session is filtered out of every picker — including this app's own, since
    /// `RemotePlayTarget.resolve` requires that flag — so "Lire sur…" could
    /// never target Cinemax on the Apple TV, the feature's main use case.
    ///
    /// **No `deviceProfile` is sent, deliberately.** The profile this app plays
    /// with is engine-dependent (`buildVLCDeviceProfile` vs
    /// `buildAppleDeviceProfile`, chosen from `forceNativeAVPlayer` at playback
    /// time) and this app always negotiates its own `PlaybackInfo` when playback
    /// actually starts. A profile pinned here would be a second, staler copy of
    /// that decision — the exact incoherence that makes a server pre-transcode
    /// for the wrong engine.
    ///
    /// `supportedCommands` lists only `DisplayMessage`, and that restraint is
    /// the point: `Play` (the "start this now" message) is not a
    /// `GeneralCommandType` and needs no declaration, while advertising
    /// transport commands the app doesn't execute would render dead controls in
    /// the sender's UI. `JellyfinSocket` honors exactly what is promised here.
    /// `supportsMediaControl: false` is how the user's opt-out is expressed:
    /// re-posting with the flag cleared removes this device from every picker
    /// immediately, whereas simply not posting would leave the session's
    /// previously-declared capabilities standing until it expires.
    public func publishCapabilities(supportsMediaControl: Bool) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let body = ClientCapabilitiesDto(
            playableMediaTypes: [.video],
            supportedCommands: supportsMediaControl ? [.displayMessage] : [],
            isSupportsMediaControl: supportsMediaControl,
            isSupportsPersistentIdentifier: true
        )
        do {
            _ = try await client.send(Paths.postFullCapabilities(body))
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// Sends a message to another session. See the protocol note on
    /// `RemoteControlAPI.sendMessage`: Jellyfin has no invitation primitive, so
    /// this is a notification and nothing more — it carries no join action.
    public func sendMessage(sessionId: String, header: String, text: String, timeoutMs: Int?) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        do {
            _ = try await client.send(Paths.sendMessageCommand(
                sessionID: sessionId,
                MessageCommand(header: header, text: text, timeoutMs: timeoutMs)
            ))
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// The URL of Jellyfin's realtime `/socket`, for `JellyfinSocketHub` to
    /// connect. Returns `nil` when unauthenticated.
    ///
    /// Lives here — in the remote-control file — rather than in the SyncPlay one
    /// because remote control is the consumer that is on by default; SyncPlay
    /// inherits the same member through `RealtimeSocketAPI`. There is deliberately
    /// only ONE of these: two factories is how the app ended up able to open two
    /// sockets onto the same server-side session.
    ///
    /// Note the `setEndpointPath` base-path preservation, without which a
    /// sub-path-hosted server (`https://host/jellyfin`) gets a socket URL that 404s.
    public func makeRealtimeSocketURL() -> URL? {
        guard let client = getClient(),
              let serverURL = getServerURL(),
              let token = client.accessToken else { return nil }
        guard var comps = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.setEndpointPath("/socket", preservingBasePathOf: serverURL)
        comps.scheme = (serverURL.scheme?.lowercased() == "https") ? "wss" : "ws"
        // `ApiKey`, not the legacy `api_key` — rejected once Jellyfin 12.0's
        // `EnableLegacyAuthorization = false` default lands; a socket has no
        // header to carry the token any other way.
        comps.queryItems = [
            URLQueryItem(name: "ApiKey", value: token),
            URLQueryItem(name: "deviceId", value: deviceID)
        ]
        return comps.url
    }
}
