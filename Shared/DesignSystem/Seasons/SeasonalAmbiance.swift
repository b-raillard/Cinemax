import SwiftUI
import UIKit

// MARK: - Seasonal ambiance
//
// Core Animation only (render server), like `HeroDrift`: a SwiftUI
// `.repeatForever` ticks on the main thread every frame, which cost the Apple
// TV 4K ~10–12 % CPU on an idle Home (lot 8). Not interactive, hidden from
// VoiceOver, ABSENT (not frozen) when `AmbiancePolicy` says no.

extension EnvironmentValues {
    /// The « Animations d'ambiance » switch, written ONCE at the root from
    /// `SeasonalThemeController` — every card reads it for the tvOS focus
    /// glow, and one `@AppStorage` observer per card was the cost to avoid.
    @Entry var seasonalAmbianceEnabled: Bool = true
}

/// Laid over a hero, above its gradient.
struct SeasonalAmbianceOverlay: View {
    @Environment(\.seasonID) private var seasonID
    @Environment(\.motionEffectsEnabled) private var motionEnabled
    @Environment(\.seasonalAmbianceEnabled) private var ambianceEnabled

    var body: some View {
        let effects = AmbiancePolicy.effects(
            theme: SeasonalThemeCatalogue.theme(id: seasonID),
            ambianceEnabled: ambianceEnabled, motionEnabled: motionEnabled
        ).intersection([.mist, .bats])
        if !effects.isEmpty {
            AmbianceRepresentable(effects: effects)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct AmbianceRepresentable: UIViewRepresentable {
    let effects: Set<AmbianceEffect>
    func makeUIView(context: Context) -> AmbianceView { AmbianceView() }
    func updateUIView(_ view: AmbianceView, context: Context) { view.setEffects(effects) }
}

final class AmbianceView: UIView {
    static let mistKey = "cinemax.ambiance.mist"
    static let batKey = "cinemax.ambiance.bat"
    /// Bats cross ONE hero per app session — rare, as the canvas asks.
    static var batsFlownThisSession = false

    private(set) var mistLayers: [CAGradientLayer] = []
    private(set) var batLayers: [CALayer] = []
    private var effects: Set<AmbianceEffect> = []
    private var batsPending = false

    /// A mist blob, in fractions of the hero.
    private struct MistBlob {
        let frame: CGRect
        let opacity: CGFloat
        let drift: CGFloat
        let period: CFTimeInterval
    }

    /// One bat's crossing: its size, its height (fraction of the hero), when and how long.
    private struct BatFlight {
        let scale: CGFloat
        let y: CGFloat
        let delay: CFTimeInterval
        let duration: CFTimeInterval
    }

    private static let mist: [MistBlob] = [
        MistBlob(frame: CGRect(x: -0.10, y: 0.70, width: 0.80, height: 0.40), opacity: 0.14, drift: 0.06, period: 22),
        MistBlob(frame: CGRect(x: 0.35, y: 0.76, width: 0.80, height: 0.34), opacity: 0.10, drift: -0.05, period: 26),
        MistBlob(frame: CGRect(x: 0.05, y: 0.84, width: 1.00, height: 0.32), opacity: 0.18, drift: 0.04, period: 30)
    ]
    private static let mistColor = UIColor(red: 0xCF / 255, green: 0xC3 / 255, blue: 0xE6 / 255, alpha: 1)
    private static let batColor = UIColor(red: 0xB3 / 255, green: 0xA8 / 255, blue: 0xB8 / 255, alpha: 0.75)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setEffects(_ newValue: Set<AmbianceEffect>) {
        guard newValue != effects else { return }
        effects = newValue
        rebuild()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        rebuild()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutMist()
        startMistDrift()
        if batsPending, bounds.width > 0 { launchBats() }
    }

    private func rebuild() {
        mistLayers.forEach { $0.removeFromSuperlayer() }
        mistLayers = []
        batLayers.forEach { $0.removeFromSuperlayer() }
        batLayers = []
        batsPending = false
        guard window != nil else { return }
        if effects.contains(.mist) { addMist() }
        if effects.contains(.bats), !Self.batsFlownThisSession {
            Self.batsFlownThisSession = true
            batsPending = true
            if bounds.width > 0 { launchBats() }
        }
    }

    private func addMist() {
        for blob in Self.mist {
            let l = CAGradientLayer()
            l.type = .radial
            l.colors = [Self.mistColor.withAlphaComponent(blob.opacity).cgColor, Self.mistColor.withAlphaComponent(0).cgColor]
            l.startPoint = CGPoint(x: 0.5, y: 0.5)
            l.endPoint = CGPoint(x: 1, y: 1)
            layer.addSublayer(l)
            mistLayers.append(l)
        }
        layoutMist()
        startMistDrift()
    }

    /// The drift is a share of the hero's WIDTH, so it waits for one: SwiftUI
    /// gives the representable its frame after `didMoveToWindow`, and a drift
    /// computed at width 0 left the mist still.
    private func startMistDrift() {
        guard bounds.width > 0 else { return }
        for (l, blob) in zip(mistLayers, Self.mist) where l.animation(forKey: Self.mistKey) == nil {
            let a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = 0
            a.toValue = bounds.width * blob.drift
            a.duration = blob.period
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.isRemovedOnCompletion = false
            l.add(a, forKey: Self.mistKey)
        }
    }

    private func layoutMist() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (l, blob) in zip(mistLayers, Self.mist) {
            l.frame = CGRect(x: blob.frame.minX * bounds.width, y: blob.frame.minY * bounds.height,
                             width: blob.frame.width * bounds.width, height: blob.frame.height * bounds.height)
        }
        CATransaction.commit()
    }

    /// The canvas's bat silhouette, 80 × 20 around its origin.
    private static func batPath() -> CGPath {
        let p = UIBezierPath()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: -6, y: -8))
        p.addLine(to: CGPoint(x: -7, y: -3))
        p.addCurve(to: CGPoint(x: -40, y: -6), controlPoint1: CGPoint(x: -14, y: -10), controlPoint2: CGPoint(x: -26, y: -12))
        p.addCurve(to: CGPoint(x: -28, y: 8), controlPoint1: CGPoint(x: -32, y: -4), controlPoint2: CGPoint(x: -28, y: 2))
        p.addCurve(to: CGPoint(x: -10, y: 10), controlPoint1: CGPoint(x: -22, y: 3), controlPoint2: CGPoint(x: -14, y: 4))
        p.addCurve(to: CGPoint(x: 0, y: 6), controlPoint1: CGPoint(x: -8, y: 5), controlPoint2: CGPoint(x: -4, y: 4))
        p.addCurve(to: CGPoint(x: 10, y: 10), controlPoint1: CGPoint(x: 4, y: 4), controlPoint2: CGPoint(x: 8, y: 5))
        p.addCurve(to: CGPoint(x: 28, y: 8), controlPoint1: CGPoint(x: 14, y: 4), controlPoint2: CGPoint(x: 22, y: 3))
        p.addCurve(to: CGPoint(x: 40, y: -6), controlPoint1: CGPoint(x: 28, y: 2), controlPoint2: CGPoint(x: 32, y: -4))
        p.addCurve(to: CGPoint(x: 7, y: -3), controlPoint1: CGPoint(x: 26, y: -12), controlPoint2: CGPoint(x: 14, y: -10))
        p.addLine(to: CGPoint(x: 6, y: -8))
        p.close()
        return p.cgPath
    }

