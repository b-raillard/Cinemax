import SwiftUI
import QuartzCore

/// iPhone Duo's table mode (2.4.0), drawn: a Duo lying open folds onto the
/// table — the film stays on the upper half, the control deck arrives on the
/// lower one — holds, then opens again, on a `DuoFoldTimeline.period` loop
/// that starts flat each time the page appears.
///
/// **A port of the approved mockup (2026-10-08), not an interpretation of it**:
/// the device's proportions, colours and radii, the deck's grid, the 3-D
/// projection (`DuoFoldProjection` — CSS `perspective` + `rotateY` + `rotateX`)
/// and every keyframe and easing (`DuoFoldTimeline`) are the mockup's numbers.
/// Drawn, never a capture, per the illustration RULE. With Motion Effects off
/// or Reduce Motion (`motionEffectsEnabled`) it rests folded, every block in
/// place. Shared by « Quoi de neuf » (iOS `tableMode`, tvOS `duoOnTV`) and the
/// onboarding's Duo page.
struct WhatsNewDuoScene: View {
    /// The edge of the square the other motifs live in, in points.
    let side: CGFloat

    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.motionEffectsEnabled) private var motionEffects
    @Environment(\.self) private var environment
    @State private var start = Date()

    /// The device's width — the mockup's 78 % of the motif square (72 % on
    /// the television).
    private var w: CGFloat {
        #if os(tvOS)
        side * 0.72
        #else
        side * 0.78
        #endif
    }
    private var h: CGFloat { w * DuoFoldProjection.halfRatio }
    private var bezel: CGFloat { w * 0.035 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !motionEffects)) { context in
            let elapsed: Double? = motionEffects ? context.date.timeIntervalSince(start) : nil
            scene(DuoFoldTimeline.pose(at: elapsed))
        }
        .frame(width: w, height: w * DuoFoldProjection.boxRatio, alignment: .topLeading)
        .onAppear { start = Date() }
        .accessibilityHidden(true)
    }

    // MARK: - Colours (the mockup's)

    /// The device's screens always show the DARK accent, whatever the app's mode.
    private var screenAccent: Color.Resolved {
        var dark = environment
        dark.colorScheme = .dark
        return themeManager.accent.resolve(in: dark)
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    private static let chassis = rgb(0x050505)
    private static let outline = Color(.sRGB, red: 150 / 255, green: 150 / 255, blue: 150 / 255, opacity: 0.35)
    private static let deckGround = rgb(0x121313)
    private static let tile = rgb(0x262727)

    /// `color-mix(in srgb, accent p, other)`.
    private func mix(_ accent: Color.Resolved, _ p: Float, _ other: SIMD3<Float>) -> Color {
        Color(.sRGB, red: Double(accent.red * p + other.x * (1 - p)),
              green: Double(accent.green * p + other.y * (1 - p)),
              blue: Double(accent.blue * p + other.z * (1 - p)))
    }

    // MARK: - Scene

    private func scene(_ pose: DuoFoldTimeline.Pose) -> some View {
        let box = w * DuoFoldProjection.boxRatio
        return ZStack(alignment: .topLeading) {
            // Halo: 30 % wider each side, 10 % taller, accent 22 % at its heart.
            Ellipse()
                .fill(EllipticalGradient(colors: [themeManager.accent.opacity(0.22), themeManager.accent.opacity(0)],
                                         center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                .frame(width: w * 1.6, height: box * 1.1)
                .offset(x: -w * 0.3)
            // The light the folded screen throws on the table.
            Ellipse()
                .fill(EllipticalGradient(colors: [themeManager.accent.opacity(0.30), themeManager.accent.opacity(0)],
                                         center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                .frame(width: w * 1.2, height: box * 0.30)
                .offset(x: -w * 0.1, y: box * 0.68)
                .opacity(pose.glow)

            upperHalf
                .projectionEffect(ProjectionTransform(
                    DuoFoldProjection.transform(half: .upper, angle: pose.upper, width: w)))
            lowerHalf(pose)
                .projectionEffect(ProjectionTransform(
                    DuoFoldProjection.transform(half: .lower, angle: pose.lower, width: w)))
                .offset(y: h)
        }
        .frame(width: w, height: box, alignment: .topLeading)
    }

    private var upperShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: w * 0.12, bottomLeadingRadius: 2,
                               bottomTrailingRadius: 2, topTrailingRadius: w * 0.12)
    }

    private var lowerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: w * 0.12,
                               bottomTrailingRadius: w * 0.12, topTrailingRadius: 2)
    }

    private var upperHalf: some View {
        film
            .frame(width: w - 2 * bezel, height: h - bezel)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: w * 0.09, topTrailingRadius: w * 0.09))
            .padding(.top, bezel)
            .frame(width: w, height: h, alignment: .top)
            .background(Self.chassis, in: upperShape)
            .overlay(upperShape.stroke(Self.outline, lineWidth: 1).padding(-0.5))
    }

    private func lowerHalf(_ pose: DuoFoldTimeline.Pose) -> some View {
        deck(pose, width: w - 2 * bezel, height: h - bezel)
            .background(Self.deckGround)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: w * 0.09, bottomTrailingRadius: w * 0.09))
            .frame(width: w, height: h, alignment: .top)
            .background(Self.chassis, in: lowerShape)
            .overlay(lowerShape.stroke(Self.outline, lineWidth: 1).padding(-0.5))
    }

    // MARK: - The film (upper half) — the mockup's 200 × 142 SVG, sliced to fill

    private var film: some View {
        let accent = screenAccent
        let skyBottom = mix(accent, 0.45, SIMD3(0x12, 0x23, 0x3A) / 255)
        return Canvas { ctx, size in
            let s = max(size.width / 200, size.height / 142)
            ctx.translateBy(x: (size.width - 200 * s) / 2, y: (size.height - 142 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            ctx.fill(Path(CGRect(x: 0, y: 0, width: 200, height: 142)), with: .color(.black))
            ctx.fill(Path(CGRect(x: 0, y: 24, width: 200, height: 94)),
                     with: .linearGradient(Gradient(colors: [Self.rgb(0x0D1A2B), skyBottom]),
                                           startPoint: CGPoint(x: 0, y: 24), endPoint: CGPoint(x: 0, y: 118)))
            ctx.fill(Path(ellipseIn: CGRect(x: 108, y: 50, width: 40, height: 40)),
                     with: .color(Color(accent).opacity(0.85)))
            // M0 96 Q40 72 82 92 T160 86 T200 90 V118 H0Z
            var far = Path()
            far.move(to: CGPoint(x: 0, y: 96))
            far.addQuadCurve(to: CGPoint(x: 82, y: 92), control: CGPoint(x: 40, y: 72))
            far.addQuadCurve(to: CGPoint(x: 160, y: 86), control: CGPoint(x: 124, y: 112))
            far.addQuadCurve(to: CGPoint(x: 200, y: 90), control: CGPoint(x: 196, y: 60))
            far.addLine(to: CGPoint(x: 200, y: 118))
            far.addLine(to: CGPoint(x: 0, y: 118))
            far.closeSubpath()
            ctx.fill(far, with: .color(Self.rgb(0x0B1420)))
            // M0 106 Q60 90 120 104 T200 100 V118 H0Z
            var near = Path()
            near.move(to: CGPoint(x: 0, y: 106))
            near.addQuadCurve(to: CGPoint(x: 120, y: 104), control: CGPoint(x: 60, y: 90))
            near.addQuadCurve(to: CGPoint(x: 200, y: 100), control: CGPoint(x: 180, y: 118))
            near.addLine(to: CGPoint(x: 200, y: 118))
            near.addLine(to: CGPoint(x: 0, y: 118))
            near.closeSubpath()
            ctx.fill(near, with: .color(Self.rgb(0x050A10)))
        }
    }

    // MARK: - The deck (lower half) — the mockup's grid

    private func deck(_ pose: DuoFoldTimeline.Pose, width sw: CGFloat, height sh: CGFloat) -> some View {
        // inset 7 % 6 % 9 %; rows 1fr 2.3fr .8fr 1.3fr, gap 6 %; columns gap 4 %.
        let dw = sw * 0.88, dh = sh * 0.84
        let rowGap = dh * 0.06, unit = (dh - 3 * rowGap) / 5.4, colGap = dw * 0.04
        let side3 = (dw - 2 * colGap) / 7
        let block = (dw - 2 * colGap) / 3.5
        let track = (dw - 3 * colGap) / 4
        return VStack(spacing: rowGap) {
            HStack(spacing: colGap) {
                tile(0, pose, width: side3, height: unit, glyph: true)
                tile(1, pose, width: side3 * 5, height: unit, glyph: false)
                tile(2, pose, width: side3, height: unit, glyph: true)
            }
            HStack(spacing: colGap) {
                tile(3, pose, width: block, height: unit * 2.3, glyph: true)
                playTile(pose, width: block * 1.5, height: unit * 2.3)
                tile(5, pose, width: block, height: unit * 2.3, glyph: true)
            }
            scrubBar(pose, width: dw, height: unit * 0.8)
            HStack(spacing: colGap) {
                ForEach(7..<11, id: \.self) { index in
                    tile(index, pose, width: track, height: unit * 1.3, glyph: true)
                }
            }
        }
        .frame(width: dw, height: dh, alignment: .top)
        .padding(.top, sh * 0.07)
        .frame(width: sw, height: sh, alignment: .top)
    }

    private func tile(_ index: Int, _ pose: DuoFoldTimeline.Pose, width: CGFloat, height: CGFloat,
                      glyph: Bool) -> some View {
        RoundedRectangle(cornerRadius: w * 0.035)
            .fill(Self.tile)
            .overlay {
                if glyph {
                    Circle().fill(Color.white.opacity(0.75)).frame(width: width * 0.32, height: width * 0.32)
                }
            }
            .frame(width: width, height: height)
            .opacity(pose.tiles[index].opacity)
            .offset(y: pose.tiles[index].lift * height)
    }

    private func playTile(_ pose: DuoFoldTimeline.Pose, width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: w * 0.035)
            .fill(mix(screenAccent, 0.85, .zero))
            .overlay {
                PlayTriangle()
                    .fill(Color.white)
                    .frame(width: w * 0.07, height: w * 0.09)
                    .offset(x: w * 0.0105)
            }
            .frame(width: width, height: height)
            .scaleEffect(pose.play.scale)
            .opacity(pose.play.opacity)
    }

    private func scrubBar(_ pose: DuoFoldTimeline.Pose, width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: w * 0.035)
            .fill(Self.tile)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22)).frame(width: width * 0.84)
                    Capsule().fill(Color.white).frame(width: width * pose.progress)
                }
                .frame(height: height * 0.10)
                .offset(x: width * 0.08, y: height * 0.45)
            }
            .frame(width: width, height: height)
            .opacity(pose.tiles[6].opacity)
            .offset(y: pose.tiles[6].lift * height)
    }
}

