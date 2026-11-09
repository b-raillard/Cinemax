import Testing
@testable import CinemaxKit

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
