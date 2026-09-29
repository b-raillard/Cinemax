import SwiftUI
import UIKit

// MARK: - Seasonal ambiance
//
// Core Animation only (render server), like `HeroDrift`: a SwiftUI
// `.repeatForever` ticks on the main thread every frame, which cost the Apple
// TV 4K ~10–12 % CPU on an idle Home (lot 8). Not interactive, hidden from
// VoiceOver, ABSENT (not frozen) when `AmbiancePolicy` says no.
//
// Two planes: FAR (small, dim, slow — in `SeasonalBackdrop`, BEHIND the
// content of the browsing screens, with the night sky) and NEAR (two big bats,
// a rare lit pumpkin — `SeasonalAmbianceOverlay`, over the whole app, except
// the calm zones). Both open with 30 s at full density — people start a film
// within 20–30 s and the player shows none of it — then settle to about a third
// (`AmbiancePolicy.density`), half again on Apple TV.

extension EnvironmentValues {
    /// The « Animations d'ambiance » switch, written ONCE at the root from
    /// `SeasonalThemeController` — every card reads it for the tvOS focus
    /// glow, and one `@AppStorage` observer per card was the cost to avoid.
    @Entry var seasonalAmbianceEnabled: Bool = true
}

/// Which depth an `AmbianceView` paints.
enum AmbiancePlane: Sendable {
    case far, near
}

/// Seconds since the ambiance first showed in this app session: the opening
/// burst is the SESSION's, not each screen's.
@MainActor
enum AmbianceClock {
    private static var start: CFTimeInterval?

    static func elapsed() -> TimeInterval {
        let now = CACurrentMediaTime()
        if start == nil { start = now }
        return now - (start ?? now)
    }
}

#if os(tvOS)
private let ambianceIsTV = true
#else
private let ambianceIsTV = false
#endif

/// The NEAR plane, over the whole signed-in app (`AppNavigation`): above the
/// tabs and every pushed screen, under sheets and the player. Hidden in the
/// calm zones (Search, Settings — `SeasonalThemeController.calmZone`).
struct SeasonalAmbianceOverlay: View {
    @Environment(\.seasonID) private var seasonID
    @Environment(\.motionEffectsEnabled) private var motionEnabled
    @Environment(\.seasonalAmbianceEnabled) private var ambianceEnabled

