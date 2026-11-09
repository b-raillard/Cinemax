import Testing
import Foundation
@testable import CinemaxKit
@testable import Cinemax
import Nuke

@Suite("Adresse locale — classement")
struct LocalNetworkAddressTests {
    @Test("Bornes des plages IPv4")
    func rangeBoundaries() {
        #expect(LocalNetworkAddress.kind(ofLiteral: "10.0.0.1") == .privateIPv4)
        #expect(LocalNetworkAddress.kind(ofLiteral: "172.15.255.255") == .publicIPv4)
        #expect(LocalNetworkAddress.kind(ofLiteral: "172.16.0.0") == .privateIPv4)
        #expect(LocalNetworkAddress.kind(ofLiteral: "172.31.255.255") == .privateIPv4)
        #expect(LocalNetworkAddress.kind(ofLiteral: "172.32.0.0") == .publicIPv4)
        #expect(LocalNetworkAddress.kind(ofLiteral: "192.168.1.128") == .privateIPv4)
        #expect(LocalNetworkAddress.kind(ofLiteral: "192.169.0.1") == .publicIPv4)
        #expect(LocalNetworkAddress.kind(ofLiteral: "169.254.3.4") == .linkLocalIPv4)
        #expect(LocalNetworkAddress.kind(ofLiteral: "100.64.0.1") == .cgnatIPv4)
        #expect(LocalNetworkAddress.kind(ofLiteral: "100.127.255.255") == .cgnatIPv4)
        #expect(LocalNetworkAddress.kind(ofLiteral: "100.128.0.1") == .publicIPv4)
        #expect(LocalNetworkAddress.kind(ofLiteral: "127.0.0.1") == .loopbackIPv4)
    }

    @Test("Formes IPv6")
    func ipv6Forms() {
        #expect(LocalNetworkAddress.kind(ofLiteral: "fd12:3456::1") == .uniqueLocalIPv6)
        #expect(LocalNetworkAddress.kind(ofLiteral: "fc00::1") == .uniqueLocalIPv6)
        #expect(LocalNetworkAddress.kind(ofLiteral: "fe80::1c2b") == .linkLocalIPv6)
        #expect(LocalNetworkAddress.kind(ofLiteral: "fe80::1%en0") == .linkLocalIPv6)
        #expect(LocalNetworkAddress.kind(ofLiteral: "[fd00::5]") == .uniqueLocalIPv6)
        #expect(LocalNetworkAddress.kind(ofLiteral: "::1") == .loopbackIPv6)
        #expect(LocalNetworkAddress.kind(ofLiteral: "2a01:cb00:1234::5") == .publicIPv6)
    }

    @Test("Adresses mal formées et noms d'hôte")
    func malformedAndHostnames() {
        for text in ["999.1.1.1", "192.168.1", "nas.lan", "movies.nivadax.net", ""] {
            #expect(LocalNetworkAddress.kind(ofLiteral: text) == .notAnIPLiteral)
        }
    }

    @Test("IPv4 mappée en IPv6 : classée par l'IPv4 embarquée")
    func ipv4MappedIPv6() {
        #expect(LocalNetworkAddress.kind(ofLiteral: "::ffff:192.168.1.128") == .privateIPv4)
        #expect(LocalNetworkAddress.kind(ofLiteral: "::ffff:8.8.8.8") == .publicIPv4)
    }

    @Test("Éligibilité d'un hôte")
    func eligibility() {
        #expect(LocalNetworkAddress.isEligibleHost("192.168.1.128"))
        #expect(LocalNetworkAddress.isEligibleHost("nas.local"))
        #expect(LocalNetworkAddress.isEligibleHost("NAS.LOCAL"))
        #expect(!LocalNetworkAddress.isEligibleHost("nas.lan"))
        #expect(!LocalNetworkAddress.isEligibleHost(".local"))
        #expect(!LocalNetworkAddress.isEligibleHost("100.64.0.1"))
        #expect(!LocalNetworkAddress.isEligibleHost("127.0.0.1"))
        #expect(!LocalNetworkAddress.isEligibleHost("8.8.8.8"))
    }
}

