import Testing
import UIKit
@testable import Cinemax

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

    @Test("The backdrop never takes a touch or focus")
    func backdropIsInert() {
        let view = DriftingBackdropView(frame: .zero)
        #expect(!view.isUserInteractionEnabled)
        #expect(view.clipsToBounds)
    }
}
#endif