// MARK: - Timing

/// The loop's keyframes, the mockup's CSS animations: `up` / `down`
/// (cubic-bezier(.45,0,.2,1)), `pop` / `popPlay` (ease-out, each block 0.07 s
/// after the previous one), `prog` (linear), `glow` (ease-in-out). Pure, so
/// the choreography is tested without a clock.
enum DuoFoldTimeline {
    static let period: Double = 7
    static let tileCount = 11
    static let stagger: Double = 0.07

    struct Tile: Equatable {
        var opacity: Double
        /// translateY, as a fraction of the block's own height.
        var lift: Double
    }

    struct Play: Equatable {
        var opacity: Double
        var scale: Double
    }

    struct Pose: Equatable {
        /// rotateX of the upper half, degrees (0 → −9).
        var upper: Double
        /// rotateX of the lower half, degrees (0 → 62).
        var lower: Double
        var glow: Double
        /// The scrub bar's played part, as a fraction of the bar.
        var progress: Double
        /// Reading order: title row 0–2, transport 3–5 (4 = play), scrub bar 6, tracks 7–10.
        var tiles: [Tile]
        var play: Play
    }

    /// `elapsed` seconds since the page appeared; `nil` = still (Motion
    /// Effects off): folded, every block in place.
    static func pose(at elapsed: Double?) -> Pose {
        guard let elapsed else {
            return Pose(upper: -9, lower: 62, glow: 1, progress: 0.38,
                        tiles: Array(repeating: Tile(opacity: 1, lift: 0), count: tileCount),
                        play: Play(opacity: 1, scale: 1))
        }
        let p = phase(elapsed)
        let shown: [(Double, Double)] = [(0, 0), (0.30, 0), (0.40, 1), (0.84, 1), (0.92, 0), (1, 0)]
        let tiles = (0..<tileCount).map { index -> Tile in
            let q = due(elapsed, delay: Double(index) * stagger)
            return Tile(opacity: value(q, shown, easeOut),
                        lift: value(q, [(0, 0.14), (0.30, 0.14), (0.40, 0), (1, 0)], easeOut))
        }
        let q = due(elapsed, delay: 4 * stagger)
        let play = Play(opacity: value(q, shown, easeOut),
                        scale: value(q, [(0, 0.7), (0.30, 0.7), (0.40, 1.08), (0.46, 1), (1, 1)], easeOut))
        return Pose(
            upper: value(p, [(0, 0), (0.14, 0), (0.36, -9), (0.82, -9), (0.96, 0), (1, 0)], fold),
            lower: value(p, [(0, 0), (0.14, 0), (0.36, 62), (0.82, 62), (0.96, 0), (1, 0)], fold),
            glow: value(p, [(0, 0), (0.20, 0), (0.40, 1), (0.82, 1), (0.95, 0), (1, 0)], easeInOut),
            progress: value(p, [(0, 0.20), (0.40, 0.20), (0.84, 0.52), (1, 0.52)], { $0 }),
            tiles: tiles,
            play: play)
    }