@Suite("Adresse locale — saisie")
struct LocalAddressInputTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test("Un hôte nu part en HTTPS")
    func bareHostDefaultsToHTTPS() {
        #expect(ServerURLNormalizer.normalizeLocal("192.168.1.128:8899") == .success(url("https://192.168.1.128:8899")))
    }

    @Test("HTTPS et sous-chemin conservés")
    func keepsHTTPSAndSubPath() {
        #expect(ServerURLNormalizer.normalizeLocal("https://192.168.1.128/jellyfin/")
                == .success(url("https://192.168.1.128/jellyfin")))
    }

    @Test("Un nom mDNS est accepté")
    func acceptsMDNS() {
        #expect(ServerURLNormalizer.normalizeLocal("nas.local:8096") == .success(url("https://nas.local:8096")))
    }

    @Test("Une IPv6 entre crochets est acceptée")
    func acceptsBracketedIPv6() {
        #expect(ServerURLNormalizer.normalizeLocal("[fd00::5]:8096") == .success(url("https://[fd00::5]:8096")))
    }

    @Test("HTTP refusé, sauf hôte non local qui reste notLocal")
    func refusesHTTP() {
        #expect(ServerURLNormalizer.normalizeLocal("http://192.168.1.128:8899") == .failure(.notHTTPS))
        #expect(ServerURLNormalizer.normalizeLocal("http://nas.local") == .failure(.notHTTPS))
        #expect(ServerURLNormalizer.normalizeLocal("http://8.8.8.8") == .failure(.notLocal))
    }

    @Test("Refus")
    func refusals() {
        #expect(ServerURLNormalizer.normalizeLocal("nas.lan") == .failure(.notLocal))
        #expect(ServerURLNormalizer.normalizeLocal("movies.nivadax.net") == .failure(.notLocal))
        #expect(ServerURLNormalizer.normalizeLocal("100.64.1.2") == .failure(.notLocal))
        #expect(ServerURLNormalizer.normalizeLocal("ftp://192.168.1.2") == .failure(.malformed))
        #expect(ServerURLNormalizer.normalizeLocal("   ") == .failure(.malformed))
        #expect(ServerURLNormalizer.normalizeLocal("http://") == .failure(.malformed))
    }
}

@Suite("Adresse locale — décision de route")
struct ServerRoutePolicyTests {
    private let lan = URL(string: "https://192.168.1.128:8920")!

    @Test func noLocalAddressIsInternet() {
        #expect(ServerRoutePolicy.decide(localURL: nil, reach: .lanCapable, expectedServerID: "S", probe: nil) == nil)
    }

    @Test func cellularNeverProbes() {
        #expect(!ServerRoutePolicy.shouldProbe(localURL: lan, reach: .cellularOnly))
        #expect(!ServerRoutePolicy.shouldProbe(localURL: lan, reach: .offline))
        #expect(ServerRoutePolicy.shouldProbe(localURL: lan, reach: .lanCapable))
    }

    @Test func probeOKIsLocal() {
        let probe = LocalProbeOutcome.answered(serverID: "S", connectedAddressIsLocal: true)
        #expect(ServerRoutePolicy.decide(localURL: lan, reach: .lanCapable, expectedServerID: "S", probe: probe) == lan)
    }

    @Test func failedProbeIsInternet() {
        let probe = LocalProbeOutcome.failed(localNetworkDenied: false)
        #expect(ServerRoutePolicy.decide(localURL: lan, reach: .lanCapable, expectedServerID: "S", probe: probe) == nil)
    }

    @Test func idMismatchIsInternet() {
        let probe = LocalProbeOutcome.answered(serverID: "OTHER", connectedAddressIsLocal: true)
        #expect(ServerRoutePolicy.decide(localURL: lan, reach: .lanCapable, expectedServerID: "S", probe: probe) == nil)
    }

    @Test func publicConnectedAddressIsInternet() {
        let probe = LocalProbeOutcome.answered(serverID: "S", connectedAddressIsLocal: false)
        #expect(ServerRoutePolicy.decide(localURL: lan, reach: .lanCapable, expectedServerID: "S", probe: probe) == nil)
    }

    @Test func httpLocalURLIsInternet() {
        let http = URL(string: "http://192.168.1.128:8899")!
        let probe = LocalProbeOutcome.answered(serverID: "S", connectedAddressIsLocal: true)
        #expect(ServerRoutePolicy.decide(localURL: http, reach: .lanCapable, expectedServerID: "S", probe: probe) == nil)
    }

