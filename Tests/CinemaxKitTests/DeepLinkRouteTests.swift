import Testing
import Foundation
@testable import Cinemax

/// Verrouille la lecture des liens entrants (#185) : le schéma `cinemax://`
/// et les Universal Links `https://<hôte>/…` mènent aux DEUX mêmes
/// destinations, et rien d'autre.
@Suite("Liens entrants — lecture")
struct DeepLinkRouteTests {

    private let undashed = "0123456789abcdef0123456789abcdef"
    private let dashed = "01234567-89ab-cdef-0123-456789abcdef"
    private let host = DeepLinkRoute.universalLinkHost

    private func route(_ s: String) -> DeepLinkRoute? {
        DeepLinkRoute.parse(URL(string: s)!, isValidItemId: AppState.isValidItemId)
    }

    @Test("Schéma custom : item et home")
    func customScheme() {
        #expect(route("cinemax://item/\(undashed)") == .item(id: undashed))
        #expect(route("cinemax://item/\(dashed)") == .item(id: dashed))
        #expect(route("cinemax://home") == .home)
    }

    @Test("Universal Link : mêmes destinations sur l'hôte déclaré")
    func universalLink() {
        #expect(route("https://\(host)/item/\(undashed)") == .item(id: undashed))
        #expect(route("https://\(host)/item/\(dashed)") == .item(id: dashed))
        #expect(route("https://\(host)/home") == .home)
    }

    @Test("Hôte et schéma insensibles à la casse, verbe non")
    func caseFolding() {
        #expect(route("HTTPS://\(host.uppercased())/item/\(undashed)") == .item(id: undashed))
        #expect(route("CINEMAX://home") == .home)
        #expect(route("https://\(host)/Item/\(undashed)") == nil)
    }

    @Test("Un autre hôte n'est pas un lien de l'app")
    func wrongHost() {
        #expect(route("https://example.com/item/\(undashed)") == nil)
        #expect(route("https://\(host).evil.com/item/\(undashed)") == nil)
        #expect(route("http://\(host)/item/\(undashed)") == nil)
    }

    @Test("Identifiant mal formé : rejeté sur les deux formes")
    func malformedId() {
        #expect(route("cinemax://item/../secret") == nil)
        #expect(route("cinemax://item/12345") == nil)
        #expect(route("https://\(host)/item/not-an-id") == nil)
    }

    @Test("Segments en trop, verbe inconnu, item nu : rejetés")
    func shapeMismatch() {
        #expect(route("https://\(host)/item/\(undashed)/play") == nil)
        #expect(route("https://\(host)/item") == nil)
        #expect(route("https://\(host)/play/\(undashed)") == nil)
        #expect(route("https://\(host)/") == nil)
        #expect(route("cinemax://play/\(undashed)") == nil)
    }

    @Test("Requête et fragment ignorés")
    func queryAndFragment() {
        #expect(route("https://\(host)/item/\(undashed)?utm=x#frag") == .item(id: undashed))
        #expect(route("https://\(host)/home?x=1") == .home)
    }
}
