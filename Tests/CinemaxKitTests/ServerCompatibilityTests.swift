import Foundation
import Testing
@testable import CinemaxKit

/// The app's compatibility floor is **Jellyfin 10.9** (see CLAUDE.md): since
/// jellyfin-sdk-swift 0.6.0 the generator no longer emits the `/Users/{userId}/…`
/// routes, and the client depends on their 10.9 replacements (`/UserItems/Resume`,
/// `/Items/Latest`, `/UserViews`, `/UserPlayedItems`, `/UserFavoriteItems`,
/// `/Users/Password`, `/Users/Configuration`) in the app, the Widget and the Top
/// Shelf alike. These tests lock the pieces of that floor a refactor could break
/// in silence — a capability gate that stops gating, or a learned version that
/// gets thrown away where nothing re-learns it.
@Suite("Server compatibility")
struct ServerCompatibilityTests {

    // MARK: - A1 — a same-server reconnect keeps the learned version

    /// `UserSwitchSheet` and `rollBackFailedSwitch` both reconnect onto the URL
    /// the client already points at, and NOTHING re-learns the version on those
    /// paths. Clearing it there left the rest of the process on "version
    /// unknown", which every gate reads as *unsupported*: on a 12.0 server the
    /// library Collections row, the `/Items/{id}/Collections` reverse lookup,
    /// the lightweight `fetchUserData` and the UPnP admin row all disappeared
    /// after a simple account switch.
    @Test("reconnecting to the same server keeps the learned version")
    func reconnectSameServerKeepsVersion() {
        let api = JellyfinAPIClient()
        let url = URL(string: "https://host/jellyfin")!
        api.reconnect(url: url, accessToken: "tok-a")
        api.setServerVersion("12.0.0")

        api.reconnect(url: url, accessToken: "tok-b")

        #expect(api.getServerVersion() == ServerVersion(12, 0, 0))
        #expect(api.serverSupports(.libraryScopedCollections))
    }

    /// The other half of the same rule, and the one that must never regress:
    /// a multi-server switch really does repoint the client, so the old
    /// version stops being true and a 12.0 feature must not fire at a 10.9 box.
    @Test("reconnecting to a DIFFERENT server always clears the learned version")
    func reconnectOtherServerClearsVersion() {
        let api = JellyfinAPIClient()
        api.reconnect(url: URL(string: "https://twelve.example")!, accessToken: "tok")
        api.setServerVersion("12.0.0")

        api.reconnect(url: URL(string: "https://ten.example")!, accessToken: "tok")

        #expect(api.getServerVersion() == nil)
        #expect(api.serverSupports(.libraryScopedCollections) == false)
        #expect(api.serverSupports(.itemUserDataEndpoint) == false)
    }

    /// "Same server" is the registry's own equivalence class
    /// (`ServerURLNormalizer.dedupKey`), not raw `URL` equality: a trailing
    /// slash, an uppercase host or an explicit default port name the same box.
    @Test("a different spelling of the same server is still the same server")
    func reconnectSameServerDifferentSpelling() {
        let api = JellyfinAPIClient()
        api.reconnect(url: URL(string: "https://Host.Example:443/jellyfin")!, accessToken: "tok")
        api.setServerVersion("12.0.0")

        api.reconnect(url: URL(string: "https://host.example/jellyfin/")!, accessToken: "tok")

        #expect(api.getServerVersion() == ServerVersion(12, 0, 0))
    }

    /// A sub-path is part of the identity: `https://host/jellyfin` and
    /// `https://host` are two different servers behind one host name.
    @Test("a different sub-path on the same host clears the version")
    func reconnectDifferentSubPathClearsVersion() {
        let api = JellyfinAPIClient()
        api.reconnect(url: URL(string: "https://host/jellyfin")!, accessToken: "tok")
        api.setServerVersion("12.0.0")

        api.reconnect(url: URL(string: "https://host/emby")!, accessToken: "tok")

        #expect(api.getServerVersion() == nil)
    }

    // MARK: - A2 — media segments are 10.10+

    @Test("mediaSegments admits 10.10 and refuses 10.9")
    func mediaSegmentsThreshold() throws {
        #expect(ServerVersion.mediaSegments == ServerVersion(10, 10))
        #expect(try #require(ServerVersion("10.9.11")).supports(.mediaSegments) == false)
        #expect(try #require(ServerVersion("10.10.0")).supports(.mediaSegments))
        #expect(try #require(ServerVersion("12.0.0")).supports(.mediaSegments))
    }