    @Test func unknownExpectedIdIsInternet() {
        let probe = LocalProbeOutcome.answered(serverID: "S", connectedAddressIsLocal: true)
        #expect(ServerRoutePolicy.decide(localURL: lan, reach: .lanCapable, expectedServerID: nil, probe: probe) == nil)
    }
}

@Suite("Adresse locale — sonde")
struct LocalRouteProbeTests {
    private let body = Data(#"{"Id":"S","ServerName":"NAS"}"#.utf8)

    @Test func probeAcceptsMatchingBody() {
        #expect(LocalRouteProbe.evaluate(statusCode: 200, body: body, connectedAddress: "192.168.1.128")
            == .answered(serverID: "S", connectedAddressIsLocal: true))
    }

    @Test func probeAcceptsIPv4MappedAddress() {
        #expect(LocalRouteProbe.evaluate(statusCode: 200, body: body, connectedAddress: "::ffff:192.168.1.128")
            == .answered(serverID: "S", connectedAddressIsLocal: true))
    }

    @Test func probeRejectsPublicConnectedAddress() {
        #expect(LocalRouteProbe.evaluate(statusCode: 200, body: body, connectedAddress: "86.245.10.3")
            == .answered(serverID: "S", connectedAddressIsLocal: false))
    }

    @Test func probeRejectsNon200() {
        for status in [301, 401, 500] {
            #expect(LocalRouteProbe.evaluate(statusCode: status, body: body, connectedAddress: "192.168.1.128")
                == .failed(localNetworkDenied: false))
        }
    }

    @Test func probeRejectsBodyWithoutId() {
        let noId = Data(#"{"ServerName":"NAS"}"#.utf8)
        #expect(LocalRouteProbe.evaluate(statusCode: 200, body: noId, connectedAddress: "192.168.1.128")
            == .failed(localNetworkDenied: false))
    }

    @Test func probeUnknownAddressIsNotLocal() {
        #expect(LocalRouteProbe.evaluate(statusCode: 200, body: body, connectedAddress: nil)
            == .answered(serverID: "S", connectedAddressIsLocal: false))
    }
}

@Suite("Adresse locale — réécriture d'URL")
struct ServerRouteRewriteTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func rewriteNoBasePaths() {
        let out = ServerRoutePolicy.rewrite(url("https://movies.nivadax.net/Items/1/Images/Primary?tag=t"),
                                            identityBase: url("https://movies.nivadax.net"),
                                            dialBase: url("http://192.168.1.128:8899"))
        #expect(out?.absoluteString == "http://192.168.1.128:8899/Items/1/Images/Primary?tag=t")
    }

    @Test func rewriteIdentityBasePathToRoot() {
        let out = ServerRoutePolicy.rewrite(url("https://box.example.org/jellyfin/Items/1/Images/Primary"),
                                            identityBase: url("https://box.example.org/jellyfin"),
                                            dialBase: url("http://192.168.1.128:8096"))
        #expect(out?.absoluteString == "http://192.168.1.128:8096/Items/1/Images/Primary")
    }

    @Test func rewriteRootToDialBasePath() {
        let out = ServerRoutePolicy.rewrite(url("https://movies.nivadax.net/Items/1"),
                                            identityBase: url("https://movies.nivadax.net"),
                                            dialBase: url("http://nas.local/jellyfin"))
        #expect(out?.absoluteString == "http://nas.local/jellyfin/Items/1")
    }

    @Test func rewriteLeavesForeignURL() {
        #expect(ServerRoutePolicy.rewrite(url("https://other.example.com/Items/1"),
                                          identityBase: url("https://movies.nivadax.net"),
                                          dialBase: url("http://192.168.1.128:8899")) == nil)
    }

    @Test func kindOfDialURL() {
        #expect(ServerRoutePolicy.kind(ofDialURL: url("http://192.168.1.128:8899")) == .local)
        #expect(ServerRoutePolicy.kind(ofDialURL: url("http://nas.local")) == .local)
        #expect(ServerRoutePolicy.kind(ofDialURL: url("https://movies.nivadax.net")) == .internet)
    }
}

@Suite("Adresse locale — images")
struct LocalServerImageRouteTests {
    private let identity = URL(string: "https://movies.nivadax.net")!
    private let dial = URL(string: "http://192.168.1.128:8899")!

