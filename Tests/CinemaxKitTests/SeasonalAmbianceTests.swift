import Testing
import UIKit
@testable import Cinemax

@MainActor
@Suite("Seasonal ambiance")
struct SeasonalAmbianceTests {
    private func hosted() -> (UIWindow, AmbianceView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 600))
        let view = AmbianceView(frame: window.bounds)
        window.addSubview(view)
        return (window, view)
    }

    @Test("Mist: a fog bank and smoke rising from the bottom band, gone when turned off")
    func mist() {
        let (window, view) = hosted()
        view.setEffects([.mist])
        #expect(view.mistLayers.count == 3)
        #expect(view.mistLayers.allSatisfy { $0.animation(forKey: AmbianceView.mistKey) != nil })
        // The moving smoke: emitted INSIDE the bottom band, so it shows at once.
        let fog = view.fogEmitter
        #expect(fog != nil)
        #expect(fog?.emitterCells?.isEmpty == false)
        // Longitude 0 rises (see the pumpkins): at ±π/2 the smoke slid out
        // sideways along the bottom edge.
        #expect(fog?.emitterCells?.first?.emissionLongitude == 0)
        #expect((fog?.emitterPosition.y ?? 0) >= view.bounds.height * 0.8)
        #expect((fog?.emitterPosition.y ?? .infinity) <= view.bounds.height)
        view.setEffects([])
        #expect(view.mistLayers.isEmpty)
        #expect(view.fogEmitter == nil)
        _ = window
    }

    @Test("Bats keep crossing from the first seconds, never just once")
    func batsKeepFlying() throws {
        let (window, view) = hosted()
        view.setEffects([.bats])
        view.layoutIfNeeded()
        #expect(view.batLayers.count >= 8)
        for bat in view.batLayers {
            let cycle = try #require(bat.animation(forKey: AmbianceView.batKey) as? CAAnimationGroup)
            #expect(cycle.repeatCount == .infinity)
            let fly = try #require(cycle.animations?.first)
            #expect(fly.beginTime <= 4)             // the first crossing starts at once
        }
        // A second screen gets its own bats: no once-per-session latch any more.
        let (window2, other) = hosted()
        other.setEffects([.bats])
        other.layoutIfNeeded()
        #expect(other.batLayers.count >= 8)
        view.setEffects([])
        #expect(view.batLayers.isEmpty)
        _ = (window, window2)
    }

    @Test("Pumpkins fall from the top edge, gone when turned off")
    func pumpkins() {
        let (window, view) = hosted()
        view.setEffects([.pumpkins])
        view.layoutIfNeeded()
        let fall = view.pumpkinEmitter
        #expect(fall != nil)
        #expect(fall?.emitterCells?.first?.contents != nil)
        // An emitter's longitude 0 points UP the screen and π DOWN (±π/2 go
        // sideways — the pumpkins left through the side edges at first).
        #expect(fall?.emitterCells?.first?.emissionLongitude == .pi)
        #expect((fall?.emitterCells?.first?.yAcceleration ?? 0) > 0)
        #expect((fall?.emitterPosition.y ?? 1) <= 0)
        view.setEffects([])
        #expect(view.pumpkinEmitter == nil)
        _ = window
    }

    @Test("Off-window, nothing is added until the window")
    func offWindow() {
        let view = AmbianceView(frame: CGRect(x: 0, y: 0, width: 1200, height: 600))
        view.setEffects([.mist])
        #expect(view.mistLayers.isEmpty)
        let window = UIWindow(frame: view.frame)
        window.addSubview(view)
        #expect(view.mistLayers.count == 3)
    }

    @Test("Mist added before its frame drifts by a share of the final width")
    func mistDriftUsesTheLaidOutWidth() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 600))
        let view = AmbianceView(frame: .zero)          // SwiftUI sizes it later
        window.addSubview(view)
        view.setEffects([.mist])
        view.frame = window.bounds
        view.layoutIfNeeded()
        let drift = try #require(view.mistLayers.first?.animation(forKey: AmbianceView.mistKey) as? CABasicAnimation)
        let toValue = try #require(drift.toValue as? CGFloat)
        #expect(abs(toValue) > 10, "drift \(toValue) pt")
    }

    #if os(tvOS)
    @Test("Focus glow pulses only while focused")
    func focusGlow() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let glow = SeasonalFocusGlowView(frame: CGRect(x: 50, y: 50, width: 200, height: 120))
        window.addSubview(glow)
        glow.setGlowing(true)
        #expect(glow.layer.animation(forKey: SeasonalFocusGlowView.animationKey) != nil)
        glow.setGlowing(false)
        #expect(glow.layer.animation(forKey: SeasonalFocusGlowView.animationKey) == nil)
        #expect(glow.layer.shadowOpacity == 0)
    }
    #endif
}
