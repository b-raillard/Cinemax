import Foundation
import Testing
@testable import CinemaxKit
import JellyfinAPI

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

/// Audit 2026-09-22 (Q3) : l'état de connexion du client est lu et remplacé
/// d'un bloc, et une écriture calculée avant un `await` ne s'installe que si
/// rien n'a remplacé le client entre-temps.
@Suite("JellyfinAPIClient — état de connexion")
struct JellyfinClientStateTests {
    @Test("An install computed from a superseded generation is dropped")
    func staleInstallDropped() {
        var state = JellyfinAPIClient.ClientState()
        let a = JellyfinClient(configuration: .init(url: URL(string: "https://a")!, client: "t", deviceName: "d", deviceID: "i", version: "1"))
        let b = JellyfinClient(configuration: .init(url: URL(string: "https://b")!, client: "t", deviceName: "d", deviceID: "i", version: "1"))
        let before = state.generation
        let reconnected = state.install(b, url: URL(string: "https://b")!, dialURL: nil, accessToken: "tok-b")   // a reconnect lands
        // …then the probe that started before it finishes: refused.
        let stale = state.install(a, url: URL(string: "https://a")!, dialURL: nil, accessToken: nil, ifGeneration: before)
        #expect(reconnected)
        #expect(stale == false)
        #expect(state.serverURL == URL(string: "https://b"))
        #expect(state.accessToken == "tok-b")
    }

    @Test("Client, URL and token move together")
    func connectionIsConsistent() {
        let api = JellyfinAPIClient()
        api.reconnect(url: URL(string: "https://one.example")!, accessToken: "t1")
        api.reconnect(url: URL(string: "https://two.example")!, accessToken: "t2")
        let connection = api.getConnection()
        #expect(connection?.serverURL == URL(string: "https://two.example"))
        #expect(connection?.client.configuration.url == URL(string: "https://two.example"))
        #expect(connection?.client.accessToken == "t2")
    }

    @Test("A language change keeps the connection's server and token")
    func languageChangeKeepsConnection() {
        let api = JellyfinAPIClient()
        api.reconnect(url: URL(string: "https://nas.local")!, accessToken: "tok")
        api.setPreferredLanguage("en")
        #expect(api.getConnection()?.client.accessToken == "tok")
        #expect(api.getServerURL() == URL(string: "https://nas.local"))
        #expect(api.getPreferredLanguage() == "en")
    }

    // MARK: - Dial URL (adresse locale, 2026-11-09)
    //
    // The public URL stays the server's IDENTITY; only the transport dials a
    // separate DIAL URL (the LAN address). `JellyfinAPIClient` has no
    // URLSession / URLProtocol injection seam, so the two contracts that would
    // need a stubbed `/System/Info/Public` (`connectToServer(url:dialURL:)`'s
    // install, `fetchServerInfo`'s version guard) are locked through
    // `ClientState` directly, like `staleInstallDropped`.

    private static let identity = URL(string: "https://jellyfin.example.com/jellyfin")!
    private static let lan = URL(string: "https://192.168.1.20:8920")!
    private static let otherServer = URL(string: "https://other.example.net")!

    private static func sdkClient(_ url: URL) -> JellyfinClient {
        JellyfinClient(configuration: .init(url: url, client: "t", deviceName: "d", deviceID: "i", version: "1"))
    }

    @Test("A dial URL rebuilds the client in place: identity, token and version kept")
    func dialURLRebuildsInPlace() {
        let api = JellyfinAPIClient()
        api.reconnect(url: Self.identity, accessToken: "tok")
        api.setServerVersion("12.0.0")

        api.setDialURL(Self.lan)

        #expect(api.getServerURL() == Self.identity, "the identity never moves")
        #expect(api.getDialURL() == Self.lan)
        #expect(api.currentDialURL() == Self.lan)
        #expect(api.getConnection()?.serverURL == Self.lan, "getConnection hands out the URL to DIAL")
        #expect(api.getConnection()?.client.configuration.url == Self.lan)
        #expect(api.knownServerVersion() == ServerVersion(12, 0, 0), "same server: the version survives a route change")
        #expect(api.getConnection()?.client.accessToken == "tok")
    }