    private final class SpyLoader: DataLoading, @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
        private final class Token: Nuke.Cancellable { func cancel() {} }
        func loadData(with request: URLRequest,
                      didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                      completion: @escaping @Sendable (Error?) -> Void) -> any Nuke.Cancellable {
            lock.lock(); _urls.append(request.url!); lock.unlock()
            return Token()
        }
    }

    @Test func tableRewritesUnderIdentity() {
        let table = ImageRouteTable()
        table.set(identity: identity, dial: dial)
        var request = URLRequest(url: URL(string: "https://movies.nivadax.net/Items/1/Images/Primary")!)
        request.setValue("MediaBrowser Token=\"t\"", forHTTPHeaderField: "Authorization")
        let out = table.rewrite(request)
        #expect(out.url?.absoluteString == "http://192.168.1.128:8899/Items/1/Images/Primary")
        #expect(out.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Token=\"t\"")
    }

    @Test func tableNoDialIsIdentity() {
        let table = ImageRouteTable()
        let request = URLRequest(url: URL(string: "https://movies.nivadax.net/Items/1/Images/Primary")!)
        table.set(identity: identity, dial: nil)
        #expect(table.rewrite(request).url == request.url)
        table.set(identity: identity, dial: identity)
        #expect(table.rewrite(request).url == request.url)
    }

    @Test func loaderForwardsRewrittenRequest() {
        let table = ImageRouteTable()
        table.set(identity: identity, dial: dial)
        let spy = SpyLoader()
        let loader = RoutedImageDataLoader(wrapping: spy, table: table)
        _ = loader.loadData(with: URLRequest(url: URL(string: "https://movies.nivadax.net/Items/1/Images/Primary")!),
                            didReceiveData: { _, _ in }, completion: { _ in })
        #expect(spy.urls.map(\.absoluteString) == ["http://192.168.1.128:8899/Items/1/Images/Primary"])
    }

    /// A loader that records what it was asked to fetch, then fails — so a
    /// pipeline request through it ends instead of hanging.
    private final class FailingSpyLoader: DataLoading, @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
        private final class Token: Nuke.Cancellable { func cancel() {} }
        func loadData(with request: URLRequest,
                      didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                      completion: @escaping @Sendable (Error?) -> Void) -> any Nuke.Cancellable {
            lock.lock(); _urls.append(request.url!); lock.unlock()
            DispatchQueue.global().async { completion(URLError(.notConnectedToInternet)) }
            return Token()
        }
    }

    /// Through a REAL pipeline: the transport dials the LAN, while the request
    /// and both cache keys stay on the identity — a route change never
    /// re-downloads nor double-stores an image. A private table, never
    /// `.shared` (parallel suites).
    @Test func cacheKeyStaysIdentity() async {
        let table = ImageRouteTable()
        table.set(identity: identity, dial: dial)
        let spy = FailingSpyLoader()
        var configuration = ImagePipeline.Configuration(dataLoader: RoutedImageDataLoader(wrapping: spy, table: table))
        configuration.imageCache = nil
        configuration.dataCache = nil
        let pipeline = ImagePipeline(configuration: configuration)
        let url = URL(string: "https://movies.nivadax.net/Items/1/Images/Primary")!
        let request = ImageRequest(url: url)

        _ = try? await pipeline.data(for: request)

        #expect(spy.urls.map(\.absoluteString) == ["http://192.168.1.128:8899/Items/1/Images/Primary"])
        #expect(request.imageId == url.absoluteString)
        let dataKey = pipeline.cache.makeDataCacheKey(for: request)
        #expect(dataKey.hasPrefix(url.absoluteString))
        #expect(!dataKey.contains("192.168.1.128"))
        #expect(pipeline.cache.makeImageCacheKey(for: request) == pipeline.cache.makeImageCacheKey(for: ImageRequest(url: url)))
    }
}

/// « Local » / « Internet » on the cards that are NOT the active server: from
/// the HOST of the URL that answered, as soon as either probe answers.
@Suite("Adresse locale — indication des cartes")
struct ServersRouteIndicationTests {
    private let lanIdentity = URL(string: "http://192.168.1.128:8899")!
    private let publicIdentity = URL(string: "https://movies.nivadax.net")!
    private let lan = URL(string: "https://192.168.1.128:8920")!
    private let online = PingResult.online(name: nil, version: nil, serverID: "S")

