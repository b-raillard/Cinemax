import SwiftUI

/// The four 2.6.0 motifs, which MOVE: drawn on the same 100 × 100 grid and in
/// the same ink as `MotifCanvas`, from the approved 2.6.0 mockup's SVG, each
/// looping its own small story. With Motion Effects off or Reduce Motion they
/// rest on the static drawing (`MotifMotion` at `nil`). The halo is drawn
/// around them by `WhatsNewIllustrationView`, like every motif.
struct WhatsNewAnimatedMotif: View {
    let kind: WhatsNewIllustration
    let ink: MotifInk

    @Environment(\.motionEffectsEnabled) private var motionEffects
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !motionEffects)) { context in
            let elapsed: Double? = motionEffects ? context.date.timeIntervalSince(start) : nil
            Canvas { ctx, size in
                ctx.scaleBy(x: size.width / 100, y: size.height / 100)
                MotifMotionDrawing(ink: ink).draw(kind, at: elapsed, in: &ctx)
            }
        }
        .onAppear { start = Date() }
    }
}

/// The mockup's CSS animations, as pure poses. `nil` = still: the static
/// drawing. Translations are in grid units (the CSS percentages of each
/// element's own box, already multiplied out); scales pivot on the element's
/// centre, except the typed bar, which grows from its left edge.
enum MotifMotion {
    /// One element's state. The default is the static drawing.
    struct Layer: Equatable {
        var opacity: Double = 1
        var scale: Double = 1
        var dx: Double = 0
        var dy: Double = 0
    }

    // MARK: « Demander un titre » — 5 s, ease-out

    struct Request: Equatable {
        /// The typed bar's scaleX.
        var typed: Double = 1
        var poster = Layer()
        var pill = Layer()
        var ping = Layer()
    }

    static let requestPeriod: Double = 5

    static func request(at elapsed: Double?) -> Request {
        guard let elapsed else { return Request() }
        let p = phase(elapsed, period: requestPeriod)
        return Request(
            typed: ease(p, [(0, 0), (0.06, 0), (0.28, 1), (1, 1)]),
            poster: Layer(opacity: ease(p, [(0, 0), (0.26, 0), (0.42, 1), (1, 1)]),
                          dy: ease(p, [(0, 3.68), (0.26, 3.68), (0.42, 0), (1, 0)])),
            pill: Layer(opacity: ease(p, [(0, 0), (0.44, 0), (0.54, 1), (1, 1)]),
                        scale: ease(p, [(0, 0.6), (0.44, 0.6), (0.54, 1.06), (0.60, 1), (0.68, 0.92), (0.74, 1), (1, 1)])),
            ping: Layer(opacity: ease(p, [(0, 0), (0.74, 0), (0.80, 1), (1, 1)]),
                        scale: ease(p, [(0, 0), (0.74, 0), (0.80, 1.35), (0.86, 1), (1, 1)])))
    }

    // MARK: « Les épisodes manquants » — 4.6 s, ease-out

    struct Missing: Equatable {
        /// The missing row's group opacity (over its own faded ink).
        var row: Double = 1
        var pill = Layer()
    }

    static let missingPeriod: Double = 4.6

    static func missing(at elapsed: Double?) -> Missing {
        guard let elapsed else { return Missing() }
        let p = phase(elapsed, period: missingPeriod)
        return Missing(
            row: ease(p, [(0, 0), (0.08, 0), (0.30, 1), (1, 1)]),
            pill: Layer(opacity: ease(p, [(0, 0), (0.32, 0), (0.48, 1), (1, 1)]),
                        scale: ease(p, [(0, 1), (0.48, 1), (0.66, 0.9), (0.74, 1), (1, 1)]),
                        dx: ease(p, [(0, 11.4), (0.32, 11.4), (0.48, 0), (1, 0)])))
    }

    // MARK: « Plus rapide à la maison » — ease-in-out loops

    struct Home: Equatable {
        /// The two accent dots between the phone and the house, phone side
        /// first; their opacity is absolute (0.7 at rest).
        var hops = [Layer(opacity: 0.7), Layer(opacity: 0.7)]
        /// The three faint dots of the long way out (0.3 at rest).
        var far = [0.3, 0.3, 0.3]
        /// The server's lit indicator.
        var led: Double = 1
    }

    static let hopPeriod: Double = 1.6
    static let hopDelays: [Double] = [0, 0.25]
    static let farPeriod: Double = 3.6
    static let farDelays: [Double] = [0, 0.6, 1.2]
    static let ledDelay: Double = 0.5

    static func home(at elapsed: Double?) -> Home {
        guard let elapsed else { return Home() }
        let hops = hopDelays.map { delay -> Layer in
            let q = due(elapsed, delay: delay, period: hopPeriod)
            return Layer(opacity: easeInOut(q, [(0, 0.25), (0.3, 1), (0.6, 0.7), (1, 0.25)]),
                         scale: easeInOut(q, [(0, 0.8), (0.3, 1.2), (0.6, 1), (1, 0.8)]))
        }
        let far = farDelays.map { easeInOut(due(elapsed, delay: $0, period: farPeriod), [(0, 0.15), (0.5, 0.45), (1, 0.15)]) }
        let led = easeInOut(due(elapsed, delay: ledDelay, period: hopPeriod), [(0, 1), (0.4, 0.35), (1, 1)])
        return Home(hops: hops, far: far, led: led)
    }