    @Test("Setting the dial back to nil dials the identity again")
    func clearingDialDialsIdentity() {
        let api = JellyfinAPIClient()
        api.reconnect(url: Self.identity, accessToken: "tok")
        api.setDialURL(Self.lan)

        api.setDialURL(nil)

        #expect(api.getDialURL() == Self.identity)
        #expect(api.getConnection()?.client.configuration.url == Self.identity)
        #expect(api.getConnection()?.client.accessToken == "tok")
    }

    @Test("An unchanged dial URL does not rebuild the client")
    func unchangedDialIsNoOp() throws {
        let api = JellyfinAPIClient()
        api.reconnect(url: Self.identity, accessToken: "tok")
        api.setDialURL(Self.lan)
        let before = try #require(api.connectionWithGeneration()).generation

        api.setDialURL(Self.lan)

        #expect(api.connectionWithGeneration()?.generation == before)
    }

    @Test("An identity-bound dial for another server is refused: dial and generation untouched")
    func dialForForeignIdentityRefused() throws {
        let api = JellyfinAPIClient()
        api.reconnect(url: Self.identity, accessToken: "tok")
        let before = try #require(api.connectionWithGeneration()).generation

        api.setDialURL(Self.lan, forIdentity: Self.otherServer)

        #expect(api.getDialURL() == Self.identity)
        #expect(api.connectionWithGeneration()?.generation == before)
        #expect(api.getConnection()?.client.configuration.url == Self.identity)
    }

    @Test("An identity-bound dial for the same server applies, whatever its spelling")
    func dialForSameIdentityApplies() {
        let api = JellyfinAPIClient()
        api.reconnect(url: Self.identity, accessToken: "tok")

        api.setDialURL(Self.lan, forIdentity: URL(string: "https://JELLYFIN.example.com/jellyfin/")!)

        #expect(api.getDialURL() == Self.lan)
        #expect(api.getServerURL() == Self.identity)
    }

    @Test("A dial URL before any connection is dropped")
    func dialWithoutConnectionIsDropped() {
        let api = JellyfinAPIClient()
        api.setDialURL(Self.lan)
        #expect(api.getClient() == nil)
        #expect(api.getDialURL() == nil)
    }