    @Test func lanIdentityReadsLocalWithNoLocalAddress() {
        let card = ServersViewModel.cardState(publicResult: online, localDone: true, localDial: nil, identity: lanIdentity)
        #expect(card?.status == .online)
        #expect(card?.route == .local)
    }

    @Test func publicAnswerShowsAtOnceThenTheLANUpgrades() {
        // Away from home the LAN probe is still running: the card is online,
        // « Internet », without waiting for its timeout.
        let early = ServersViewModel.cardState(publicResult: online, localDone: false, localDial: nil, identity: publicIdentity)
        #expect(early?.status == .online)
        #expect(early?.route == .internet)
        // At home the LAN probe then answers: « Local ».
        let late = ServersViewModel.cardState(publicResult: online, localDone: true, localDial: lan, identity: publicIdentity)
        #expect(late?.status == .online)
        #expect(late?.route == .local)
    }

    @Test func lanAnswerAloneIsOnlineLocal() {
        let card = ServersViewModel.cardState(publicResult: nil, localDone: true, localDial: lan, identity: publicIdentity)
        #expect(card?.status == .online)
        #expect(card?.route == .local)
        let tunnelDown = ServersViewModel.cardState(publicResult: .offline, localDone: true, localDial: lan, identity: publicIdentity)
        #expect(tunnelDown?.route == .local)
    }

    @Test func offlineOnlyOnceBothFailed() {
        #expect(ServersViewModel.cardState(publicResult: .offline, localDone: false, localDial: nil, identity: publicIdentity) == nil)
        #expect(ServersViewModel.cardState(publicResult: nil, localDone: true, localDial: nil, identity: publicIdentity) == nil)
        let card = ServersViewModel.cardState(publicResult: .offline, localDone: true, localDial: nil, identity: publicIdentity)
        #expect(card?.status == .offline)
        #expect(card?.route == nil)
    }
}

@Suite("Adresse locale — réseau")
struct LocalNetworkReachTests {
    @Test func reachMapping() {
        #expect(NetworkMonitor.reach(isSatisfied: true, usesWiFiOrWired: true) == .lanCapable)
        #expect(NetworkMonitor.reach(isSatisfied: true, usesWiFiOrWired: false) == .cellularOnly)
        #expect(NetworkMonitor.reach(isSatisfied: false, usesWiFiOrWired: true) == .offline)
        #expect(NetworkMonitor.reach(isSatisfied: false, usesWiFiOrWired: false) == .offline)
    }
}

