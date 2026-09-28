import Testing
import UIKit
@testable import Cinemax

@MainActor
@Suite("Seasonal ambiance", .serialized)
struct SeasonalAmbianceTests {
    private func hosted() -> (UIWindow, AmbianceView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 600))
        let view = AmbianceView(frame: window.bounds)
        window.addSubview(view)
        return (window, view)
    }

    @Test("Mist: three drifting layers, gone when turned off")
    func mist() {
        let (window, view) = hosted()
        view.setEffects([.mist])
        #expect(view.mistLayers.count == 3)
        #expect(view.mistLayers.allSatisfy { $0.animation(forKey: AmbianceView.mistKey) != nil })
        // The moving smoke: a particle emitter rising from the bottom edge.
        let fog = view.fogEmitter
        #expect(fog != nil)
        #expect(fog?.emitterCells?.isEmpty == false)
        #expect((fog?.emitterPosition.y ?? 0) >= view.bounds.height)
        view.setEffects([])
        #expect(view.mistLayers.isEmpty)
        #expect(view.fogEmitter == nil)
        _ = window
    }

    @Test("Bats fly once per session")
    func batsOnce() {
        AmbianceView.batsFlownThisSession = false
        let (w1, first) = hosted()
        first.setEffects([.bats])
        first.layoutIfNeeded()
        #expect(first.batLayers.count == 3)
        #expect(AmbianceView.batsFlownThisSession)
        let (w2, second) = hosted()
        second.setEffects([.bats])
        second.layoutIfNeeded()
        #expect(second.batLayers.isEmpty)
        _ = (w1, w2)
    }

    @Test("A witch crosses on a long repeating cycle, gone when turned off")
    func witch() {
        let (window, view) = hosted()
        view.setEffects([.witches])
        view.layoutIfNeeded()
        let flight = view.witchLayer?.animation(forKey: AmbianceView.witchKey) as? CAAnimationGroup
        #expect(flight?.repeatCount == .infinity)
        #expect((flight?.duration ?? 0) >= 60)
        view.setEffects([])
        #expect(view.witchLayer == nil)
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