    private func launchBats() {
        batsPending = false
        let w = bounds.width, h = bounds.height
        let flights = [
            BatFlight(scale: 1.0, y: 0.22, delay: 0.4, duration: 6.5),
            BatFlight(scale: 0.7, y: 0.30, delay: 1.6, duration: 7.5),
            BatFlight(scale: 0.5, y: 0.16, delay: 2.4, duration: 8.5)
        ]
        for flight in flights {
            let container = CALayer()
            container.position = CGPoint(x: -100, y: -100)   // off-screen between flights
            let shape = CAShapeLayer()
            shape.path = Self.batPath()
            shape.fillColor = Self.batColor.cgColor
            shape.setAffineTransform(CGAffineTransform(scaleX: flight.scale, y: flight.scale))
            container.addSublayer(shape)
            layer.addSublayer(container)
            batLayers.append(container)

            let path = UIBezierPath()
            path.move(to: CGPoint(x: -60, y: h * (flight.y + 0.08)))
            path.addQuadCurve(to: CGPoint(x: w + 60, y: h * flight.y), controlPoint: CGPoint(x: w * 0.5, y: h * (flight.y - 0.1)))
            let fly = CAKeyframeAnimation(keyPath: "position")
            fly.path = path.cgPath
            fly.duration = flight.duration
            fly.beginTime = CACurrentMediaTime() + flight.delay
            fly.fillMode = .backwards
            fly.calculationMode = .paced
            container.add(fly, forKey: Self.batKey)

            let flap = CABasicAnimation(keyPath: "transform.scale.y")
            flap.fromValue = flight.scale
            flap.toValue = flight.scale * 0.55
            flap.duration = 0.16
            flap.autoreverses = true
            // Flaps for the flight only — no animation left running on a bat
            // parked off-screen afterwards.
            flap.repeatCount = Float((flight.delay + flight.duration) / (flap.duration * 2)) + 1
            shape.add(flap, forKey: Self.batKey)
        }
    }
}

#if os(tvOS)
/// The canvas's « lueur » — a pumpkin halo that flickers slowly behind the
/// focused card. A layer shadow animated by Core Animation.
struct SeasonalFocusGlow: UIViewRepresentable {
    let active: Bool
    let color: Color
    let cornerRadius: CGFloat

    func makeUIView(context: Context) -> SeasonalFocusGlowView { SeasonalFocusGlowView() }

    func updateUIView(_ view: SeasonalFocusGlowView, context: Context) {
        view.glowColor = UIColor(color)
        view.cornerRadius = cornerRadius
        view.setGlowing(active)
    }
}

final class SeasonalFocusGlowView: UIView {
    static let animationKey = "cinemax.season.focusGlow"
    /// Resolved in `layoutSubviews`; a new colour (season, accent, dark mode)
    /// asks for one.
    var glowColor: UIColor = .clear { didSet { setNeedsLayout() } }
    var cornerRadius: CGFloat = 0
    private(set) var isGlowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.shadowOffset = .zero
        layer.shadowRadius = 30
        layer.shadowOpacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setGlowing(_ glowing: Bool) {
        guard glowing != isGlowing else { return }
        isGlowing = glowing
        apply()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).cgPath
        layer.shadowColor = glowColor.resolvedColor(with: traitCollection).cgColor
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    private func apply() {
        if isGlowing, window != nil {
            layer.shadowOpacity = 0.35
            if layer.animation(forKey: Self.animationKey) == nil {
                let a = CABasicAnimation(keyPath: "shadowOpacity")
                a.fromValue = 0.35
                a.toValue = 0.75
                a.duration = 1.4
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.isRemovedOnCompletion = false
                layer.add(a, forKey: Self.animationKey)
            }
        } else if !isGlowing {
            layer.removeAnimation(forKey: Self.animationKey)
            layer.shadowOpacity = 0
        }
    }
}
#endif