/// The widget's and the Top Shelf's own probe (`ExtensionServerRoute.swift`,
/// shared by source — the app targets carry it only for these tests).
@Suite("Adresse locale — extensions")
struct ExtensionServerRouteTests {
    private let body = Data(#"{"Id":"S","ServerName":"NAS"}"#.utf8)
    private let pub = URL(string: "https://jelly.example.com")!
    private let lan = URL(string: "https://192.168.1.128:8920")!

    @Test func extensionProbeTimeout() {
        #expect(ExtensionServerRoute.probeTimeout == 1.0)
    }

    @Test func extensionAcceptsMatchingLocal() {
        #expect(ExtensionServerRoute.accepts(statusCode: 200, body: body, serverID: "S", connectedAddress: "192.168.1.128"))
        #expect(ExtensionServerRoute.accepts(statusCode: 200, body: body, serverID: "S", connectedAddress: "::ffff:192.168.1.128"))
    }

    @Test func extensionRejectsMismatch() {
        #expect(!ExtensionServerRoute.accepts(statusCode: 200, body: body, serverID: "OTHER", connectedAddress: "192.168.1.128"))
    }

    @Test func extensionRejectsPublicAddress() {
        #expect(!ExtensionServerRoute.accepts(statusCode: 200, body: body, serverID: "S", connectedAddress: "86.245.10.3"))
        #expect(!ExtensionServerRoute.accepts(statusCode: 200, body: body, serverID: "S", connectedAddress: "100.64.0.1"))
        #expect(!ExtensionServerRoute.accepts(statusCode: 200, body: body, serverID: "S", connectedAddress: nil))
    }

    @Test func extensionRejectsNon200AndBodyWithoutId() {
        for status in [301, 401, 500] {
            #expect(!ExtensionServerRoute.accepts(statusCode: status, body: body, serverID: "S", connectedAddress: "192.168.1.128"))
        }
        let noId = Data(#"{"ServerName":"NAS"}"#.utf8)
        #expect(!ExtensionServerRoute.accepts(statusCode: 200, body: noId, serverID: "S", connectedAddress: "192.168.1.128"))
        #expect(!ExtensionServerRoute.accepts(statusCode: 200, body: Data(#"{"Id":""}"#.utf8), serverID: "", connectedAddress: "192.168.1.128"))
    }

    /// All three return at once, without a request.
    @Test func extensionNoLocalAddressIsPublic() async {
        #expect(await ExtensionServerRoute.dialURL(publicURL: pub, localURL: nil, serverID: "S", localPin: nil) == pub)
        #expect(await ExtensionServerRoute.dialURL(publicURL: pub, localURL: lan, serverID: nil, localPin: nil) == pub)
        // The LAN address is https only (amendment).
        let http = URL(string: "http://192.168.1.128:8096")!
        #expect(await ExtensionServerRoute.dialURL(publicURL: pub, localURL: http, serverID: "S", localPin: nil) == pub)
    }

    /// Once dialling the LAN, the session's fetches validate with the LAN pin.
    @Test func extensionDialingSwapsPin() {
        let local = ExtensionServerRoute.endpoint(publicURL: pub, publicPin: "ab12", dialURL: lan, localPin: "cd34")
        #expect(local == .init(serverURL: lan, pinnedCertificateSHA256: "cd34"))
        let internet = ExtensionServerRoute.endpoint(publicURL: pub, publicPin: "ab12", dialURL: pub, localPin: "cd34")
        #expect(internet == .init(serverURL: pub, pinnedCertificateSHA256: "ab12"))
    }

    @Test func extensionPinKeyIsTheLANHostPort() throws {
        let pin = try #require(ExtensionServerTrust.pin(serverURL: lan, fingerprint: "cd34"))
        #expect(pin.trustKey == "192.168.1.128:8920")
    }
}

/// App Intents: after `reconnect`, the headless client dials the LAN when the
/// same probe and policy as the app's say so.
@Suite("Adresse locale — App Intents")
struct IntentRouteTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var timeouts: [TimeInterval] = []
        func record(_ timeout: TimeInterval) { lock.lock(); timeouts.append(timeout); lock.unlock() }
        var recorded: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return timeouts }
    }

    private func context(localURL: URL?, serverID: String?) -> IntentSessionContext {
        IntentSessionContext(
            serverId: "entry", serverURL: URL(string: "https://jelly.example.com")!,
            accessToken: "t", userId: "u", localURL: localURL, serverID: serverID)
    }

    private let lan = URL(string: "https://192.168.1.128:8920")!

    @Test func intentDialsLANWhenProbeMatches() async {
        let calls = Calls()
        let dial = await IntentSessionProvider.dialURL(for: context(localURL: lan, serverID: "S")) { _, timeout in
            calls.record(timeout)
            return .answered(serverID: "S", connectedAddressIsLocal: true)
        }
        #expect(dial == lan)
        #expect(calls.recorded == [LocalRouteProbe.launchTimeout])
    }

    @Test func intentStaysPublicOnMismatchOrNonLocal() async {
        let other = await IntentSessionProvider.dialURL(for: context(localURL: lan, serverID: "S")) { _, _ in
            .answered(serverID: "OTHER", connectedAddressIsLocal: true)
        }
        #expect(other == nil)
        let remote = await IntentSessionProvider.dialURL(for: context(localURL: lan, serverID: "S")) { _, _ in
            .answered(serverID: "S", connectedAddressIsLocal: false)
        }
        #expect(remote == nil)
    }

    @Test func intentContextCarriesLocalAddress() throws {
        let keychain = MockKeychain()
        keychain.savedServers = [ServerEntry(
            id: "a", name: "NAS", url: URL(string: "https://jelly.example.com")!, serverID: "S",
            accessToken: "t", userId: "u", localURL: lan)]
        keychain.savedActiveServerId = "a"
        let context = try #require(IntentSessionProvider.resolveContext(keychain: keychain))
        #expect(context.localURL == lan)
        #expect(context.serverID == "S")
        #expect(context.serverURL == URL(string: "https://jelly.example.com")!)
    }

    @Test func intentNoLocalAddressMakesNoProbe() async {
        let calls = Calls()
        let dial = await IntentSessionProvider.dialURL(for: context(localURL: nil, serverID: "S")) { _, timeout in
            calls.record(timeout)
            return .answered(serverID: "S", connectedAddressIsLocal: true)
        }
        #expect(dial == nil)
        #expect(calls.recorded.isEmpty)
    }
}