    /// A staggered block's phase: before its first delay has elapsed it has
    /// not started (phase 0, hidden), not wrapped into the end of a loop.
    private static func due(_ elapsed: Double, delay: Double) -> Double {
        elapsed < delay ? 0 : phase(elapsed - delay)
    }

    /// Where `time` falls in the loop, 0 ..< 1.
    static func phase(_ time: Double) -> Double {
        let t = time.truncatingRemainder(dividingBy: period) / period
        return t < 0 ? t + 1 : t
    }

    /// Piecewise keyframes, each segment eased like a CSS keyframe.
    private static func value(_ p: Double, _ frames: [(Double, Double)], _ ease: (Double) -> Double) -> Double {
        for (a, b) in zip(frames, frames.dropFirst()) where p >= a.0 && p <= b.0 {
            if a.1 == b.1 || b.0 == a.0 { return a.1 }
            return a.1 + (b.1 - a.1) * ease((p - a.0) / (b.0 - a.0))
        }
        return frames.last?.1 ?? 0
    }

    private static let fold = bezier(0.45, 0, 0.2, 1)
    private static let easeOut = bezier(0, 0, 0.58, 1)
    private static let easeInOut = bezier(0.42, 0, 0.58, 1)

    /// CSS `cubic-bezier(x1, y1, x2, y2)`.
    private static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> @Sendable (Double) -> Double {
        { x in
            func curve(_ t: Double, _ a: Double, _ b: Double) -> Double {
                3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
            }
            var lo = 0.0, hi = 1.0
            for _ in 0..<30 {
                let mid = (lo + hi) / 2
                if curve(mid, x1, x2) < x { lo = mid } else { hi = mid }
            }
            return curve((lo + hi) / 2, y1, y2)
        }
    }
}

