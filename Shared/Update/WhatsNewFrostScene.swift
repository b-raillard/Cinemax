import SwiftUI

/// The « Noël sous le givre » announcement (2.8.0): one big snow crystal
/// glowing on a night sky, smaller crystals falling past it, the season's
/// frost thick in the four corners. A PORT of scene B of the approved mockup
/// (artifact « Nouveautés 2.8.0 », 2026-11-24): change the mockup first, then
/// the numbers here.
///
/// Drawn in one `Canvas` on a 680 × 380 grid, in the season's own colours
/// (`SeasonalThemeCatalogue.christmas`), never the user's accent — like
/// `WhatsNewHalloweenScene`. The frost is the season's own rendered texture
/// (`SeasonFrost`, the one the app wears in season), tiled and masked to the
/// corners: the owner refused drawn frost twice, and this is the frost the
/// page is offering. With Motion Effects off or Reduce Motion everything
/// stands still (`FrostSceneMotion` at `nil`).
struct WhatsNewFrostScene: View {
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

    private static let night = rgb(0x0B1A2E)
    private static let skyTop = rgb(0x071222)
    private static let skyBottom = rgb(0x16304F)
    private static let frost = rgb(0xCFE2F5)
    private static let snow = rgb(0xEDF2F8)

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    private static let bounds = CGRect(x: 0, y: 0, width: 680, height: 380)

    // MARK: - Drawing

    private static func draw(in ctx: inout GraphicsContext, time: Double?) {
        ctx.fill(Path(bounds), with: .linearGradient(
            Gradient(stops: [.init(color: skyTop, location: 0), .init(color: night, location: 0.62),
                             .init(color: skyBottom, location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: 380)))
        for star in FrostSceneMotion.stars {
            let opacity = 0.6 * FrostSceneMotion.twinkle(time, phase: star.phase)
            ctx.fill(circle(star.x, star.y, star.r), with: .color(snow.opacity(opacity)))
        }
        // The glow the big crystal stands in.
        ctx.fill(circle(340, 190, 150), with: .radialGradient(
            Gradient(stops: [.init(color: frost.opacity(0.32), location: 0), .init(color: frost.opacity(0.08), location: 0.55),
                             .init(color: frost.opacity(0), location: 1)]),
            center: CGPoint(x: 340, y: 190), startRadius: 0, endRadius: 150))
        drawCentralCrystal(in: &ctx, time: time)
        for flake in FrostSceneMotion.flakes { drawFlake(flake, in: &ctx, time: time) }
        drawFrost(in: &ctx)
    }

    /// The big crystal, swaying gently: a blurred copy for its glow, then the
    /// crisp one — branches, barbs, the short spikes between the branches and
    /// the hexagon at its heart.
    private static func drawCentralCrystal(in ctx: inout GraphicsContext, time: Double?) {
        var layer = ctx
        layer.translateBy(x: 340 + FrostSceneMotion.sway(time, period: 6, phase: 0), y: 190)
        layer.rotate(by: .degrees(8))
        var glow = layer
        glow.addFilter(.blur(radius: 6))
        glow.opacity = 0.55
        strokeStar(radius: 80, width: 7, in: &glow)
        strokeStar(radius: 80, width: 2.6, in: &layer)
    }

    private static func strokeStar(radius r: Double, width w: Double, in ctx: inout GraphicsContext) {
        let style = { (lineWidth: Double) in StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round) }
        ctx.stroke(crystal(radius: r), with: .color(snow), style: style(w))
        var spikes = Path()
        for k in 0..<6 {
            let a = Double(k) * .pi / 3 + .pi / 6
            spikes.move(to: .zero)
            spikes.addLine(to: CGPoint(x: cos(a) * r * 0.34, y: sin(a) * r * 0.34))
        }
        ctx.stroke(spikes, with: .color(snow), style: style(w * 0.8))
        var hexagon = Path()
        hexagon.addLines((0..<6).map { k in
            let a = Double(k) * .pi / 3
            return CGPoint(x: cos(a) * r * 0.16, y: sin(a) * r * 0.16)
        })
        hexagon.closeSubpath()
        ctx.stroke(hexagon, with: .color(snow), style: style(w * 0.7))
    }

    /// The app's crystal (`SeasonalAmbiance`'s six branches, three pairs of
    /// barbs), centred on the origin.
    static func crystal(radius r: Double) -> Path {
        var path = Path()
        for k in 0..<6 {
            let a = Double(k) * .pi / 3
            let (ca, sa) = (cos(a), sin(a))
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: ca * r, y: sa * r))
            for (along, length) in [(0.38, 0.30), (0.58, 0.24), (0.78, 0.16)] {
                let base = CGPoint(x: ca * r * along, y: sa * r * along)
                for side in [1.0, -1.0] {
                    let b = a + side * .pi / 4
                    path.move(to: base)
                    path.addLine(to: CGPoint(x: base.x + cos(b) * r * length, y: base.y + sin(b) * r * length))
                }
            }
        }
        return path
    }

    private static func drawFlake(_ flake: FrostSceneMotion.Flake, in ctx: inout GraphicsContext, time: Double?) {
        var layer = ctx
        layer.opacity = flake.far ? 0.55 : 0.9
        layer.translateBy(x: flake.x + FrostSceneMotion.sway(time, period: flake.swayPeriod, phase: flake.swayPhase),
                          y: FrostSceneMotion.fallY(flake, time: time))
        if flake.isDot {
            layer.fill(circle(0, 0, flake.size * 0.45), with: .color(snow))
        } else {
            layer.rotate(by: .degrees(flake.rotation))
            layer.stroke(crystal(radius: flake.size), with: .color(snow),
                         style: StrokeStyle(lineWidth: flake.far ? 0.9 : 1.5, lineCap: .round))
        }
    }

    /// The season's frost: a cold haze and the `SeasonFrost` texture, both
    /// masked to the corners (each a radial fade, 280 units).
    private static func drawFrost(in ctx: inout GraphicsContext) {
        var frosted = ctx
        frosted.clipToLayer { mask in
            for corner in [CGPoint.zero, CGPoint(x: 680, y: 0), CGPoint(x: 0, y: 380), CGPoint(x: 680, y: 380)] {
                mask.fill(Path(bounds), with: .radialGradient(
                    Gradient(stops: [.init(color: .white, location: 0), .init(color: .white.opacity(0.75), location: 0.45),
                                     .init(color: .white.opacity(0), location: 1)]),
                    center: corner, startRadius: 0, endRadius: 280))
            }
        }
        frosted.fill(Path(bounds), with: .color(frost.opacity(0.16)))
        let texture = frosted.resolve(Image("SeasonFrost"))
        var tiles = frosted
        tiles.opacity = 0.85
        let tile = 420.0
        for x in stride(from: 0.0, to: 680, by: tile) {
            for y in stride(from: 0.0, to: 380, by: tile) {
                tiles.draw(texture, in: CGRect(x: x, y: y, width: tile, height: tile))
            }
        }
    }

    private static func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
}

