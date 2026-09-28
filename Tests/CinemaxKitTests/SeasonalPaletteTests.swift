import SwiftUI
import Testing
import UIKit
@testable import Cinemax

@Suite("Seasonal palette")
@MainActor
struct SeasonalPaletteTests {
    private let halloween = SeasonalThemeCatalogue.halloween

    // MARK: Pure resolution

    @Test("No season: the token's own light / dark values")
    func noSeason() {
        #expect(SeasonalColor.resolve(light: 0xF7F7F8, dark: 0x0E0E0E, token: .surface, isDark: true, season: nil) == 0x0E0E0E)
        #expect(SeasonalColor.resolve(light: 0xF7F7F8, dark: 0x0E0E0E, token: .surface, isDark: false, season: nil) == 0xF7F7F8)
    }

    @Test("Dark mode in season: the season's value")
    func darkInSeason() {
        #expect(SeasonalColor.resolve(light: 0xF7F7F8, dark: 0x0E0E0E, token: .surface, isDark: true, season: halloween) == 0x0C0A10)
    }

    @Test("Light mode, season without light palette: untouched")
    func lightWithoutLightPalette() {
        #expect(SeasonalColor.resolve(light: 0xF7F7F8, dark: 0x0E0E0E, token: .surface, isDark: false, season: halloween) == 0xF7F7F8)
    }

    @Test("A token the season does not cover is never repainted")
    func uncoveredToken() {
        #expect(SeasonalColor.resolve(light: 0xC0392B, dark: 0xEE7D77, token: nil, isDark: true, season: halloween) == 0xEE7D77)
    }

    // MARK: The chain, link by link
    //
    // An off-screen test window never commits SwiftUI content (only the
    // hosting view's system background came out), so the chain is proven one
    // link at a time: UIKit provider ← trait, SwiftUI paint ← environment,
    // environment ← window / scene trait (the bridge).

    private func hex(_ color: UIColor) -> UInt {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt((r * 255).rounded()) << 16 | UInt((g * 255).rounded()) << 8 | UInt((b * 255).rounded())
    }

    private func resolved(_ color: Color, dark: Bool, season: String?) -> UInt {
        let traits = UITraitCollection { t in
            t.userInterfaceStyle = dark ? .dark : .light
            t[SeasonTrait.self] = season
        }
        return hex(UIColor(color).resolvedColor(with: traits))
    }

    @Test("UIKit: the provider reads the season trait")
    func providerReadsTheTrait() {
        #expect(resolved(CinemaColor.surface, dark: true, season: nil) == 0x0E0E0E)
        #expect(resolved(CinemaColor.surface, dark: true, season: "halloween") == 0x0C0A10)
        #expect(resolved(CinemaColor.onSurface, dark: true, season: "halloween") == 0xF1E9E0)
        #expect(resolved(CinemaColor.error, dark: true, season: "halloween") == 0xEE7D77)
    }

    @Test("Light surface ignores a season without light palette")
    func lightSurfaceIgnoresASeasonWithoutLightPalette() {
        #expect(resolved(CinemaColor.surface, dark: false, season: "halloween") == 0xF7F7F8)
    }

    private func painted(season: String?) -> UInt {
        let renderer = ImageRenderer(content: CinemaColor.surface
            .frame(width: 8, height: 8)
            .environment(\.colorScheme, .dark)
            .environment(\.seasonID, season))
        renderer.scale = 1
        let cg = renderer.cgImage!
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -4, y: -4, width: cg.width, height: cg.height))
        return UInt(px[0]) << 16 | UInt(px[1]) << 8 | UInt(px[2])
    }

    private func close(_ a: UInt, _ b: UInt) -> Bool {
        [16, 8, 0].allSatisfy { abs(Int((a >> UInt($0)) & 255) - Int((b >> UInt($0)) & 255)) <= 2 }
    }

    @Test("SwiftUI: a CinemaColor paints the season from the environment")
    func swiftUIPaintsFromTheEnvironment() {
        let plain = painted(season: nil), season = painted(season: "halloween")
        #expect(close(plain, 0x0E0E0E), "painted #\(String(plain, radix: 16))")
        #expect(close(season, 0x0C0A10), "painted #\(String(season, radix: 16))")
    }

    /// Records the `\.seasonID` its body sees.
    private final class Seen: @unchecked Sendable { var id: String?? = .none }
    private struct Probe: View {
        let seen: Seen
        @Environment(\.seasonID) private var seasonID
        var body: some View {
            seen.id = .some(seasonID)
            return Color.clear
        }
    }

    @Test("Changing the trait redraws live: window trait reaches the environment")
    func changingTheTraitRedrawsLive() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let seen = Seen()
        window.rootViewController = UIHostingController(rootView: Probe(seen: seen))
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        #expect(seen.id == .some(nil))
        window.traitOverrides[SeasonTrait.self] = "halloween"
        window.layoutIfNeeded()
        window.rootViewController?.view.layoutIfNeeded()
        #expect(seen.id == .some("halloween"))
        window.traitOverrides[SeasonTrait.self] = nil
        window.layoutIfNeeded()
        window.rootViewController?.view.layoutIfNeeded()
        #expect(seen.id == .some(nil))
    }
}

@Suite("Season trait applier", .serialized)
@MainActor
struct SeasonTraitApplierTests {
    /// The applier writes the test host's REAL scene; every test leaves it
    /// without a season override, as the app starts.
    private func hosted() throws -> (UIWindow, SeasonTraitApplierView, UIWindowScene) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let view = SeasonTraitApplierView()
        window.addSubview(view)
        return (window, view, scene)
    }

    @Test("No season on a scene that never had one: no override, no crash")
    func noSeasonNoOverride() throws {
        let (window, view, scene) = try hosted()
        view.setSeasonID(nil)
        #expect(!scene.traitOverrides.contains(SeasonTrait.self))
        _ = window
    }

    @Test("A season is written on the scene, and removed when it ends")
    func writesAndRemoves() throws {
        let (window, view, scene) = try hosted()
        defer { if scene.traitOverrides.contains(SeasonTrait.self) { scene.traitOverrides.remove(SeasonTrait.self) } }
        view.setSeasonID("halloween")
        #expect(scene.traitOverrides.contains(SeasonTrait.self))
        #expect(scene.traitOverrides[SeasonTrait.self] == "halloween")
        view.setSeasonID(nil)
        #expect(!scene.traitOverrides.contains(SeasonTrait.self))
        _ = window
    }
}