// MARK: - Projection

/// The mockup's 3-D: `.duoPersp { perspective: 4.2w; perspective-origin:
/// 50% -30% }` around `.duoRig { rotateY(-14deg) }` around each half's
/// `rotateX`, hinged at the fold. One `CATransform3D` per half, in that
/// half's own coordinates.
enum DuoFoldProjection {
    enum Half { case upper, lower }

    /// One half of the 2007 × 2853 inner display.
    static let halfRatio: CGFloat = 0.7105
    /// The art's layout box, height ÷ width.
    static let boxRatio: CGFloat = 1.44
    static let yaw: CGFloat = -14

    static func transform(half: Half, angle: Double, width w: CGFloat) -> CATransform3D {
        let h = w * halfRatio
        let offset: CGFloat = half == .upper ? 0 : h
        // Both halves' transform-origin, and the rig's centre: the hinge.
        let hinge = CGPoint(x: w / 2, y: h)
        let eye = CGPoint(x: w / 2, y: -0.3 * boxRatio * w)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / (4.2 * w)

        // Row vectors: each step applies after the previous one.
        var m = CATransform3DMakeTranslation(-hinge.x, offset - hinge.y, 0)
        m = CATransform3DConcat(m, CATransform3DMakeRotation(CGFloat(angle) * .pi / 180, 1, 0, 0))
        m = CATransform3DConcat(m, CATransform3DMakeRotation(yaw * .pi / 180, 0, 1, 0))
        m = CATransform3DConcat(m, CATransform3DMakeTranslation(hinge.x - eye.x, hinge.y - eye.y, 0))
        m = CATransform3DConcat(m, perspective)
        m = CATransform3DConcat(m, CATransform3DMakeTranslation(eye.x, eye.y - offset, 0))
        return m
    }

    /// Where `point` (in the half's own coordinates) is drawn.
    static func project(_ point: CGPoint, half: Half, angle: Double, width: CGFloat) -> CGPoint {
        let m = transform(half: half, angle: angle, width: width)
        let x = point.x * m.m11 + point.y * m.m21 + m.m41
        let y = point.x * m.m12 + point.y * m.m22 + m.m42
        let w = point.x * m.m14 + point.y * m.m24 + m.m44
        return CGPoint(x: x / w, y: y / w)
    }
}

/// The play glyph.
private struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
