import Testing
import UIKit
@testable import Cinemax

/// Light-mode hero (recette 2026-11-15): Home and the library show their
/// backdrop with no shade on iOS; dark mode, tvOS and the fiche keep the
/// gradient — see `HeroBackdropShade`.
@Suite("Hero backdrop shade")
struct HeroBackdropShadeTests {
    @Test("only a light-mode iOS hero that opts in loses its gradient")
    func resolve() {
        #expect(HeroBackdropShade.resolve(isLight: true, clearInLightMode: true, isTV: false) == .none)
        #expect(HeroBackdropShade.resolve(isLight: false, clearInLightMode: true, isTV: false) == .gradient)
        #expect(HeroBackdropShade.resolve(isLight: true, clearInLightMode: false, isTV: false) == .gradient)
        #expect(HeroBackdropShade.resolve(isLight: true, clearInLightMode: true, isTV: true) == .gradient)
    }
}

/// Light-mode hero text (recette 2026-11-15, owner's choice « 3 »): the
/// text block takes the dark-mode look over a dark backdrop and keeps the
/// page's light tokens over a light one — see `HeroTextTone`.
@Suite("Hero text tone")
struct HeroTextToneTests {
    @Test("a black or saturated dark backdrop takes light text")
    func darkBackdrop() {
        #expect(HeroTextTone.resolve(red: 0, green: 0, blue: 0) == .onDark)
        #expect(HeroTextTone.resolve(red: 0.25, green: 0.12, blue: 0.4) == .onDark)
    }

    @Test("a white or pale backdrop keeps the page's dark text")
    func lightBackdrop() {
        #expect(HeroTextTone.resolve(red: 1, green: 1, blue: 1) == .standard)
        #expect(HeroTextTone.resolve(red: 0.92, green: 0.92, blue: 0.93) == .standard)
    }

    /// Decided on the meta line's grey, the block's weakest text: on a mid
    /// green (L ≈ 0.19) the dark title read, « 0m » in grey did not.
    @Test("the tone flips where the light meta grey starts to read better than the dark one")
    func threshold() {
        // #808080 (L ≈ 0.22): dark grey 1.81:1, light grey 1.72:1 → dark.
        #expect(HeroTextTone.resolve(red: 0x80 / 255.0, green: 0x80 / 255.0, blue: 0x80 / 255.0) == .standard)
        // #777777 (L ≈ 0.18): light grey 1.95:1 against dark 1.59:1 → light.
        #expect(HeroTextTone.resolve(red: 0x77 / 255.0, green: 0x77 / 255.0, blue: 0x77 / 255.0) == .onDark)
        // The bench's mid green #2E8A3A (L ≈ 0.19) → light.
        #expect(HeroTextTone.resolve(red: 0x2E / 255.0, green: 0x8A / 255.0, blue: 0x3A / 255.0) == .onDark)
    }

    /// A 16:9 backdrop in a portrait phone hero is cropped SIDEWAYS (centred):
    /// only its middle shows, and the text sits on that middle's lower left.
    @Test("a wide image in a portrait hero samples the visible middle, low and left")
    func wideImageSample() throws {
        let rect = try #require(HeroTextTone.sampleRect(imageSize: CGSize(width: 1920, height: 1080),
                                           heroSize: CGSize(width: 402, height: 480)))
        let visible = (402.0 / 480.0) / (1920.0 / 1080.0)
        #expect(abs(rect.minX - (1 - visible) / 2) < 0.001)
        #expect(abs(rect.width - visible * 0.8) < 0.001)
        #expect(abs(rect.minY - 0.55) < 0.001)
        #expect(abs(rect.maxY - 1) < 0.001)
    }

    /// A backdrop narrower than the hero (iPad landscape) is cropped
    /// VERTICALLY and anchored to the TOP (`heroBackdropBleed`), so the text
    /// sits over the lower part of the image's visible top band.
    @Test("a tall image in a wide hero samples the top band's lower left")
    func tallImageSample() throws {
        let rect = try #require(HeroTextTone.sampleRect(imageSize: CGSize(width: 1600, height: 1000),
                                           heroSize: CGSize(width: 1200, height: 460)))
        let visible = (1600.0 / 1000.0) / (1200.0 / 460.0)
        #expect(abs(rect.minX) < 0.001)
        #expect(abs(rect.width - 0.8) < 0.001)
        #expect(abs(rect.minY - visible * 0.55) < 0.001)
        #expect(abs(rect.maxY - visible) < 0.001)
    }

    /// Chernobyl (recette 2026-11-15): over an unshaded image the meta line's
    /// GREY (rating, year, genre) read far worse than the title next to it —
    /// so over an image it takes the title's colour, sharpened by a tight
    /// shadow when it is light. Under dark mode's gradient it stays grey.
    @Test("over an image the meta line takes the title's colour")
    func metaLineStyle() {
        #expect(HeroTextTone.metaStyle(over: nil) == .init(usesPrimaryText: false, sharpShadow: false))
        #expect(HeroTextTone.metaStyle(over: .standard) == .init(usesPrimaryText: true, sharpShadow: false))
        #expect(HeroTextTone.metaStyle(over: .onDark) == .init(usesPrimaryText: true, sharpShadow: true))
    }

    @Test("a degenerate size samples nothing")
    func degenerate() {
        #expect(HeroTextTone.sampleRect(imageSize: .zero, heroSize: CGSize(width: 400, height: 400)) == nil)
        #expect(HeroTextTone.sampleRect(imageSize: CGSize(width: 10, height: 10), heroSize: .zero) == nil)
    }
}

