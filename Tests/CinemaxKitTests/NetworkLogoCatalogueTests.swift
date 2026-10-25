import Foundation
import Testing
import UIKit
@testable import Cinemax

/// The channel / studio logos of the fiche (2026-10-25): which studio gets a
/// logo, and that every catalogue entry really ships in the asset catalogue.
@Suite("Logos des chaînes")
struct NetworkLogoCatalogueTests {

    @Test("Every catalogue entry is a template image in the bundle")
    func bundleWiring() {
        #expect(NetworkLogoCatalogue.assets.count >= 80)
        for (name, asset) in NetworkLogoCatalogue.assets {
            let image = UIImage(named: asset)
            #expect(image != nil, "\(name) → \(asset) absent du catalogue d'images")
            #expect(image?.renderingMode == .alwaysTemplate, "\(asset) n'est pas en rendu modèle")
        }
    }

    @Test("A series' production company is skipped for its network, whatever the order")
    func networkAfterProductionCompany() {
        let logo = NetworkLogoCatalogue.logo(forStudios: ["Warner Bros. Television", "The CW"])
        #expect(logo?.name == "The CW")
        #expect(logo?.asset == "Networks/network-71")
    }

    @Test("Case and surrounding spaces do not matter; the name is kept as Jellyfin spells it")
    func normalisedLookup() {
        let logo = NetworkLogoCatalogue.logo(forStudios: [" netflix "])
        #expect(logo?.asset == "Networks/network-213")
        #expect(logo?.name == " netflix ")
        #expect(NetworkLogoCatalogue.logo(forStudios: ["Apple TV"])?.asset == "Networks/network-2552")
    }

    @Test("No logo for an unknown studio, nor for none")
    func unknown() {
        #expect(NetworkLogoCatalogue.logo(forStudios: ["Gaumont", "Blender Foundation"]) == nil)
        #expect(NetworkLogoCatalogue.logo(forStudios: []) == nil)
    }
}
