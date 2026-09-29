import SwiftUI

/// The « Nuit d'Halloween » announcement: a full night scene rather than one
/// motif on a halo — the page sells a LOOK, so it shows it. Drawn (one
/// `Canvas`, never an image, per the illustration RULE) on a 680 × 380 grid in
/// the season's own colours, not the user's accent.
///
/// It is the one « Quoi de neuf » art that moves — stars twinkle, bats flap
/// and one crosses the sky, windows and lanterns flicker, the spider bobs —
/// and all of it stops with Motion Effects off or Reduce Motion
/// (`motionEffectsEnabled`), leaving every light on.
struct WhatsNewHalloweenScene: View {
    @Environment(\.motionEffectsEnabled) private var motionEffects

    static let aspectRatio: CGFloat = 680 / 380

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !motionEffects)) { context in
            let time: Double? = motionEffects ? context.date.timeIntervalSinceReferenceDate : nil
            Canvas { ctx, size in
                let scale = min(size.width / 680, size.height / 380)
                ctx.scaleBy(x: scale, y: scale)
                Self.draw(in: &ctx, time: time)
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: CinemaScale.pt(20), style: .continuous))
        .accessibilityHidden(true)
    }

    // MARK: - Palette (the season's)

    private static let night = rgb(0x0C0A10)
    private static let dusk = rgb(0x171220)
    private static let hill = rgb(0x130F1A)
    private static let ink = rgb(0x0E0B13)
    private static let ground = rgb(0x09070D)
    private static let star = rgb(0xEDE6D6)
    private static let moon = rgb(0xEDE4C8)
    private static let crater = rgb(0xDCD1B2)
    private static let bat = rgb(0x1C1726)
    private static let web = rgb(0x8A7F98)
    private static let spider = rgb(0x2A2233)
    private static let window = rgb(0xFFB347)
    private static let pumpkin = rgb(0xFF7A1A)
    private static let pumpkinSide = rgb(0xD9600E)
    private static let stem = rgb(0x4B6B1F)
    private static let flame = rgb(0xFFD27A)

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    // MARK: - Motion

    /// 0…1, once per `period` seconds.
    private static func wave(_ time: Double, period: Double, phase: Double = 0) -> Double {
        0.5 + 0.5 * sin((time / period + phase) * 2 * .pi)
    }

    /// A light that flickers on two steps; fully lit when still.
    private static func flicker(_ time: Double?, period: Double = 1.8, phase: Double = 0) -> Double {
        guard let time else { return 1 }
        return Int(((time + phase) / (period / 2)).rounded(.down)).isMultiple(of: 2) ? 1 : 0.55
    }

    // MARK: - Drawing

    private static func draw(in ctx: inout GraphicsContext, time: Double?) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: 680, height: 380)), with: .color(night))
        ctx.fill(Path(CGRect(x: 0, y: 200, width: 680, height: 180)), with: .color(dusk))
        drawStars(in: &ctx, time: time)
        drawMoon(in: &ctx, time: time)
        drawHouse(in: &ctx, time: time)
        drawTree(in: &ctx)
        var foreground = Path()
        foreground.move(to: CGPoint(x: 0, y: 344))
        foreground.addQuadCurve(to: CGPoint(x: 380, y: 346), control: CGPoint(x: 180, y: 318))
        foreground.addQuadCurve(to: CGPoint(x: 680, y: 336), control: CGPoint(x: 580, y: 374))
        foreground.addLine(to: CGPoint(x: 680, y: 380))
        foreground.addLine(to: CGPoint(x: 0, y: 380))
        foreground.closeSubpath()
        ctx.fill(foreground, with: .color(ground))
        drawCobweb(in: &ctx, time: time)
        drawPumpkin(in: &ctx, at: CGPoint(x: 320, y: 334), scale: 1.35, time: time, phase: 0)
        drawPumpkin(in: &ctx, at: CGPoint(x: 398, y: 350), scale: 0.9, time: time, phase: 0.6)
        drawPumpkin(in: &ctx, at: CGPoint(x: 262, y: 352), scale: 0.75, time: time, phase: 1.1)
    }

    /// A point of light; a `twinkle` phase makes it breathe, `nil` holds it steady.
    private struct Light {
        let rect: CGRect
        var alpha = 1.0
        var twinkle: Double?
    }

    private static func star(_ x: Double, _ y: Double, _ r: Double, _ twinkle: Double? = nil) -> Light {
        Light(rect: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), twinkle: twinkle)
    }

    private static let stars: [Light] = [
        star(40, 150, 1.4, 0), star(90, 110, 1, 0.5), star(150, 60, 1.6, 0.2), star(215, 130, 1),
        star(260, 40, 1.3, 0.7), star(300, 95, 1), star(345, 30, 1.8, 0.1), star(385, 140, 1.1, 0.4),
        star(420, 70, 1), star(610, 40, 1.5, 0.3), star(645, 110, 1, 0.8), star(595, 170, 1.2),
        star(235, 180, 1, 0.6), star(660, 200, 1.3), star(120, 200, 1, 0.9), star(455, 190, 1)
    ]

    private static func drawStars(in ctx: inout GraphicsContext, time: Double?) {
        for light in stars {
            var opacity = 1.0
            if let time, let phase = light.twinkle { opacity = 0.25 + 0.75 * wave(time, period: 5.2, phase: phase) }
            ctx.fill(Path(ellipseIn: light.rect), with: .color(star.opacity(opacity)))
        }
    }

    private static func drawMoon(in ctx: inout GraphicsContext, time: Double?) {
        for (r, alpha) in [(112.0, 0.04), (86, 0.06), (70, 0.08)] {
            ctx.fill(circle(500, 115, r), with: .color(moon.opacity(alpha)))
        }
        ctx.fill(circle(500, 115, 56), with: .color(moon))
        for (x, y, r) in [(482.0, 100.0, 9.0), (520, 132, 12), (512, 92, 5), (478, 138, 4)] {
            ctx.fill(circle(x, y, r), with: .color(crater))
        }
        for bat in moonBats { drawBat(bat, in: &ctx, time: time) }
        // One bat crosses the whole sky; still, it waits on the left.
        let crossing = time.map { ($0 / 14).truncatingRemainder(dividingBy: 1) } ?? 0.2
        drawBat(
            Bat(at: CGPoint(x: -80 + 840 * crossing, y: 170 - 60 * crossing), scale: 0.7, color: spider, phase: 0.2),
            in: &ctx, time: time
        )
    }

    private struct Bat {
        let at: CGPoint
        let scale: Double
        let color: Color
        let phase: Double
    }

    private static let moonBats = [
        Bat(at: CGPoint(x: 470, y: 100), scale: 1.3, color: bat, phase: 0),
        Bat(at: CGPoint(x: 535, y: 82), scale: 1, color: bat, phase: 0.4),
        Bat(at: CGPoint(x: 520, y: 140), scale: 0.8, color: bat, phase: 0.7)
    ]

    private static let batPath: Path = {
        var p = Path()
        p.move(to: .zero)
        p.addCurve(to: CGPoint(x: -20, y: -4), control1: CGPoint(x: -4, y: -6), control2: CGPoint(x: -10, y: -8))
        p.addCurve(to: CGPoint(x: -16, y: 5), control1: CGPoint(x: -15, y: -2), control2: CGPoint(x: -14, y: 2))
        p.addCurve(to: CGPoint(x: -5, y: 6), control1: CGPoint(x: -11, y: 2), control2: CGPoint(x: -7, y: 3))
        p.addCurve(to: CGPoint(x: 0, y: 4), control1: CGPoint(x: -3, y: 3), control2: CGPoint(x: -1, y: 2))
        p.addCurve(to: CGPoint(x: 5, y: 6), control1: CGPoint(x: 1, y: 2), control2: CGPoint(x: 3, y: 3))
        p.addCurve(to: CGPoint(x: 16, y: 5), control1: CGPoint(x: 7, y: 3), control2: CGPoint(x: 11, y: 2))
        p.addCurve(to: CGPoint(x: 20, y: -4), control1: CGPoint(x: 14, y: 2), control2: CGPoint(x: 15, y: -2))
        p.addCurve(to: .zero, control1: CGPoint(x: 10, y: -8), control2: CGPoint(x: 4, y: -6))
        p.closeSubpath()
        return p
    }()

    private static func drawBat(_ bat: Bat, in ctx: inout GraphicsContext, time: Double?) {
        let flap = time.map { 1 - 0.65 * wave($0, period: 1, phase: bat.phase) } ?? 1
        var layer = ctx
        layer.translateBy(x: bat.at.x, y: bat.at.y)
        layer.scaleBy(x: bat.scale, y: bat.scale * flap)
        layer.fill(batPath, with: .color(bat.color))
    }

    private static func drawHouse(in ctx: inout GraphicsContext, time: Double?) {
        var slope = Path()
        slope.move(to: CGPoint(x: 0, y: 300))
        slope.addQuadCurve(to: CGPoint(x: 340, y: 288), control: CGPoint(x: 140, y: 196))
        slope.addLine(to: CGPoint(x: 340, y: 380))
        slope.addLine(to: CGPoint(x: 0, y: 380))
        slope.closeSubpath()
        ctx.fill(slope, with: .color(hill))

        var house = Path()
        house.addRect(CGRect(x: 140, y: 214, width: 78, height: 60))
        house.addRect(CGRect(x: 206, y: 178, width: 24, height: 96))
        house.addRect(CGRect(x: 118, y: 238, width: 26, height: 36))
        house.addRect(CGRect(x: 186, y: 186, width: 4, height: 12))
        house.addLines([CGPoint(x: 134, y: 216), CGPoint(x: 179, y: 178), CGPoint(x: 224, y: 216)])
        house.addLines([CGPoint(x: 202, y: 180), CGPoint(x: 218, y: 132), CGPoint(x: 234, y: 180)])
        house.addLines([CGPoint(x: 114, y: 240), CGPoint(x: 131, y: 218), CGPoint(x: 148, y: 240)])
        ctx.fill(house, with: .color(ink))

        let lit = [
            Light(rect: CGRect(x: 152, y: 228, width: 9, height: 12), twinkle: 0),
            Light(rect: CGRect(x: 172, y: 228, width: 9, height: 12)),
            Light(rect: CGRect(x: 213, y: 192, width: 9, height: 12), twinkle: 0.7),
            Light(rect: CGRect(x: 213, y: 222, width: 9, height: 11)),
            Light(rect: CGRect(x: 126, y: 250, width: 8, height: 10), alpha: 0.7)
        ]
        for light in lit {
            let opacity = light.alpha * (light.twinkle.map { flicker(time, phase: $0) } ?? 1)
            ctx.fill(Path(roundedRect: light.rect, cornerRadius: 1), with: .color(window.opacity(opacity)))
        }
        ctx.fill(
            Path(roundedRect: CGRect(x: 170, y: 254, width: 12, height: 20), cornerRadius: 6),
            with: .color(pumpkin.opacity(0.8))
        )
    }

    private static func drawTree(in ctx: inout GraphicsContext) {
        let branches: [([CGPoint], Double)] = [
            ([CGPoint(x: 612, y: 380), CGPoint(x: 604, y: 330), CGPoint(x: 622, y: 300), CGPoint(x: 600, y: 258),
              CGPoint(x: 590, y: 238), CGPoint(x: 568, y: 232), CGPoint(x: 548, y: 214)], 10),
            ([CGPoint(x: 604, y: 300), CGPoint(x: 630, y: 280), CGPoint(x: 646, y: 262), CGPoint(x: 672, y: 262)], 6),
            ([CGPoint(x: 596, y: 262), CGPoint(x: 600, y: 236), CGPoint(x: 616, y: 220), CGPoint(x: 612, y: 196)], 5),
            ([CGPoint(x: 566, y: 226), CGPoint(x: 556, y: 212), CGPoint(x: 552, y: 200), CGPoint(x: 540, y: 196)], 4),
            ([CGPoint(x: 640, y: 270), CGPoint(x: 650, y: 254), CGPoint(x: 648, y: 244), CGPoint(x: 660, y: 236)], 3),
            ([CGPoint(x: 612, y: 196), CGPoint(x: 620, y: 186), CGPoint(x: 630, y: 184), CGPoint(x: 636, y: 176)], 3)
        ]
        for (points, width) in branches {
            var path = Path()
            path.move(to: points[0])
            // A start point, then (control1, control2, end) triples.
            var index = 1
            while index + 2 < points.count {
                path.addCurve(to: points[index + 2], control1: points[index], control2: points[index + 1])
                index += 3
            }
            ctx.stroke(path, with: .color(ground), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    private static func drawCobweb(in ctx: inout GraphicsContext, time: Double?) {
        var web = Path()
        for end in [CGPoint(x: 120, y: 0), CGPoint(x: 112, y: 44), CGPoint(x: 86, y: 86),
                    CGPoint(x: 44, y: 112), CGPoint(x: 0, y: 120)] {
            web.move(to: .zero)
            web.addLine(to: end)
        }
        for ring in [30.0, 62, 96] {
            // Sagging threads between the spokes.
            let spokes = [0.0, 0.37, 0.785, 1.2, .pi / 2]
            web.move(to: CGPoint(x: ring, y: 0))
            for (from, to) in zip(spokes, spokes.dropFirst()) {
                let mid = (from + to) / 2
                let end = CGPoint(x: ring * cos(to), y: ring * sin(to))
                let sag = CGPoint(x: ring * 0.86 * cos(mid), y: ring * 0.86 * sin(mid))
                web.addQuadCurve(to: end, control: sag)
            }
        }
        ctx.stroke(web, with: .color(Self.web.opacity(0.45)), lineWidth: 0.8)

        let drop = 62 + (time.map { 14 * wave($0, period: 6) } ?? 0)
        var thread = Path()
        thread.move(to: CGPoint(x: 138, y: 0))
        thread.addLine(to: CGPoint(x: 138, y: drop))
        ctx.stroke(thread, with: .color(Self.web.opacity(0.6)), lineWidth: 0.7)
        var legs = Path()
        for side in [-1.0, 1.0] {
            for (dy, reach) in [(-2.0, -6.0), (0, 0), (2, 6)] {
                legs.move(to: CGPoint(x: 138 + 3 * side, y: drop + 6 + dy))
                legs.addLine(to: CGPoint(x: 138 + (reach == 0 ? 10 : 9) * side, y: drop + 6 + reach))
            }
        }
        ctx.stroke(legs, with: .color(spider), lineWidth: 1.4)
        ctx.fill(Path(ellipseIn: CGRect(x: 133.5, y: drop + 0.5, width: 9, height: 11)), with: .color(spider))
    }

    private static func drawPumpkin(
        in ctx: inout GraphicsContext, at center: CGPoint, scale: Double, time: Double?, phase: Double
    ) {
        var layer = ctx
        layer.translateBy(x: center.x, y: center.y)
        layer.scaleBy(x: scale, y: scale)
        layer.fill(circle(0, 0, 62), with: .color(pumpkin.opacity(0.06)))
        layer.fill(circle(0, 0, 44), with: .color(pumpkin.opacity(0.08)))
        layer.fill(Path(ellipseIn: CGRect(x: -28, y: -20, width: 30, height: 40)), with: .color(pumpkinSide))
        layer.fill(Path(ellipseIn: CGRect(x: -2, y: -20, width: 30, height: 40)), with: .color(pumpkinSide))
        layer.fill(Path(ellipseIn: CGRect(x: -14, y: -21, width: 28, height: 42)), with: .color(pumpkin))
        layer.fill(Path(roundedRect: CGRect(x: -2, y: -27, width: 4, height: 9), cornerRadius: 2), with: .color(stem))
        var face = Path()
        face.addLines([CGPoint(x: -12, y: -5), CGPoint(x: -6, y: -11), CGPoint(x: -2, y: -4)])
        face.closeSubpath()
        face.addLines([CGPoint(x: 12, y: -5), CGPoint(x: 6, y: -11), CGPoint(x: 2, y: -4)])
        face.closeSubpath()
        face.addLines([
            CGPoint(x: -13, y: 5), CGPoint(x: -8, y: 10), CGPoint(x: -4, y: 6), CGPoint(x: 0, y: 11),
            CGPoint(x: 4, y: 6), CGPoint(x: 8, y: 10), CGPoint(x: 13, y: 5), CGPoint(x: 9, y: 14), CGPoint(x: -9, y: 14)
        ])
        face.closeSubpath()
        layer.fill(face, with: .color(flame.opacity(flicker(time, phase: phase))))
    }

    private static func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
}