#if os(tvOS)
/// The tvOS hero drift runs as a Core Animation animation on the backdrop's
/// image layer (render server), no longer as a SwiftUI `.repeatForever`
/// ticked on the main thread — see `HeroDrift`.
@MainActor
@Suite("Hero backdrop drift")
struct HeroBackdropDriftTests {
    private func hosted() -> (UIWindow, DriftingBackdropView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let view = DriftingBackdropView(frame: window.bounds)
        window.addSubview(view)
        return (window, view)
    }

    @Test("Drifting adds the layer animation")
    func driftAddsAnimation() {
        let (window, view) = hosted()
        view.setDrifting(true)
        let animation = view.imageView.layer.animation(forKey: HeroDrift.animationKey) as? CABasicAnimation
        #expect(animation?.keyPath == "transform.scale")
        #expect(animation?.toValue as? CGFloat == HeroDrift.scale)
        #expect(animation?.autoreverses == true)
        #expect(animation?.repeatCount == .infinity)
        _ = window
    }

    @Test("Motion off removes it")
    func motionOffRemovesAnimation() {
        let (window, view) = hosted()
        view.setDrifting(true)
        view.setDrifting(false)
        #expect(view.imageView.layer.animation(forKey: HeroDrift.animationKey) == nil)
        _ = window
    }

    @Test("Off-window, the drift waits for the window")
    func driftWaitsForWindow() {
        let view = DriftingBackdropView(frame: .zero)
        view.setDrifting(true)
        #expect(view.imageView.layer.animation(forKey: HeroDrift.animationKey) == nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.addSubview(view)
        #expect(view.imageView.layer.animation(forKey: HeroDrift.animationKey) != nil)
    }

    @Test("A failed load retries on the next window entry")
    func failedLoadRetriesOnWindowEntry() async {
        let view = DriftingBackdropView(frame: .zero)
        view.load(URL(fileURLWithPath: "/nonexistent/cinemax-hero-\(UUID().uuidString).jpg"))
        await view.loadTask?.value
        #expect(view.hasFailedLoad)
        #expect(view.imageView.image == nil)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.addSubview(view)
        #expect(!view.hasFailedLoad)
        #expect(view.loadTask != nil)
        await view.loadTask?.value
        #expect(view.hasFailedLoad)
    }

    @Test("The same URL again is not refetched")
    func sameURLIsNoOp() async {
        let view = DriftingBackdropView(frame: .zero)
        let url = URL(fileURLWithPath: "/nonexistent/cinemax-hero-\(UUID().uuidString).jpg")
        view.load(url)
        await view.loadTask?.value
        view.load(url)
        #expect(view.hasFailedLoad)
    }

    @Test("The backdrop never takes a touch or focus")
    func backdropIsInert() {
        let view = DriftingBackdropView(frame: .zero)
        #expect(!view.isUserInteractionEnabled)
        #expect(view.clipsToBounds)
    }
}
#endif