    @Test("Every reconnect dials the identity again")
    func reconnectResetsDialURL() {
        let api = JellyfinAPIClient()
        api.reconnect(url: Self.identity, accessToken: "tok")
        api.setDialURL(Self.lan)

        api.reconnect(url: Self.identity, accessToken: "tok")

        #expect(api.getDialURL() == Self.identity,
                "a switch must not hand the next server's token to the previous LAN address")
        #expect(api.getConnection()?.client.configuration.url == Self.identity)
    }

    @Test("A language change keeps the dial URL")
    func languageChangeKeepsDial() {
        let api = JellyfinAPIClient()
        api.reconnect(url: Self.identity, accessToken: "tok")
        api.setDialURL(Self.lan)

        api.setPreferredLanguage("de")

        #expect(api.getDialURL() == Self.lan)
        #expect(api.getServerURL() == Self.identity)
        #expect(api.getConnection()?.client.configuration.url == Self.lan)
        #expect(api.getConnection()?.client.accessToken == "tok")
    }

    @Test("connectionWithGeneration hands out the identity AND the dial")
    func connectionCarriesBothURLs() {
        let api = JellyfinAPIClient()
        api.reconnect(url: Self.identity, accessToken: "tok")
        api.setDialURL(Self.lan)

        let connection = api.connectionWithGeneration()

        #expect(connection?.identity == Self.identity)
        #expect(connection?.dial == Self.lan)
        #expect(connection?.client.configuration.url == Self.lan)
    }

    /// `setDialURL` has no `await` between its snapshot and its install, so no
    /// latch can hold the window from outside: the refusal is locked on
    /// `install(…ifGeneration:)`, which is the only thing it relies on.
    @Test("A dial write computed before a reconnect to another server is refused")
    func staleDialWriteRefused() {
        var state = JellyfinAPIClient.ClientState()
        _ = state.install(Self.sdkClient(Self.identity), url: Self.identity, dialURL: nil, accessToken: "tok")
        let snapshot = state.generation                      // setDialURL's snapshot
        let reconnected = state.install(Self.sdkClient(Self.otherServer), url: Self.otherServer, dialURL: nil, accessToken: "tok-2")
        let stale = state.install(Self.sdkClient(Self.lan), url: Self.identity, dialURL: Self.lan, accessToken: "tok", ifGeneration: snapshot)

        #expect(reconnected)
        #expect(stale == false)
        #expect(state.serverURL == Self.otherServer)
        #expect(state.dialURL == nil)
        #expect(state.effectiveDialURL == Self.otherServer, "the other server is dialled on its own identity")
        #expect(state.accessToken == "tok-2")
    }

    /// The install step of `connectToServer(url:dialURL:)` — the probe itself
    /// needs a stubbed transport the client does not have (see the MARK above).
    @Test("A connect through a dial URL installs the identity beside it")
    func connectWithDialInstallsIdentity() {
        var state = JellyfinAPIClient.ClientState()
        let generation = state.generation
        let installed = state.install(Self.sdkClient(Self.lan), url: Self.identity, dialURL: Self.lan, accessToken: nil, ifGeneration: generation)

        #expect(installed)
        #expect(state.serverURL == Self.identity)
        #expect(state.dialURL == Self.lan)
        #expect(state.effectiveDialURL == Self.lan)
        #expect(state.client?.configuration.url == Self.lan)
    }

    @Test("A dial equal to the identity is stored as « dial the identity »")
    func dialEqualToIdentityIsNil() {
        var state = JellyfinAPIClient.ClientState()
        _ = state.install(Self.sdkClient(Self.identity), url: Self.identity, dialURL: Self.identity, accessToken: nil)
        #expect(state.dialURL == nil)
        #expect(state.effectiveDialURL == Self.identity)
    }

    /// `fetchServerInfo`'s version write: a route change between the probe and
    /// the write bumps the generation but names the SAME server (identity), so
    /// the version is kept — while a switch to another server still drops it.
    @Test("fetchServerInfo's version guard compares the identity, not the dial")
    func fetchServerInfoKeepsVersionAcrossDial() {
        let version = ServerVersion(12, 0, 0)

        var state = JellyfinAPIClient.ClientState()
        _ = state.install(Self.sdkClient(Self.identity), url: Self.identity, dialURL: nil, accessToken: "tok")
        let probed = state.generation
        _ = state.install(Self.sdkClient(Self.lan), url: Self.identity, dialURL: Self.lan, accessToken: "tok", ifGeneration: probed)
        state.recordVersion(version, probedOn: Self.identity, atGeneration: probed)
        #expect(state.serverVersion == version, "a route change is the same server")

        var switched = JellyfinAPIClient.ClientState()
        _ = switched.install(Self.sdkClient(Self.identity), url: Self.identity, dialURL: nil, accessToken: "tok")
        let probedBefore = switched.generation
        _ = switched.install(Self.sdkClient(Self.otherServer), url: Self.otherServer, dialURL: nil, accessToken: "tok-2")
        switched.recordVersion(version, probedOn: Self.identity, atGeneration: probedBefore)
        #expect(switched.serverVersion == nil, "another server's version is never stamped on this one")

        // The probe ran on the LAN address but names the identity: a version
        // recorded while dialling the LAN lands.
        var dialled = JellyfinAPIClient.ClientState()
        _ = dialled.install(Self.sdkClient(Self.lan), url: Self.identity, dialURL: Self.lan, accessToken: "tok")
        dialled.recordVersion(version, probedOn: Self.identity, atGeneration: dialled.generation)
        #expect(dialled.serverVersion == version)
    }
}
