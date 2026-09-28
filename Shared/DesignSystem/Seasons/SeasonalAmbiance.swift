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

/// Laid over the WHOLE app (`AppNavigation`, above the tabs and every pushed
/// screen; under sheets and the player, which are their own presentations).
/// Never interactive, never read by VoiceOver.
struct SeasonalAmbianceOverlay: View {
    @Environment(\.seasonID) private var seasonID
    @Environment(\.motionEffectsEnabled) private var motionEnabled
    @Environment(\.seasonalAmbianceEnabled) private var ambianceEnabled

    var body: some View {
        let effects = AmbiancePolicy.effects(
            theme: SeasonalThemeCatalogue.theme(id: seasonID),
            ambianceEnabled: ambianceEnabled, motionEnabled: motionEnabled
        ).intersection([.mist, .bats, .witches])
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
    static let witchKey = "cinemax.ambiance.witch"
    /// Bats cross ONCE per app session — rare, as the canvas asks.
    static var batsFlownThisSession = false

    /// The fog bank lying along the bottom edge (slow horizontal drift).
    private(set) var mistLayers: [CAGradientLayer] = []
    /// The moving smoke: soft puffs rising from below the bottom edge, growing,
    /// turning and dissolving — what makes the fog read as smoke.
    private(set) var fogEmitter: CAEmitterLayer?
    private(set) var batLayers: [CALayer] = []
    private(set) var witchLayer: CALayer?
    private var effects: Set<AmbianceEffect> = []
    private var batsPending = false
    private var witchPending = false

    /// A fog-bank blob, in fractions of the screen.
    private struct MistBlob {
        let frame: CGRect
        let opacity: CGFloat
        let drift: CGFloat
        let period: CFTimeInterval
    }

    /// One bat's crossing: its size, its height (fraction of the screen), when and how long.
    private struct BatFlight {
        let scale: CGFloat
        let y: CGFloat
        let delay: CFTimeInterval
        let duration: CFTimeInterval
    }

    /// A witch crosses 20 s after launch, then every 2 min 30 — rare enough to surprise.
    private enum WitchFlight {
        static let firstDelay: CFTimeInterval = 20
        static let duration: CFTimeInterval = 11
        static let period: CFTimeInterval = 150
    }

    private static let mist: [MistBlob] = [
        MistBlob(frame: CGRect(x: -0.10, y: 0.80, width: 0.80, height: 0.30), opacity: 0.10, drift: 0.06, period: 22),
        MistBlob(frame: CGRect(x: 0.35, y: 0.84, width: 0.80, height: 0.26), opacity: 0.07, drift: -0.05, period: 26),
        MistBlob(frame: CGRect(x: 0.05, y: 0.90, width: 1.00, height: 0.24), opacity: 0.12, drift: 0.04, period: 30)
    ]
    private static let mistColor = UIColor(red: 0xCF / 255, green: 0xC3 / 255, blue: 0xE6 / 255, alpha: 1)
    private static let batColor = UIColor(red: 0xB3 / 255, green: 0xA8 / 255, blue: 0xB8 / 255, alpha: 0.75)
    private static let witchColor = UIColor(red: 0x15 / 255, green: 0x11 / 255, blue: 0x1C / 255, alpha: 0.85)

    /// A soft round puff (white, radial alpha falloff) tinted by the emitter cell.
    private static let puffImage: CGImage? = {
        let size = CGSize(width: 128, height: 128)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0.5).cgColor, UIColor.white.withAlphaComponent(0).cgColor]
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.45, 1]) else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size.width / 2, options: [])
        }.cgImage
    }()

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
        layoutFog()
        startMistDrift()
        if batsPending, bounds.width > 0 { launchBats() }
        if witchPending, bounds.width > 0 { launchWitch() }
    }

    private func rebuild() {
        mistLayers.forEach { $0.removeFromSuperlayer() }
        mistLayers = []
        fogEmitter?.removeFromSuperlayer()
        fogEmitter = nil
        batLayers.forEach { $0.removeFromSuperlayer() }
        batLayers = []
        witchLayer?.removeFromSuperlayer()
        witchLayer = nil
        batsPending = false
        witchPending = false
        guard window != nil else { return }
        if effects.contains(.mist) {
            addMist()
            addFog()
        }
        if effects.contains(.bats), !Self.batsFlownThisSession {
            Self.batsFlownThisSession = true
            batsPending = true
            if bounds.width > 0 { launchBats() }
        }
        if effects.contains(.witches) {
            witchPending = true
            if bounds.width > 0 { launchWitch() }
        }
    }

    // MARK: Fog bank

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

    /// The drift is a share of the WIDTH, so it waits for one: SwiftUI gives
    /// the representable its frame after `didMoveToWindow`, and a drift
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

    // MARK: Rising smoke

    private func addFog() {
        let emitter = CAEmitterLayer()
        emitter.emitterShape = .line
        let cell = CAEmitterCell()
        cell.contents = Self.puffImage
        cell.birthRate = 0.9
        cell.lifetime = 20
        cell.lifetimeRange = 5
        cell.velocity = 24
        cell.velocityRange = 8
        cell.emissionLongitude = -.pi / 2           // up
        cell.emissionRange = .pi / 6
        cell.xAcceleration = 2.5                     // a breeze pushes it sideways
        cell.scale = 2.4
        cell.scaleRange = 0.8
        cell.scaleSpeed = 0.07                       // puffs swell as they rise
        cell.spin = 0.04
        cell.spinRange = 0.1                         // and turn slowly
        cell.color = Self.mistColor.withAlphaComponent(0.30).cgColor
        cell.alphaSpeed = -0.015                     // then dissolve
        emitter.emitterCells = [cell]
        // Pre-warmed: the smoke is already there when the screen appears.
        emitter.beginTime = CACurrentMediaTime() - 12
        layer.addSublayer(emitter)
        fogEmitter = emitter
        layoutFog()
    }

    private func layoutFog() {
        guard let emitter = fogEmitter else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = bounds
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.maxY + 40)
        emitter.emitterSize = CGSize(width: bounds.width * 1.3, height: 1)
        // As many puffs per point of width on a phone as on a TV.
        emitter.birthRate = Float(min(max(bounds.width / 1000, 0.4), 1.8))
        CATransaction.commit()
    }

    // MARK: Bats

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

    // MARK: Witch

    /// A witch on her broom flying right, ~190 × 90 around the seat. Drawn as
    /// separate parts, then unioned: overlapping parts of opposite winding
    /// punched holes in the cloak.
    private static func witchPath() -> CGPath {
        var parts: [CGPath] = []
        func part(_ build: (CGMutablePath) -> Void) {
            let p = CGMutablePath()
            build(p)
            parts.append(p)
        }
        part { p in   // broom stick
            p.move(to: CGPoint(x: -58, y: 9)); p.addLine(to: CGPoint(x: 52, y: -3))
            p.addLine(to: CGPoint(x: 52, y: 0)); p.addLine(to: CGPoint(x: -58, y: 12)); p.closeSubpath()
        }
        part { p in   // bristles
            p.move(to: CGPoint(x: -52, y: 8))
            p.addCurve(to: CGPoint(x: -92, y: 0), control1: CGPoint(x: -66, y: 2), control2: CGPoint(x: -80, y: -4))
            p.addCurve(to: CGPoint(x: -88, y: 12), control1: CGPoint(x: -94, y: 5), control2: CGPoint(x: -92, y: 9))
            p.addCurve(to: CGPoint(x: -94, y: 22), control1: CGPoint(x: -92, y: 16), control2: CGPoint(x: -96, y: 19))
            p.addCurve(to: CGPoint(x: -52, y: 14), control1: CGPoint(x: -80, y: 22), control2: CGPoint(x: -64, y: 18))
            p.closeSubpath()
        }
        part { p in   // cloak, flowing back in two tails
            p.move(to: CGPoint(x: 8, y: 6))
            p.addCurve(to: CGPoint(x: 6, y: -24), control1: CGPoint(x: 14, y: -4), control2: CGPoint(x: 12, y: -18))
            p.addCurve(to: CGPoint(x: -40, y: -14), control1: CGPoint(x: -8, y: -24), control2: CGPoint(x: -26, y: -22))
            p.addCurve(to: CGPoint(x: -24, y: -6), control1: CGPoint(x: -34, y: -10), control2: CGPoint(x: -30, y: -8))
            p.addCurve(to: CGPoint(x: -46, y: 2), control1: CGPoint(x: -32, y: -2), control2: CGPoint(x: -40, y: 0))
            p.addCurve(to: CGPoint(x: -8, y: 8), control1: CGPoint(x: -30, y: 8), control2: CGPoint(x: -18, y: 10))
            p.closeSubpath()
        }
        part { p in   // leg and boot
            p.move(to: CGPoint(x: 4, y: 6)); p.addLine(to: CGPoint(x: 14, y: 20)); p.addLine(to: CGPoint(x: 22, y: 20))
            p.addLine(to: CGPoint(x: 20, y: 24)); p.addLine(to: CGPoint(x: 9, y: 24)); p.addLine(to: CGPoint(x: -2, y: 8))
            p.closeSubpath()
        }
        part { p in   // arm to the front of the broom
            p.move(to: CGPoint(x: 4, y: -18)); p.addLine(to: CGPoint(x: 26, y: -2))
            p.addLine(to: CGPoint(x: 24, y: 2)); p.addLine(to: CGPoint(x: 0, y: -12)); p.closeSubpath()
        }
        part { $0.addEllipse(in: CGRect(x: 2, y: -35, width: 12, height: 12)) }    // head
        part { $0.addEllipse(in: CGRect(x: -6, y: -36, width: 26, height: 5)) }    // hat brim
        part { p in   // crooked hat
            p.move(to: CGPoint(x: 0, y: -34))
            p.addCurve(to: CGPoint(x: -4, y: -62), control1: CGPoint(x: 2, y: -46), control2: CGPoint(x: 4, y: -56))
            p.addCurve(to: CGPoint(x: -14, y: -58), control1: CGPoint(x: -8, y: -64), control2: CGPoint(x: -12, y: -62))
            p.addCurve(to: CGPoint(x: 14, y: -34), control1: CGPoint(x: -4, y: -56), control2: CGPoint(x: 8, y: -46))
            p.closeSubpath()
        }
        return parts.dropFirst().reduce(parts[0]) { $0.union($1, using: .winding) }
    }

    private func launchWitch() {
        witchPending = false
        let w = bounds.width, h = bounds.height
        let container = CALayer()
        container.position = CGPoint(x: -300, y: -300)       // off-screen between crossings
        let shape = CAShapeLayer()
        shape.path = Self.witchPath()
        shape.fillColor = Self.witchColor.cgColor
        let scale = min(max(w / 1400, 0.55), 1.1)
        shape.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        container.addSublayer(shape)
        layer.addSublayer(container)
        witchLayer = container

        let path = UIBezierPath()
        path.move(to: CGPoint(x: -140, y: h * 0.32))
        path.addQuadCurve(to: CGPoint(x: w + 140, y: h * 0.16), controlPoint: CGPoint(x: w * 0.5, y: h * 0.06))
        let fly = CAKeyframeAnimation(keyPath: "position")
        fly.path = path.cgPath
        fly.calculationMode = .paced
        fly.beginTime = WitchFlight.firstDelay
        fly.duration = WitchFlight.duration
        // A gentle bob on the broom, for the crossing only.
        let bob = CABasicAnimation(keyPath: "transform.rotation.z")
        bob.fromValue = -0.05
        bob.toValue = 0.05
        bob.duration = 0.9
        bob.autoreverses = true
        bob.beginTime = WitchFlight.firstDelay
        bob.repeatCount = Float(WitchFlight.duration / (bob.duration * 2))
        let cycle = CAAnimationGroup()
        cycle.animations = [fly, bob]
        cycle.duration = WitchFlight.period
        cycle.repeatCount = .infinity
        cycle.isRemovedOnCompletion = false
        container.add(cycle, forKey: Self.witchKey)
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
