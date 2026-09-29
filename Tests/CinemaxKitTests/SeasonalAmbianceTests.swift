import Testing
import UIKit
@testable import Cinemax

@MainActor
@Suite("Seasonal ambiance")
struct SeasonalAmbianceTests {
    private func hosted(_ plane: AmbiancePlane, elapsed: TimeInterval = 0) -> (UIWindow, AmbianceView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 600))
        let view = AmbianceView(plane: plane, clock: { elapsed })
        view.frame = window.bounds
        window.addSubview(view)
        return (window, view)
    }

    #if os(tvOS)
    private let isTV = true
    #else
    private let isTV = false
    #endif

    @Test("Far plane: small dim bats on endless loops, from the first seconds")
    func farBats() throws {
        let (window, view) = hosted(.far)
        view.setEffects([.bats])
        view.layoutIfNeeded()
        #expect(view.batLayers.count == AmbiancePolicy.batCount(dense: AmbianceView.farBatCount, elapsed: 0, isTV: isTV))
        let first = try #require(view.batLayers.first?.animation(forKey: AmbianceView.batKey) as? CAAnimationGroup)
        #expect(first.repeatCount == .infinity)
        #expect((first.animations?.first?.beginTime ?? 99) <= 4)
        view.setEffects([])
        #expect(view.batLayers.isEmpty)
        _ = window
    }

    @Test("During the opening, the extra bats stop after it, on a crossing boundary")
    func extraBatsEndAfterTheIntro() throws {
        let (window, view) = hosted(.far, elapsed: 10)
        view.setEffects([.bats])
        view.layoutIfNeeded()
        let calm = AmbiancePolicy.batCount(dense: AmbianceView.farBatCount, elapsed: 999, isTV: isTV)
        let extras = view.batLayers.dropFirst(calm)
        #expect(!extras.isEmpty)
        for bat in extras {
            let cycle = try #require(bat.animation(forKey: AmbianceView.batKey) as? CAAnimationGroup)
            #expect(cycle.repeatCount == 0)
            #expect(cycle.repeatDuration >= 20)               // outlives the remaining opening
            let rounds = cycle.repeatDuration / cycle.duration
            #expect(abs(rounds - rounds.rounded()) < 0.001)   // ends between two crossings
        }
        _ = window
    }

    @Test("After the opening, a new screen only gets the calm count")
    func calmAfterIntro() {
        let (window, view) = hosted(.far, elapsed: 120)
        view.setEffects([.bats])
        view.layoutIfNeeded()
        #expect(view.batLayers.count == AmbiancePolicy.batCount(dense: AmbianceView.farBatCount, elapsed: 120, isTV: isTV))
        _ = window
    }

    @Test("Near plane: two large bats at most")
    func nearBats() {
        let (window, view) = hosted(.near)
        view.setEffects([.bats])
        view.layoutIfNeeded()
        #expect(view.batLayers.count <= 2)
        #expect(!view.batLayers.isEmpty)
        _ = window
    }

    @Test("Pumpkins fall (longitude π); far = plain + carved, near = lit only")
    func pumpkins() {
        let (w1, far) = hosted(.far)
        far.setEffects([.pumpkins])
        far.layoutIfNeeded()
        let cells = far.pumpkinEmitter?.emitterCells ?? []
        #expect(cells.count == 2)
        #expect(cells.allSatisfy { $0.emissionLongitude == .pi && $0.contents != nil })
        #expect((far.pumpkinEmitter?.emitterPosition.y ?? 1) <= 0)
        let (w2, near) = hosted(.near)
        near.setEffects([.pumpkins])
        near.layoutIfNeeded()
        #expect(near.pumpkinEmitter?.emitterCells?.count == 1)
        near.setEffects([])
        #expect(near.pumpkinEmitter == nil)
        _ = (w1, w2)
    }

    @Test("Off-window, nothing is added until the window")
    func offWindow() {
        let view = AmbianceView(plane: .far, clock: { 0 })
        view.frame = CGRect(x: 0, y: 0, width: 1200, height: 600)
        view.setEffects([.bats])
        #expect(view.batLayers.isEmpty)
        let window = UIWindow(frame: view.frame)
        window.addSubview(view)
        view.layoutIfNeeded()
        #expect(!view.batLayers.isEmpty)
    }

    // MARK: Night sky

    @Test("Night sky: stars in dark mode only, webs in both, twinkle only with motion")
    func nightSky() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let sky = NightSkyView(frame: window.bounds)
        window.addSubview(sky)
        sky.configure(dark: true, twinkle: true)
        sky.layoutIfNeeded()
        #expect(sky.starLayer.path?.isEmpty == false)
        #expect(sky.webLayers.count == 2)
        #expect(!sky.twinkleLayers.isEmpty)
        #expect(sky.twinkleLayers.allSatisfy { $0.animation(forKey: NightSkyView.twinkleKey) != nil })
        sky.configure(dark: false, twinkle: false)
        sky.layoutIfNeeded()
        #expect(sky.starLayer.path == nil || sky.starLayer.path?.isEmpty == true)
        #expect(sky.webLayers.count == 2)
        #expect(sky.twinkleLayers.allSatisfy { $0.animation(forKey: NightSkyView.twinkleKey) == nil })
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