    // MARK: « La qualité de chaque épisode » — 4.4 s, ease-out

    static let tagPeriod: Double = 4.4
    static let tagDelays: [Double] = [0, 0.35, 0.7]

    /// The three tags, top (accent) first.
    static func tags(at elapsed: Double?) -> [Layer] {
        guard let elapsed else { return tagDelays.map { _ in Layer() } }
        return tagDelays.map { delay in
            let q = due(elapsed, delay: delay, period: tagPeriod)
            return Layer(opacity: ease(q, [(0, 0), (0.08, 0), (0.22, 1), (0.88, 1), (1, 0)]),
                         dx: ease(q, [(0, -7), (0.08, -7), (0.22, 0), (1, 0)]))
        }
    }

    // MARK: Clock

    /// Where `time` falls in a loop of `period` seconds, 0 ..< 1.
    static func phase(_ time: Double, period: Double) -> Double {
        let t = time.truncatingRemainder(dividingBy: period) / period
        return t < 0 ? t + 1 : t
    }

    /// A delayed element's phase: before its delay it sits on its first
    /// keyframe (CSS would flash the resting pose), then it loops.
    static func due(_ elapsed: Double, delay: Double, period: Double) -> Double {
        elapsed < delay ? 0 : phase(elapsed - delay, period: period)
    }

    private static func ease(_ p: Double, _ frames: [(Double, Double)]) -> Double {
        DuoFoldTimeline.value(p, frames, DuoFoldTimeline.easeOut)
    }

    private static func easeInOut(_ p: Double, _ frames: [(Double, Double)]) -> Double {
        DuoFoldTimeline.value(p, frames, DuoFoldTimeline.easeInOut)
    }
}

/// Draws one pose of a 2.6.0 motif into a context already scaled to the
/// 100 × 100 grid. Every rectangle, dot and opacity is the mockup's.
private struct MotifMotionDrawing {
    let ink: MotifInk

    func draw(_ kind: WhatsNewIllustration, at elapsed: Double?, in ctx: inout GraphicsContext) {
        switch kind {
        case .seerrRequests: request(MotifMotion.request(at: elapsed), &ctx)
        case .missingEpisodes: missing(MotifMotion.missing(at: elapsed), &ctx)
        case .localAddress: home(MotifMotion.home(at: elapsed), &ctx)
        case .episodeQuality: quality(MotifMotion.tags(at: elapsed), &ctx)
        default: break
        }
    }

    /// A search field being typed, the poster it found, the accent « Demander »
    /// pill on it, and a dot saying the request is on its way.
    private func request(_ pose: MotifMotion.Request, _ ctx: inout GraphicsContext) {
        rect(&ctx, box(14, 14, 72, 14), 7, ink.tile)
        dot(&ctx, 23, 21, 3.2, ink.mark, 0.55)
        var typed = ctx
        typed.translateBy(x: 31, y: 0)
        typed.scaleBy(x: pose.typed, y: 1)
        typed.translateBy(x: -31, y: 0)
        rect(&typed, box(31, 19.5, 30, 3), 1.5, ink.mark, 0.5)
        layer(&ctx, pose.poster, around: CGPoint(x: 50, y: 57)) { g in
            rect(&g, box(33, 34, 34, 46), 6, ink.tileHigh)
            rect(&g, box(39, 41, 22, 3), 1.5, ink.mark, 0.45)
            rect(&g, box(39, 47, 14, 3), 1.5, ink.mark, 0.35)
        }
        layer(&ctx, pose.pill, around: CGPoint(x: 50, y: 77)) { g in
            rect(&g, box(27, 70, 46, 14), 7, ink.accent)
            rect(&g, box(43, 75.5, 22, 3), 1.5, ink.text)
            rect(&g, box(33.5, 75.75, 6, 2.5), 1.25, ink.text)
            rect(&g, box(35.5, 73.75, 2, 6.5), 1, ink.text)
        }
        layer(&ctx, pose.ping, around: CGPoint(x: 67, y: 34)) { g in
            dot(&g, 67, 34, 4.5, ink.accent)
        }
    }

