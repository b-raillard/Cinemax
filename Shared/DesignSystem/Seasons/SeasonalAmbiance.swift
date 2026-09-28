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
        ).intersection([.mist, .bats, .pumpkins])
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

    /// The fog bank lying along the bottom edge (slow horizontal drift).
    private(set) var mistLayers: [CAGradientLayer] = []
    /// The moving smoke: soft puffs born in the bottom band, rising, swelling,
    /// turning and dissolving.
    private(set) var fogEmitter: CAEmitterLayer?
    /// Bats crossing again and again, from the first seconds — people open
    /// a film within 20–30 s, and the player shows none of this.
    private(set) var batLayers: [CALayer] = []
    /// Orange pumpkins tumbling down from the top edge.
    private(set) var pumpkinEmitter: CAEmitterLayer?
    private var effects: Set<AmbianceEffect> = []
    private var batsPending = false

    /// A fog-bank blob, in fractions of the screen.
    private struct MistBlob {
        let frame: CGRect
        let opacity: CGFloat
        let drift: CGFloat
        let period: CFTimeInterval
    }

    /// One bat's loop: size, height (fraction of the screen), direction, when
    /// its first crossing starts, how long a crossing lasts, and how often it
    /// comes back. Fixed values, so no two bats fly in step.
    private struct BatRoute {
        let scale: CGFloat
        let y: CGFloat
        let leftToRight: Bool
        let start: CFTimeInterval
        let duration: CFTimeInterval
        let period: CFTimeInterval
    }

    private static let mist: [MistBlob] = [
        MistBlob(frame: CGRect(x: -0.10, y: 0.78, width: 0.80, height: 0.32), opacity: 0.16, drift: 0.06, period: 22),
        MistBlob(frame: CGRect(x: 0.35, y: 0.82, width: 0.80, height: 0.28), opacity: 0.12, drift: -0.05, period: 26),
        MistBlob(frame: CGRect(x: 0.05, y: 0.88, width: 1.00, height: 0.26), opacity: 0.20, drift: 0.04, period: 30)
    ]

    private static let batRoutes: [BatRoute] = [
        BatRoute(scale: 1.0, y: 0.18, leftToRight: true, start: 0.3, duration: 6.0, period: 9),
        BatRoute(scale: 0.6, y: 0.26, leftToRight: false, start: 0.9, duration: 7.5, period: 11),
        BatRoute(scale: 0.8, y: 0.12, leftToRight: true, start: 1.6, duration: 6.5, period: 10),
        BatRoute(scale: 0.5, y: 0.34, leftToRight: false, start: 2.2, duration: 8.5, period: 13),
        BatRoute(scale: 0.9, y: 0.44, leftToRight: true, start: 2.8, duration: 7.0, period: 12),
        BatRoute(scale: 0.55, y: 0.22, leftToRight: false, start: 3.3, duration: 8.0, period: 10),
        BatRoute(scale: 0.7, y: 0.52, leftToRight: true, start: 3.7, duration: 7.5, period: 14),
        BatRoute(scale: 0.45, y: 0.08, leftToRight: false, start: 1.2, duration: 9.0, period: 12),
        BatRoute(scale: 0.85, y: 0.38, leftToRight: false, start: 0.5, duration: 6.5, period: 15),
        BatRoute(scale: 0.6, y: 0.60, leftToRight: true, start: 2.5, duration: 8.0, period: 11)
    ]

    private static let mistColor = UIColor(red: 0xD9 / 255, green: 0xCC / 255, blue: 0xEF / 255, alpha: 1)
    private static let batColor = UIColor(red: 0xB3 / 255, green: 0xA8 / 255, blue: 0xB8 / 255, alpha: 0.8)

    /// A soft round puff (white, radial alpha falloff) tinted by the emitter cell.
    private static let puffImage: CGImage? = {
        let size = CGSize(width: 128, height: 128)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            // A near-gaussian falloff: no visible edge, so a puff never « pops ».
            let alphas: [CGFloat] = [0.55, 0.45, 0.28, 0.12, 0.03, 0]
            let colors = alphas.map { UIColor.white.withAlphaComponent($0).cgColor }
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                            locations: [0, 0.2, 0.45, 0.7, 0.88, 1]) else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size.width / 2, options: [])
        }.cgImage
    }()

    /// An orange jack-o'-lantern, 96 pt, drawn once.
    private static let pumpkinImage: CGImage? = {
        let size = CGSize(width: 96, height: 96)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            let side = UIColor(red: 0xE0 / 255, green: 0x62 / 255, blue: 0x0C / 255, alpha: 1)
            let body = UIColor(red: 0xFF / 255, green: 0x7A / 255, blue: 0x1A / 255, alpha: 1)
            let light = UIColor(red: 0xFF / 255, green: 0x9A / 255, blue: 0x45 / 255, alpha: 1)
            // Stem.
            c.setFillColor(UIColor(red: 0x4F / 255, green: 0x6B / 255, blue: 0x24 / 255, alpha: 1).cgColor)
            c.fill(CGRect(x: 44, y: 12, width: 9, height: 16))
            // Lobes, back to front.
            c.setFillColor(side.cgColor)
            c.fillEllipse(in: CGRect(x: 6, y: 24, width: 50, height: 64))
            c.fillEllipse(in: CGRect(x: 40, y: 24, width: 50, height: 64))
            c.setFillColor(body.cgColor)
            c.fillEllipse(in: CGRect(x: 22, y: 22, width: 52, height: 68))
            c.setFillColor(light.withAlphaComponent(0.55).cgColor)
            c.fillEllipse(in: CGRect(x: 30, y: 28, width: 18, height: 40))
            // Face.
            let face = UIColor(red: 0x3A / 255, green: 0x16 / 255, blue: 0x05 / 255, alpha: 1)
            c.setFillColor(face.cgColor)
            for eyeX in [30.0, 54.0] {
                c.move(to: CGPoint(x: eyeX, y: 52)); c.addLine(to: CGPoint(x: eyeX + 12, y: 52))
                c.addLine(to: CGPoint(x: eyeX + 6, y: 42)); c.closePath(); c.fillPath()
            }
            c.move(to: CGPoint(x: 28, y: 62))
            for (i, x) in stride(from: 32.0, through: 68.0, by: 6.0).enumerated() {
                c.addLine(to: CGPoint(x: x, y: i.isMultiple(of: 2) ? 70 : 64))
            }
            c.addLine(to: CGPoint(x: 70, y: 62))
            c.addQuadCurve(to: CGPoint(x: 28, y: 62), control: CGPoint(x: 49, y: 82))
            c.fillPath()
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
        layoutPumpkins()
        startMistDrift()
        if batsPending, bounds.width > 0 { launchBats() }
    }

    private func rebuild() {
        mistLayers.forEach { $0.removeFromSuperlayer() }
        mistLayers = []
        fogEmitter?.removeFromSuperlayer()
        fogEmitter = nil
        batLayers.forEach { $0.removeFromSuperlayer() }
        batLayers = []
        pumpkinEmitter?.removeFromSuperlayer()
        pumpkinEmitter = nil
        batsPending = false
        guard window != nil else { return }
        if effects.contains(.mist) {
            addMist()
            addFog()
        }
        if effects.contains(.pumpkins) { addPumpkins() }
        if effects.contains(.bats) {
            batsPending = true
            if bounds.width > 0 { launchBats() }
        }
    }

    /// As many particles per point of width on a phone as on a TV.
    private var widthFactor: Float { Float(min(max(bounds.width / 1000, 0.4), 1.8)) }

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
        emitter.emitterShape = .rectangle
        let cell = CAEmitterCell()
        cell.contents = Self.puffImage
        // Many faint, small-born puffs that swell slowly, rather than a few
        // thick ones appearing whole: a continuous, fluid smoke.
        cell.birthRate = 3.2
        cell.lifetime = 18
        cell.lifetimeRange = 4
        cell.velocity = 14
        cell.velocityRange = 6
        // An emitter's longitude 0 points UP the screen, π DOWN, ±π/2
        // sideways — at ±π/2 the smoke slid out along the bottom edge.
        cell.emissionLongitude = 0
        cell.emissionRange = .pi / 6
        cell.xAcceleration = 2.5                     // a breeze pushes it sideways
        cell.scale = 0.7
        cell.scaleRange = 0.3
        cell.scaleSpeed = 0.2                        // born small, swelling as it rises
        cell.spin = 0.03
        cell.spinRange = 0.08                        // turning slowly
        cell.color = Self.mistColor.withAlphaComponent(0.16).cgColor
        cell.alphaSpeed = -0.008                     // then thinning out
        emitter.emitterCells = [cell]
        // Pre-warmed: the smoke is already there when the screen appears.
        emitter.beginTime = CACurrentMediaTime() - 10
        layer.addSublayer(emitter)
        fogEmitter = emitter
        layoutFog()
    }

    private func layoutFog() {
        guard let emitter = fogEmitter else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = bounds
        // Born along the bottom edge (half of the band below it), so the smoke
        // drifts in rather than appearing mid-screen.
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.height)
        emitter.emitterSize = CGSize(width: bounds.width * 1.2, height: bounds.height * 0.12)
        emitter.birthRate = widthFactor
        CATransaction.commit()
    }

    // MARK: Pumpkins

    private func addPumpkins() {
        let emitter = CAEmitterLayer()
        emitter.emitterShape = .line
        let cell = CAEmitterCell()
        cell.contents = Self.pumpkinImage
        cell.birthRate = 1.4
        cell.lifetime = 14
        cell.velocity = 85
        cell.velocityRange = 35
        // π points DOWN (see the smoke). At ±π/2 the pumpkins left sideways
        // and only ever showed along the top edge.
        cell.emissionLongitude = .pi
        cell.emissionRange = .pi / 14
        cell.yAcceleration = 12
        cell.spin = 0.5
        cell.spinRange = 1.4                         // tumbling, both ways
        cell.scale = 0.42
        cell.scaleRange = 0.18
        emitter.emitterCells = [cell]
        // Pre-warmed: pumpkins are already falling when the app opens.
        emitter.beginTime = CACurrentMediaTime() - 6
        layer.addSublayer(emitter)
        pumpkinEmitter = emitter
        layoutPumpkins()
    }

    private func layoutPumpkins() {
        guard let emitter = pumpkinEmitter else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = bounds
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: -40)
        emitter.emitterSize = CGSize(width: bounds.width * 1.05, height: 1)
        // Not below ~one pumpkin a second, even on a phone.
        emitter.birthRate = max(widthFactor, 0.8)
        CATransaction.commit()
    }

    // MARK: Bats

    /// The canvas's bat silhouette, 80 × 20 around its origin (symmetric, so it
    /// reads the same flying either way).
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

    /// Every bat on its own endless loop, the whole thing run by the render
    /// server: no timer, no main-thread work after this.
    private func launchBats() {
        batsPending = false
        let w = bounds.width, h = bounds.height
        for route in Self.batRoutes {
            let container = CALayer()
            container.position = CGPoint(x: -100, y: -100)   // off-screen between crossings
            let shape = CAShapeLayer()
            shape.path = Self.batPath()
            shape.fillColor = Self.batColor.cgColor
            shape.setAffineTransform(CGAffineTransform(scaleX: route.scale, y: route.scale))
            container.addSublayer(shape)
            layer.addSublayer(container)
            batLayers.append(container)

            let from = CGPoint(x: route.leftToRight ? -60 : w + 60, y: h * (route.y + 0.06))
            let to = CGPoint(x: route.leftToRight ? w + 60 : -60, y: h * route.y)
            let path = UIBezierPath()
            path.move(to: from)
            path.addQuadCurve(to: to, controlPoint: CGPoint(x: w * 0.5, y: h * (route.y - 0.08)))
            let fly = CAKeyframeAnimation(keyPath: "position")
            fly.path = path.cgPath
            fly.calculationMode = .paced
            fly.beginTime = route.start
            fly.duration = route.duration
            let flap = CABasicAnimation(keyPath: "transform.scale.y")
            flap.fromValue = 1
            flap.toValue = 0.55
            flap.duration = 0.16
            flap.autoreverses = true
            flap.beginTime = route.start
            flap.repeatCount = Float(route.duration / (flap.duration * 2))
            let cycle = CAAnimationGroup()
            cycle.animations = [fly, flap]
            cycle.duration = route.start + route.period
            cycle.repeatCount = .infinity
            cycle.isRemovedOnCompletion = false
            container.add(cycle, forKey: Self.batKey)
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