@Suite("Adresse locale — enregistrement")
struct LocalAddressSavePolicyTests {
    private func decide(
        known: String?, publicID: String? = nil, probe: LocalProbeOutcome,
        certificate: LocalCertificateState = .trusted
    ) -> LocalAddressSaveDecision {
        LocalAddressSavePolicy.decide(knownServerID: known, publicServerID: publicID, probe: probe, certificate: certificate)
    }

    @Test func saveRefusesPublicConnectedAddress() {
        let decision = decide(known: "S", probe: .answered(serverID: "S", connectedAddressIsLocal: false))
        #expect(decision == LocalAddressSaveDecision(outcome: .refusedNotLocal, saves: false, serverIDToAdopt: nil))
    }

    @Test func answeredWithNoExpectedIdAdoptsLocalId() {
        let decision = decide(known: nil, probe: .answered(serverID: "S", connectedAddressIsLocal: true))
        #expect(decision == LocalAddressSaveDecision(outcome: .reachable, saves: true, serverIDToAdopt: "S"))
    }

    @Test func answeredMatchingKnownIdAdoptsNothing() {
        let decision = decide(known: "S", probe: .answered(serverID: "S", connectedAddressIsLocal: true))
        #expect(decision == LocalAddressSaveDecision(outcome: .reachable, saves: true, serverIDToAdopt: nil))
    }

    @Test func answeredMatchingPublicIdAdoptsIt() {
        let decision = decide(known: nil, publicID: "S", probe: .answered(serverID: "S", connectedAddressIsLocal: true))
        #expect(decision == LocalAddressSaveDecision(outcome: .reachable, saves: true, serverIDToAdopt: "S"))
    }

    @Test func answeredOtherIdIsRefused() {
        let decision = decide(known: "S", probe: .answered(serverID: "OTHER", connectedAddressIsLocal: true))
        #expect(decision == LocalAddressSaveDecision(outcome: .refusedOtherServer, saves: false, serverIDToAdopt: nil))
        let fromPublic = decide(known: nil, publicID: "S", probe: .answered(serverID: "OTHER", connectedAddressIsLocal: true))
        #expect(fromPublic.outcome == .refusedOtherServer)
        #expect(!fromPublic.saves)
    }

    @Test func failedWithNoExpectedIdNeedsSignIn() {
        let decision = decide(known: nil, probe: .failed(localNetworkDenied: false))
        #expect(decision == LocalAddressSaveDecision(outcome: .needsSignIn, saves: false, serverIDToAdopt: nil))
        #expect(decide(known: nil, probe: .failed(localNetworkDenied: true)).outcome == .needsSignIn)
    }

    @Test func failedLocalNetworkDeniedSaves() {
        let decision = decide(known: "S", probe: .failed(localNetworkDenied: true))
        #expect(decision == LocalAddressSaveDecision(outcome: .savedLocalNetworkDenied, saves: true, serverIDToAdopt: nil))
        let learned = decide(known: nil, publicID: "S", probe: .failed(localNetworkDenied: true))
        #expect(learned == LocalAddressSaveDecision(outcome: .savedLocalNetworkDenied, saves: true, serverIDToAdopt: "S"))
    }

    @Test func failedUnreachablePinnedSaves() {
        let decision = decide(known: "S", probe: .failed(localNetworkDenied: false), certificate: .trusted)
        #expect(decision == LocalAddressSaveDecision(outcome: .savedUnreachable, saves: true, serverIDToAdopt: nil))
        let learned = decide(known: nil, publicID: "S", probe: .failed(localNetworkDenied: false), certificate: .trusted)
        #expect(learned == LocalAddressSaveDecision(outcome: .savedUnreachable, saves: true, serverIDToAdopt: "S"))
    }