    /// Three episode rows; the missing middle one fades into its place and the
    /// accent report pill slides in beside it, then is pressed.
    private func missing(_ pose: MotifMotion.Missing, _ ctx: inout GraphicsContext) {
        rect(&ctx, box(12, 18, 28, 17), 4, ink.tile)
        rect(&ctx, box(46, 22, 38, 3), 1.5, ink.mark, 0.5)
        rect(&ctx, box(46, 28, 24, 3), 1.5, ink.mark, 0.35)
        layer(&ctx, MotifMotion.Layer(opacity: pose.row), around: CGPoint(x: 39, y: 50)) { g in
            rect(&g, box(12, 41.5, 28, 17), 4, ink.tileHigh, 0.4)
            rect(&g, box(46, 45.5, 20, 3), 1.5, ink.mark, 0.3)
        }
        layer(&ctx, pose.pill, around: CGPoint(x: 65, y: 56.5)) { g in
            rect(&g, box(46, 51, 38, 11), 5.5, ink.accent)
            dot(&g, 54, 56.5, 2.2, ink.text)
            rect(&g, box(59, 55, 19, 3), 1.5, ink.text)
        }
        rect(&ctx, box(12, 65, 28, 17), 4, ink.tile)
        rect(&ctx, box(46, 69, 38, 3), 1.5, ink.mark, 0.5)
        rect(&ctx, box(46, 75, 24, 3), 1.5, ink.mark, 0.35)
    }

    /// The house holding the server and the phone beside it: accent dots hop
    /// the short way home, the long way out stays faint and slow.
    private func home(_ pose: MotifMotion.Home, _ ctx: inout GraphicsContext) {
        triangle(&ctx, [CGPoint(x: 12, y: 46), CGPoint(x: 38, y: 24), CGPoint(x: 64, y: 46)], ink.tileHigh)
        rect(&ctx, box(17, 44, 42, 36), 4, ink.tile)
        rect(&ctx, box(26, 52, 24, 8), 2.5, ink.tileHigh)
        dot(&ctx, 44, 56, 2, ink.accent, pose.led)
        rect(&ctx, box(26, 64, 24, 8), 2.5, ink.tileHigh)
        dot(&ctx, 44, 68, 2, ink.mark, 0.5)
        for (hop, centre) in zip(pose.hops, [CGPoint(x: 70, y: 62), CGPoint(x: 64.5, y: 64)]) {
            dot(&ctx, centre.x, centre.y, 2.2 * hop.scale, ink.accent, hop.opacity)
        }
        rect(&ctx, box(74, 48, 16, 30), 4, ink.tileHigh)
        rect(&ctx, box(76.5, 52, 11, 15), 2.5, ink.accent)
        for (opacity, centre) in zip(pose.far, [CGPoint(x: 72, y: 36), CGPoint(x: 78, y: 29), CGPoint(x: 84, y: 22)]) {
            dot(&ctx, centre.x, centre.y, 1.6, ink.mark, opacity)
        }
    }

    /// A poster; its three tags arrive one after another, the accent one first.
    private func quality(_ tags: [MotifMotion.Layer], _ ctx: inout GraphicsContext) {
        rect(&ctx, box(14, 20, 38, 56), 6, ink.tileHigh)
        triangle(&ctx, [CGPoint(x: 28, y: 40), CGPoint(x: 40, y: 48), CGPoint(x: 28, y: 56)], ink.mark, 0.5)
        let rows = [TagRow(y: 26, fill: ink.accent, mark: ink.text, markOpacity: 1, width: 16),
                    TagRow(y: 43, fill: ink.tile, mark: ink.mark, markOpacity: 0.5, width: 12),
                    TagRow(y: 60, fill: ink.tile, mark: ink.mark, markOpacity: 0.5, width: 18)]
        for (tag, row) in zip(tags, rows) {
            layer(&ctx, tag, around: CGPoint(x: 72, y: row.y + 5.5)) { g in
                rect(&g, box(58, row.y, 28, 11), 5.5, row.fill)
                rect(&g, box(64, row.y + 4, row.width, 3), 1.5, row.mark, row.markOpacity)
            }
        }
    }

    /// One quality tag: its row, its pill and the label mark inside.
    private struct TagRow {
        let y: CGFloat
        let fill: Color
        let mark: Color
        let markOpacity: Double
        let width: CGFloat
    }

    // MARK: Primitives

    /// Draws `body` with `l`'s opacity, offset and scale around `centre`.
    private func layer(_ ctx: inout GraphicsContext, _ l: MotifMotion.Layer, around centre: CGPoint,
                       _ body: (inout GraphicsContext) -> Void) {
        var g = ctx
        g.opacity *= l.opacity
        g.translateBy(x: centre.x + l.dx, y: centre.y + l.dy)
        g.scaleBy(x: l.scale, y: l.scale)
        g.translateBy(x: -centre.x, y: -centre.y)
        body(&g)
    }

    private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    private func rect(_ ctx: inout GraphicsContext, _ frame: CGRect, _ r: CGFloat, _ color: Color,
                      _ opacity: Double = 1) {
        ctx.fill(Path(roundedRect: frame, cornerRadius: r), with: .color(color.opacity(opacity)))
    }

    private func dot(_ ctx: inout GraphicsContext, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat,
                     _ color: Color, _ opacity: Double = 1) {
        ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                 with: .color(color.opacity(opacity)))
    }

    private func triangle(_ ctx: inout GraphicsContext, _ points: [CGPoint], _ color: Color, _ opacity: Double = 1) {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        ctx.fill(path, with: .color(color.opacity(opacity)))
    }
}