    var body: some View {
        let effects = AmbiancePolicy.effects(
            theme: SeasonalThemeCatalogue.theme(id: seasonID),
            ambianceEnabled: ambianceEnabled, motionEnabled: motionEnabled
        ).intersection([.bats, .pumpkins])
        if !effects.isEmpty {
            AmbianceRepresentable(effects: effects, plane: .near)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// A browsing screen's background: the surface colour, and in season its
/// backdrop (night sky) with the FAR ambiance plane — behind the content, so
/// posters and text stay clean. Out of season: exactly `CinemaColor.surface`.
struct SeasonalBackdrop: View {
    @Environment(\.seasonID) private var seasonID
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.motionEffectsEnabled) private var motionEnabled
    @Environment(\.seasonalAmbianceEnabled) private var ambianceEnabled

    var body: some View {
        let theme = SeasonalThemeCatalogue.theme(id: seasonID)
        let effects = AmbiancePolicy.effects(
            theme: theme, ambianceEnabled: ambianceEnabled, motionEnabled: motionEnabled
        ).intersection([.bats, .pumpkins])
        ZStack {
            CinemaColor.surface
            if theme?.backdrop == .nightSky {
                NightSkyRepresentable(dark: colorScheme == .dark, twinkle: motionEnabled && ambianceEnabled)
            }
            if !effects.isEmpty {
                AmbianceRepresentable(effects: effects, plane: .far)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AmbianceRepresentable: UIViewRepresentable {
    let effects: Set<AmbianceEffect>
    let plane: AmbiancePlane
    func makeUIView(context: Context) -> AmbianceView { AmbianceView(plane: plane) }
    func updateUIView(_ view: AmbianceView, context: Context) { view.setEffects(effects) }
}

final class AmbianceView: UIView {
    static let batKey = "cinemax.ambiance.bat"
    /// Bats on the far plane at full density (the near plane has two).
    static let farBatCount = 8

    /// Bats on their loops.
    private(set) var batLayers: [CALayer] = []
    /// Pumpkins tumbling down from the top edge.
    private(set) var pumpkinEmitter: CAEmitterLayer?
    private let plane: AmbiancePlane
    private let clock: () -> TimeInterval
    private var effects: Set<AmbianceEffect> = []
    private var batsPending = false
    private var calmTask: Task<Void, Never>?

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

    private static let farRoutes: [BatRoute] = [
        BatRoute(scale: 0.50, y: 0.16, leftToRight: true, start: 0.3, duration: 10, period: 13),
        BatRoute(scale: 0.34, y: 0.30, leftToRight: false, start: 1.1, duration: 12, period: 16),
        BatRoute(scale: 0.44, y: 0.46, leftToRight: true, start: 1.8, duration: 11, period: 15),
        BatRoute(scale: 0.30, y: 0.62, leftToRight: false, start: 2.6, duration: 13, period: 17),
        BatRoute(scale: 0.55, y: 0.24, leftToRight: false, start: 0.7, duration: 9.5, period: 14),
        BatRoute(scale: 0.38, y: 0.54, leftToRight: true, start: 3.2, duration: 12, period: 18),
        BatRoute(scale: 0.32, y: 0.10, leftToRight: false, start: 2.2, duration: 13, period: 16),
        BatRoute(scale: 0.46, y: 0.72, leftToRight: true, start: 3.8, duration: 11, period: 15)
    ]

    private static let nearRoutes: [BatRoute] = [
        BatRoute(scale: 1.35, y: 0.20, leftToRight: true, start: 1.5, duration: 5.5, period: 24),
        BatRoute(scale: 1.15, y: 0.42, leftToRight: false, start: 9, duration: 6.0, period: 30)
    ]

    private static let farBatColor = UIColor(red: 0xB3 / 255, green: 0xA8 / 255, blue: 0xB8 / 255, alpha: 0.5)
    private static let nearBatColor = UIColor(red: 0x1C / 255, green: 0x17 / 255, blue: 0x26 / 255, alpha: 0.92)

    private enum PumpkinFace { case plain, carved }

    /// An orange pumpkin, 128 pt with room for its glow; the carved one is lit
    /// from inside.
    private static func pumpkinImage(_ face: PumpkinFace) -> CGImage? {
        let size = CGSize(width: 128, height: 128)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: 16, y: 16)                 // the 96-pt pumpkin, centred
            let side = UIColor(red: 0xE0 / 255, green: 0x62 / 255, blue: 0x0C / 255, alpha: 1)
            let body = UIColor(red: 0xFF / 255, green: 0x7A / 255, blue: 0x1A / 255, alpha: 1)
            let light = UIColor(red: 0xFF / 255, green: 0x9A / 255, blue: 0x45 / 255, alpha: 1)
            if face == .carved {
                // A warm halo around the lit pumpkin.
                c.setShadow(offset: .zero, blur: 14, color: UIColor(red: 1, green: 0.55, blue: 0.1, alpha: 0.9).cgColor)
            }
            c.setFillColor(UIColor(red: 0x4F / 255, green: 0x6B / 255, blue: 0x24 / 255, alpha: 1).cgColor)
            c.fill(CGRect(x: 44, y: 12, width: 9, height: 16))
            c.setFillColor(side.cgColor)
            c.fillEllipse(in: CGRect(x: 6, y: 24, width: 50, height: 64))
            c.fillEllipse(in: CGRect(x: 40, y: 24, width: 50, height: 64))
            c.setFillColor(body.cgColor)
            c.fillEllipse(in: CGRect(x: 22, y: 22, width: 52, height: 68))
            c.setShadow(offset: .zero, blur: 0, color: nil)
            c.setFillColor(light.withAlphaComponent(0.55).cgColor)
            c.fillEllipse(in: CGRect(x: 30, y: 28, width: 18, height: 40))
            guard face == .carved else { return }
            // Carved face, glowing from inside.
            c.setFillColor(UIColor(red: 0xFF / 255, green: 0xD3 / 255, blue: 0x4D / 255, alpha: 1).cgColor)
            c.setShadow(offset: .zero, blur: 6, color: UIColor(red: 1, green: 0.85, blue: 0.3, alpha: 1).cgColor)
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
    }

    private static let plainPumpkin = pumpkinImage(.plain)
    private static let carvedPumpkin = pumpkinImage(.carved)

    init(plane: AmbiancePlane, clock: @escaping () -> TimeInterval = { AmbianceClock.elapsed() }) {
        self.plane = plane
        self.clock = clock
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { calmTask?.cancel() }

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
        layoutPumpkins()
        if batsPending, bounds.width > 0 { launchBats() }
    }

    private func rebuild() {
        calmTask?.cancel()
        calmTask = nil
        batLayers.forEach { $0.removeFromSuperlayer() }
        batLayers = []
        pumpkinEmitter?.removeFromSuperlayer()
        pumpkinEmitter = nil
        batsPending = false
        guard window != nil, !effects.isEmpty else { return }
        let elapsed = clock()
        if effects.contains(.pumpkins) { addPumpkins() }
        if effects.contains(.bats) {
            batsPending = true
            if bounds.width > 0 { launchBats() }
        }
        // Still in the opening: settle the pumpkins when it ends. (The extra
        // bats end on their own — `launchBats`.)
        let remaining = AmbiancePolicy.introDuration - elapsed
        if remaining > 0, pumpkinEmitter != nil {
            calmTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                self?.layoutPumpkins()
            }
        }
    }

    /// As many particles per point of width on a phone as on a TV.
    private var widthFactor: Float { Float(min(max(bounds.width / 1000, 0.8), 1.8)) }

    // MARK: Pumpkins

    private func addPumpkins() {
        let emitter = CAEmitterLayer()
        emitter.emitterShape = .line
        func cell(_ image: CGImage?, rate: Float, scale: CGFloat, velocity: CGFloat, alpha: CGFloat) -> CAEmitterCell {
            let c = CAEmitterCell()
            c.contents = image
            c.birthRate = rate
            c.lifetime = Float(1400 / velocity)     // long enough to cross any screen
            c.velocity = velocity
            c.velocityRange = velocity * 0.35
            // An emitter's longitude 0 points UP the screen, π DOWN, ±π/2
            // sideways — at ±π/2 the pumpkins left through the side edges.
            c.emissionLongitude = .pi
            c.emissionRange = .pi / 14
            c.yAcceleration = 10
            c.spin = 0.4
            c.spinRange = 1.2                        // tumbling, both ways
            c.scale = scale
            c.scaleRange = scale * 0.3
            c.color = UIColor.white.withAlphaComponent(alpha).cgColor
            return c
        }
        switch plane {
        case .far:
            // Small, dim and slow: far away, behind the posters.
            emitter.emitterCells = [
                cell(Self.plainPumpkin, rate: 0.9, scale: 0.2, velocity: 45, alpha: 0.6),
                cell(Self.carvedPumpkin, rate: 0.5, scale: 0.22, velocity: 40, alpha: 0.7)
            ]
        case .near:
            // Now and then a big lit one tumbles past in front of everything.
            emitter.emitterCells = [
                cell(Self.carvedPumpkin, rate: 0.12, scale: 0.7, velocity: 120, alpha: 1)
            ]
        }
        // Pre-warmed: already falling when the screen appears.
        emitter.beginTime = CACurrentMediaTime() - 8
        layer.addSublayer(emitter)
        pumpkinEmitter = emitter
        layoutPumpkins()
    }

    private func layoutPumpkins() {
        guard let emitter = pumpkinEmitter else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = bounds
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: -60)
        emitter.emitterSize = CGSize(width: bounds.width * 1.05, height: 1)
        emitter.birthRate = widthFactor * Float(AmbiancePolicy.density(elapsed: clock(), isTV: ambianceIsTV))
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

    /// Every bat on its own loop, run by the render server. During the
    /// opening the plane flies its full count; the bats beyond the calm count
    /// stop at the end of the crossing that outlasts it (whole cycles, so they
    /// never vanish mid-flight). After the opening, only the calm count flies.
    private func launchBats() {
        batsPending = false
        let w = bounds.width, h = bounds.height
        let elapsed = clock()
        let routes = plane == .far ? Self.farRoutes : Self.nearRoutes
        let dense = AmbiancePolicy.batCount(dense: routes.count, elapsed: 0, isTV: ambianceIsTV)
        let calm = AmbiancePolicy.batCount(dense: routes.count, elapsed: .infinity, isTV: ambianceIsTV)
        let remaining = AmbiancePolicy.introDuration - elapsed
        let flying = remaining > 0 ? dense : calm
        let color = plane == .far ? Self.farBatColor : Self.nearBatColor
        for (index, route) in routes.prefix(flying).enumerated() {
            let container = CALayer()
            container.position = CGPoint(x: -140, y: -140)   // off-screen between crossings
            let shape = CAShapeLayer()
            shape.path = Self.batPath()
            shape.fillColor = color.cgColor
            shape.setAffineTransform(CGAffineTransform(scaleX: route.scale, y: route.scale))
            container.addSublayer(shape)
            layer.addSublayer(container)
            batLayers.append(container)

            let from = CGPoint(x: route.leftToRight ? -80 : w + 80, y: h * (route.y + 0.06))
            let to = CGPoint(x: route.leftToRight ? w + 80 : -80, y: h * route.y)
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
            flap.duration = plane == .far ? 0.2 : 0.14
            flap.autoreverses = true
            flap.beginTime = route.start
            flap.repeatCount = Float(route.duration / (flap.duration * 2))
            let cycle = CAAnimationGroup()
            cycle.animations = [fly, flap]
            cycle.duration = route.start + route.period
            if remaining > 0, index >= calm {
                cycle.repeatDuration = (remaining / cycle.duration).rounded(.up) * cycle.duration
            } else {
                cycle.repeatCount = .infinity
            }
            cycle.isRemovedOnCompletion = false
            container.add(cycle, forKey: Self.batKey)
        }
    }
}

// MARK: - Night sky

private struct NightSkyRepresentable: UIViewRepresentable {
    let dark: Bool
    let twinkle: Bool
    func makeUIView(context: Context) -> NightSkyView { NightSkyView(frame: .zero) }
    func updateUIView(_ view: NightSkyView, context: Context) { view.configure(dark: dark, twinkle: twinkle) }
}

/// The season's background: scattered stars (dark mode only), a few that
/// twinkle (with motion), and cobwebs in the two top corners with a spider on
/// its thread. Drawn from a fixed seed, so it never reshuffles.
final class NightSkyView: UIView {
    static let twinkleKey = "cinemax.nightsky.twinkle"
    static let spiderKey = "cinemax.nightsky.spider"

    let starLayer = CAShapeLayer()
    private(set) var twinkleLayers: [CAShapeLayer] = []
    private(set) var webLayers: [CAShapeLayer] = []
    private let spiderLayer = CAShapeLayer()
    private var dark = true
    private var twinkle = true
    private var drawnSize: CGSize = .zero

    private static let starColor = UIColor(red: 0xF1 / 255, green: 0xE9 / 255, blue: 0xE0 / 255, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(starLayer)
        layer.addSublayer(spiderLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(dark: Bool, twinkle: Bool) {
        guard dark != self.dark || twinkle != self.twinkle || drawnSize == .zero else { return }
        self.dark = dark
        self.twinkle = twinkle
        drawnSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != drawnSize, bounds.width > 0 else { return }
        drawnSize = bounds.size
        draw()
    }

    /// SplitMix64: the same sky on every launch and every screen.
    private struct Seeded {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }

    private func draw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        twinkleLayers.forEach { $0.removeFromSuperlayer() }
        twinkleLayers = []
        webLayers.forEach { $0.removeFromSuperlayer() }
        webLayers = []
        let w = bounds.width, h = bounds.height
        var rng = Seeded(state: 0x5EA50A)

        // Stars: dark mode only (a starry sky on white reads as dirt).
        if dark {
            let stars = CGMutablePath()
            let count = Int(w * h / 7000)
            for _ in 0..<count {
                let r = 0.4 + rng.next() * 1.1
                stars.addEllipse(in: CGRect(x: rng.next() * w, y: rng.next() * h, width: r * 2, height: r * 2))
            }
            starLayer.path = stars
            starLayer.fillColor = Self.starColor.withAlphaComponent(0.45).cgColor
            for index in 0..<max(6, count / 12) {
                let star = CAShapeLayer()
                let r = 1.2 + rng.next() * 1.2
                star.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
                star.position = CGPoint(x: rng.next() * w, y: rng.next() * h)
                star.fillColor = Self.starColor.cgColor
                star.opacity = 0.8
                if twinkle {
                    let a = CABasicAnimation(keyPath: "opacity")
                    a.fromValue = 0.9
                    a.toValue = 0.15
                    a.duration = 1.4 + rng.next() * 2.2
                    a.beginTime = CACurrentMediaTime() + Double(index) * 0.37
                    a.autoreverses = true
                    a.repeatCount = .infinity
                    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    star.add(a, forKey: Self.twinkleKey)
                }
                layer.insertSublayer(star, above: starLayer)
                twinkleLayers.append(star)
            }
        } else {
            starLayer.path = nil
        }

        // Cobwebs in the two top corners.
        let webColor = dark
            ? UIColor(red: 0xB3 / 255, green: 0xA8 / 255, blue: 0xB8 / 255, alpha: 0.22)
            : UIColor(red: 0x55 / 255, green: 0x58 / 255, blue: 0x5E / 255, alpha: 0.18)
        let radius = min(w, h) * 0.34
        for corner in [CGPoint.zero, CGPoint(x: w, y: 0)] {
            let web = CAShapeLayer()
            web.path = Self.webPath(corner: corner, radius: radius, mirrored: corner.x > 0)
            web.strokeColor = webColor.cgColor
            web.fillColor = nil
            web.lineWidth = 0.8
            layer.insertSublayer(web, below: spiderLayer)
            webLayers.append(web)
        }

        // A spider on its thread, from the right-hand web.
        let thread = radius * 0.55
        let spider = CGMutablePath()
        spider.move(to: CGPoint(x: 0, y: -thread)); spider.addLine(to: CGPoint(x: 0, y: -4))
        spider.addEllipse(in: CGRect(x: -4, y: -4, width: 8, height: 9))
        for side in [-1.0, 1.0] {
            for leg in 0..<4 {
                let y = -1.0 + Double(leg) * 2.0
                spider.move(to: CGPoint(x: side * 3, y: y))
                spider.addLine(to: CGPoint(x: side * 8, y: y - 3 + Double(leg)))
                spider.addLine(to: CGPoint(x: side * 10, y: y + 2 + Double(leg)))
            }
        }
        spiderLayer.path = spider
        spiderLayer.strokeColor = webColor.withAlphaComponent(dark ? 0.6 : 0.5).cgColor
        spiderLayer.fillColor = webColor.withAlphaComponent(dark ? 0.6 : 0.5).cgColor
        spiderLayer.lineWidth = 1
        spiderLayer.position = CGPoint(x: w - radius * 0.42, y: thread)
        spiderLayer.removeAnimation(forKey: Self.spiderKey)
        if twinkle {
            let bob = CABasicAnimation(keyPath: "position.y")
            bob.fromValue = thread
            bob.toValue = thread + radius * 0.18
            bob.duration = 3.5
            bob.autoreverses = true
            bob.repeatCount = .infinity
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            spiderLayer.add(bob, forKey: Self.spiderKey)
        }
    }

    /// Radial threads from the corner, joined by sagging spiral rings.
    private static func webPath(corner: CGPoint, radius: CGFloat, mirrored: Bool) -> CGPath {
        let p = CGMutablePath()
        let threads = 7
        let angles = (0..<threads).map { Double($0) / Double(threads - 1) * (.pi / 2) }
        func point(_ angle: Double, _ r: CGFloat) -> CGPoint {
            let dx = CGFloat(cos(angle)) * r, dy = CGFloat(sin(angle)) * r
            return CGPoint(x: corner.x + (mirrored ? -dx : dx), y: corner.y + dy)
        }
        for a in angles {
            p.move(to: corner)
            p.addLine(to: point(a, radius))
        }
        for ring in 1...6 {
            let r = radius * CGFloat(ring) / 6.4
            p.move(to: point(angles[0], r))
            for i in 1..<angles.count {
                let mid = (angles[i - 1] + angles[i]) / 2
                p.addQuadCurve(to: point(angles[i], r), control: point(mid, r * 0.86))
            }
        }
        return p
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