    @Test func failedPendingCertificateNeedsApproval() {
        for known in ["S", nil] as [String?] {
            for denied in [false, true] {
                let decision = decide(known: known, probe: .failed(localNetworkDenied: denied), certificate: .pendingApproval)
                #expect(decision == LocalAddressSaveDecision(outcome: .needsCertificateApproval, saves: false, serverIDToAdopt: nil))
            }
        }
    }

    @Test func failedUnreachableUnpinnedSavesNeedingApproval() {
        let decision = decide(known: "S", probe: .failed(localNetworkDenied: false), certificate: .unknown)
        #expect(decision == LocalAddressSaveDecision(outcome: .savedNeedsApproval, saves: true, serverIDToAdopt: nil))
        let learned = decide(known: nil, publicID: "S", probe: .failed(localNetworkDenied: false), certificate: .unknown)
        #expect(learned == LocalAddressSaveDecision(outcome: .savedNeedsApproval, saves: true, serverIDToAdopt: "S"))
    }

    @Test func answeredIgnoresCertificateState() {
        let decision = decide(known: "S", probe: .answered(serverID: "S", connectedAddressIsLocal: true), certificate: .pendingApproval)
        #expect(decision.outcome == .reachable)
        #expect(decision.saves)
    }

    @Test func emptyIdsCountAsUnknown() {
        let decision = decide(known: "", publicID: "", probe: .failed(localNetworkDenied: false))
        #expect(decision.outcome == .needsSignIn)
    }

    @Test func certificateChangeLogNamesOnlyTheClass() {
        #expect(ServerCertificateTrust.addressClass(ofTrustKey: "192.168.1.128:8920") == "local")
        #expect(ServerCertificateTrust.addressClass(ofTrustKey: "nas-raillard.local:8920") == "local")
        #expect(ServerCertificateTrust.addressClass(ofTrustKey: "fd00::1:8920") == "local")
        #expect(ServerCertificateTrust.addressClass(ofTrustKey: "movies.nivadax.net:443") == "internet")
        #expect(ServerCertificateTrust.addressClass(ofTrustKey: "8.8.8.8:443") == "internet")
    }
}

@Suite("Adresse locale — messages")
struct LocalAddressToastTests {
    static let keys = [
        "servers.localAddress", "servers.localAddress.title", "servers.localAddress.message",
        "servers.localAddress.placeholder", "servers.localAddress.notHTTPS",
        "servers.localAddress.savedNeedsApproval", "servers.localAddress.reachable",
        "servers.localAddress.savedUnreachable", "servers.localAddress.denied",
        "servers.localAddress.otherServer", "servers.localAddress.notLocal",
        "servers.localAddress.signInFirst", "servers.localAddress.removed",
        "servers.route.local", "servers.route.internet", "settings.server.route.local"
    ]

    @Test func toastMapping() {
        let expected: [(LocalAddressSaveOutcome, String, Toast.Level)] = [
            (.reachable, "servers.localAddress.reachable", .success),
            (.savedUnreachable, "servers.localAddress.savedUnreachable", .info),
            (.savedLocalNetworkDenied, "servers.localAddress.denied", .error),
            (.refusedOtherServer, "servers.localAddress.otherServer", .error),
            (.refusedNotLocal, "servers.localAddress.notLocal", .error),
            (.needsSignIn, "servers.localAddress.signInFirst", .error),
            (.removed, "servers.localAddress.removed", .info),
            (.refusedNotHTTPS, "servers.localAddress.notHTTPS", .error),
            (.savedNeedsApproval, "servers.localAddress.savedNeedsApproval", .info)
        ]
        for (outcome, key, level) in expected {
            let message = LocalAddressToast.message(for: outcome)
            #expect(message?.key == key, "\(outcome)")
            #expect(message?.level == level, "\(outcome)")
        }
        // The screen shows the certificate approval instead of a toast.
        #expect(LocalAddressToast.message(for: .needsCertificateApproval) == nil)
    }

    @Test func everyKeyExistsInAllLanguages() throws {
        for lang in AppLanguage.supported {
            let path = try #require(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: lang))
            let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
            for key in Self.keys {
                let value = table[key]
                #expect(value?.isEmpty == false, "\(lang) \(key)")
            }
            #expect(table["settings.server.route.local"]?.contains("%@") == true, "\(lang)")
            #expect(table["servers.localAddress.placeholder"] == "192.168.1.128:8920", "\(lang)")
        }
    }
}