    /// The gate must sit BEFORE the client lookup, exactly like
    /// `getItemUserData`: with no version learned the call answers `[]` without
    /// touching the network — which is byte-identical to what a 10.9 server's
    /// 404 produced for `SkipSegmentController`, minus a failed request and a
    /// log line per playback.
    @Test("getMediaSegments answers [] on an unknown version without hitting the network")
    func mediaSegmentsUnknownVersionIsSilent() async throws {
        let api = JellyfinAPIClient()
        let segments = try await api.getMediaSegments(itemId: "item-1")
        #expect(segments.isEmpty)
    }

    /// The paired control: the refusal is version-driven, not a blanket
    /// short-circuit. On a supported version the call proceeds far enough to
    /// hit the missing client.
    @Test("getMediaSegments on a supported version reaches the client lookup")
    func mediaSegmentsSupportedVersionProceeds() async {
        let api = JellyfinAPIClient()
        api.setServerVersion("10.10.0")
        await #expect(throws: JellyfinError.self) {
            _ = try await api.getMediaSegments(itemId: "item-1")
        }
    }

    // MARK: - A3 — the two 12.0 thresholds

    /// `GET /Items?includeItemTypes=BoxSet&parentId=<library>` resolves through
    /// `linkedChildAncestorIds` only from 12.0; on 10.x the server silently
    /// DROPS `parentId` for BoxSets and answers with every collection it holds.
    @Test("libraryScopedCollections admits 12.0 and refuses every 10.x")
    func libraryScopedCollectionsThreshold() throws {
        #expect(ServerVersion.libraryScopedCollections == ServerVersion(12, 0, 0))
        #expect(try #require(ServerVersion("10.11.11")).supports(.libraryScopedCollections) == false)
        #expect(try #require(ServerVersion("10.10.7")).supports(.libraryScopedCollections) == false)
        #expect(try #require(ServerVersion("12.0.0-rc7")).supports(.libraryScopedCollections))
        #expect(try #require(ServerVersion("12.0.0")).supports(.libraryScopedCollections))
        #expect(try #require(ServerVersion("12.1.0")).supports(.libraryScopedCollections))
    }

    /// Read the other way round from every other threshold — UPnP port
    /// forwarding exists BELOW it — so the admin row's gate is
    /// `version < upnpPortForwarding` on a KNOWN version, and an unknown
    /// version hides the row.
    @Test("upnpPortForwarding is the version at which UPnP goes dead")
    func upnpPortForwardingThreshold() throws {
        #expect(ServerVersion.upnpPortForwarding == ServerVersion(12, 0, 0))
        #expect(try #require(ServerVersion("10.11.11")) < ServerVersion.upnpPortForwarding)
        #expect(try #require(ServerVersion("10.9.0")) < ServerVersion.upnpPortForwarding)
        #expect((try #require(ServerVersion("12.0.0")) < ServerVersion.upnpPortForwarding) == false)
        #expect((try #require(ServerVersion("12.0.0-rc7")) < ServerVersion.upnpPortForwarding) == false)
    }

    // MARK: - A6 — the avatar route the 12.0 spec carries

    /// `/Users/{id}/Images/Primary` is absent from the 12.0 spec (still routed
    /// on a 12.0 server, so nothing was broken); `/UserImage?userId=` is the
    /// route the SDK generates and exists from 10.9, so no gate. The sizing
    /// query the image pipeline reads has to survive the move.
    @Test("userImageURL targets /UserImage and keeps its sizing query")
    func userImageURLShape() {
        let builder = ImageURLBuilder(serverURL: URL(string: "http://localhost:8096")!)
        let url = builder.userImageURL(userId: "user-1", tag: "tag-9", maxWidth: 96)

        #expect(url.path() == "/UserImage")
        #expect(url.absoluteString.contains("userId=user-1"))
        #expect(url.absoluteString.contains("tag=tag-9"))
        #expect(url.absoluteString.contains("maxWidth=96"))
        #expect(url.absoluteString.contains("quality=90"))
        #expect(url.absoluteString.contains("/Users/") == false)
    }

    /// A sub-path-hosted server keeps its base path — the rule every
    /// hand-built URL in the app lives by (`URLComponents+ServerPath`).
    @Test("userImageURL preserves a sub-path-hosted server's base path")
    func userImageURLPreservesBasePath() {
        let builder = ImageURLBuilder(serverURL: URL(string: "https://host/jellyfin")!)
        let url = builder.userImageURL(userId: "user-1")
        #expect(url.path() == "/jellyfin/UserImage")
        #expect(url.absoluteString.contains("userId=user-1"))
    }
}