/// The frost scene's stars, falling crystals and motion, pure. `time` is
/// `nil` when motion is off: everything sits where the mockup draws it still.
enum FrostSceneMotion {
    struct Star: Equatable {
        let x, y, r: Double
        /// Where its twinkle starts, in seconds of its 3.2 s loop.
        let phase: Double
    }

    struct Flake: Equatable {
        let x, y: Double
        let size: Double
        /// Far crystals are smaller, fainter and slower.
        let far: Bool
        /// Seconds for one fall across the scene.
        let fallPeriod: Double
        let fallPhase: Double
        let swayPeriod: Double
        let swayPhase: Double
        let rotation: Double
        /// The smallest far ones are dots, not crystals.
        var isDot: Bool { far && size < 4.5 }
    }

    /// The fall runs from 60 above the scene to 80 below it.
    static let fallTop: Double = -60
    static let fallSpan: Double = 520
    static let twinklePeriod: Double = 3.2

    /// The mockup's generator (Park–Miller), so the scene keeps its layout.
    private struct Seeded {
        var seed: Int
        mutating func next() -> Double {
            seed = (seed * 16807) % 2_147_483_647
            return Double(seed - 1) / 2_147_483_646
        }
    }

    static let stars: [Star] = {
        var rand = Seeded(seed: 11)
        return (0..<46).map { _ in
            Star(x: rand.next() * 680, y: rand.next() * 330, r: 0.7 + rand.next() * 1.3, phase: rand.next() * twinklePeriod)
        }
    }()

    static let flakes: [Flake] = {
        var rand = Seeded(seed: 29)
        return (0..<30).map { index in
            let far = index % 3 != 0
            let x = rand.next() * 680, y = rand.next() * 380
            let size = far ? 3 + rand.next() * 3 : 7 + rand.next() * 6
            let period = far ? 14 + rand.next() * 8 : 9 + rand.next() * 4
            return Flake(x: x, y: y, size: size, far: far, fallPeriod: period, fallPhase: rand.next() * period,
                         swayPeriod: 2 * (2.5 + rand.next() * 2), swayPhase: rand.next(), rotation: rand.next() * 60)
        }
    }()

    /// Where a crystal is: still, at its own place; moving, it falls and
    /// comes back in at the top, always inside `fallTop ..< fallTop + fallSpan`.
    static func fallY(_ flake: Flake, time: Double?) -> Double {
        guard let time else { return flake.y }
        let travelled = flake.y - fallTop + fallSpan * (time + flake.fallPhase) / flake.fallPeriod
        let wrapped = travelled.truncatingRemainder(dividingBy: fallSpan)
        return fallTop + (wrapped < 0 ? wrapped + fallSpan : wrapped)
    }

    /// A side-to-side drift of ±9, one full swing per `period`; 0 still.
    static func sway(_ time: Double?, period: Double, phase: Double) -> Double {
        guard let time else { return 0 }
        return -9 * cos(2 * .pi * (time / period + phase))
    }

    /// A star's brightness factor, 0.25 … 1; 1 still.
    static func twinkle(_ time: Double?, phase: Double) -> Double {
        guard let time else { return 1 }
        return 0.25 + 0.75 * (0.5 - 0.5 * cos(2 * .pi * (time + phase) / twinklePeriod))
    }
}
