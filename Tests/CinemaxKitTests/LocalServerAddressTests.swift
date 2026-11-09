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

    @Test func cacheKeyStaysIdentity() {
        ImageRouteTable.shared.set(identity: identity, dial: dial)
        defer { ImageRouteTable.shared.set(identity: nil, dial: nil) }
        let url = URL(string: "https://movies.nivadax.net/Items/1/Images/Primary")!
        #expect(ImageRequest(url: url).imageId == url.absoluteString)
    }
}
