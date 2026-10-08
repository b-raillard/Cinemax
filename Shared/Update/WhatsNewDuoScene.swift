import SwiftUI

/// iPhone Duo's table mode (2.4.0), drawn: a Duo lying open folds onto the
/// table — the film stays on the upper half, the control deck arrives on the
/// lower one — holds, then opens again, on a `DuoFoldTimeline.period` loop.
///
/// Drawn, never a capture, per the illustration RULE: the film is a letterboxed
/// dusk in the user's accent, the deck the player's real block layout (lock /
/// title / close, −10 / play / +10, the scrub bar, four tracks) in neutral tiles
/// with the play block in the accent. With Motion Effects off or Reduce Motion
/// (`motionEffectsEnabled`) it rests folded, every block in place. Shared by
/// « Quoi de neuf » (iOS `tableMode`, tvOS `duoOnTV`) and the onboarding's
/// Duo page.
struct WhatsNewDuoScene: View {
    /// The edge of the square the other motifs live in, in points.
    let side: CGFloat

    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.motionEffectsEnabled) private var motionEffects

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !motionEffects)) { context in
            let phase: Double? = motionEffects
                ? DuoFoldTimeline.phase(at: context.date.timeIntervalSinceReferenceDate) : nil
            scene(DuoFoldTimeline.pose(at: phase))
        }
        .frame(width: side, height: side * 1.12)
        .accessibilityHidden(true)
    }

    // MARK: - Geometry

    private var deviceWidth: CGFloat { side * 0.66 }
    /// One half of the 2007 × 2853 inner display.
    private var halfHeight: CGFloat { deviceWidth * 1426 / 2007 }
    private var bezel: CGFloat { deviceWidth * 0.035 }
    private var outerRadius: CGFloat { deviceWidth * 0.12 }

    private static let chassis = Color(white: 0.17)
    private static let tile = Color(white: 0.16)
    private static let deckGround = Color(white: 0.07)

    private func scene(_ pose: DuoFoldTimeline.Pose) -> some View {
        ZStack(alignment: .top) {
            Circle()
                .fill(RadialGradient(colors: [themeManager.accent.opacity(0.20), themeManager.accent.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: side / 2))
                .frame(width: side, height: side)
            // The table under the folded half catches the screen's light.
            Ellipse()
                .fill(RadialGradient(colors: [themeManager.accent.opacity(0.30), themeManager.accent.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: side * 0.45))
                .frame(width: side * 1.1, height: side * 0.32)
                .offset(y: halfHeight * 1.05)
                .opacity(pose.glow)

            VStack(spacing: 0) {
                upperHalf
                    .rotation3DEffect(.degrees(-9 * pose.fold), axis: (x: 1, y: 0, z: 0),
                                      anchor: .bottom, perspective: 0.45)
                lowerHalf(pose)
                    .rotation3DEffect(.degrees(62 * pose.fold), axis: (x: 1, y: 0, z: 0),
                                      anchor: .top, perspective: 0.45)
            }
            .frame(width: deviceWidth)
            .rotation3DEffect(.degrees(-14), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
            .padding(.top, side * 0.04)
        }
        .frame(width: side, height: side * 1.12, alignment: .top)
    }

    private var upperHalf: some View {
        film
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: outerRadius - bezel,
                                              topTrailingRadius: outerRadius - bezel))
            .padding([.horizontal, .top], bezel)
            .frame(width: deviceWidth, height: halfHeight)
            .background(Self.chassis, in: UnevenRoundedRectangle(topLeadingRadius: outerRadius,
                                                              bottomLeadingRadius: 2,
                                                              bottomTrailingRadius: 2,
                                                              topTrailingRadius: outerRadius))
    }

    private func lowerHalf(_ pose: DuoFoldTimeline.Pose) -> some View {
        deck(pose)
            .background(Self.deckGround)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: outerRadius - bezel,
                                              bottomTrailingRadius: outerRadius - bezel))
            .padding([.horizontal, .bottom], bezel)
            .frame(width: deviceWidth, height: halfHeight)
            .background(Self.chassis, in: UnevenRoundedRectangle(topLeadingRadius: 2,
                                                              bottomLeadingRadius: outerRadius,
                                                              bottomTrailingRadius: outerRadius,
                                                              topTrailingRadius: 2))
    }

    // MARK: - The film (upper half)

    private var film: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            let frame = CGRect(x: 0, y: h * 0.17, width: w, height: h * 0.66)
            ctx.fill(Path(frame), with: .linearGradient(
                Gradient(colors: [Color(red: 0.05, green: 0.10, blue: 0.17), themeManager.accent.opacity(0.55)]),
                startPoint: CGPoint(x: 0, y: frame.minY), endPoint: CGPoint(x: 0, y: frame.maxY)))
            let sun = CGRect(x: w * 0.56, y: frame.minY + frame.height * 0.22, width: w * 0.2, height: w * 0.2)
            ctx.fill(Path(ellipseIn: sun), with: .color(themeManager.accent.opacity(0.9)))
            var far = Path()
            far.move(to: CGPoint(x: 0, y: frame.minY + frame.height * 0.76))
            far.addQuadCurve(to: CGPoint(x: w * 0.42, y: frame.minY + frame.height * 0.72),
                             control: CGPoint(x: w * 0.2, y: frame.minY + frame.height * 0.5))
            far.addQuadCurve(to: CGPoint(x: w, y: frame.minY + frame.height * 0.66),
                             control: CGPoint(x: w * 0.75, y: frame.minY + frame.height * 0.86))
            far.addLine(to: CGPoint(x: w, y: frame.maxY))
            far.addLine(to: CGPoint(x: 0, y: frame.maxY))
            ctx.fill(far, with: .color(Color(red: 0.04, green: 0.08, blue: 0.13)))
            var near = Path()
            near.move(to: CGPoint(x: 0, y: frame.minY + frame.height * 0.88))
            near.addQuadCurve(to: CGPoint(x: w, y: frame.minY + frame.height * 0.84),
                              control: CGPoint(x: w * 0.6, y: frame.minY + frame.height * 0.7))
            near.addLine(to: CGPoint(x: w, y: frame.maxY))
            near.addLine(to: CGPoint(x: 0, y: frame.maxY))
            ctx.fill(near, with: .color(Color(red: 0.02, green: 0.04, blue: 0.06)))
        }
    }

    // MARK: - The deck (lower half)

    private func deck(_ pose: DuoFoldTimeline.Pose) -> some View {
        let gap = deviceWidth * 0.03
        let radius = deviceWidth * 0.035
        let padH = deviceWidth * 0.06, padV = deviceWidth * 0.05
        // Fixed shares of the deck's height, as on the player: the title row,
        // the big transport blocks, the scrub bar, the four track blocks.
        let inner = max(0, halfHeight - bezel - 2 * padV - 3 * gap)
        return VStack(spacing: gap) {
            HStack(spacing: gap) {
                block(0, pose, radius: radius, glyph: true).frame(width: deviceWidth * 0.12)
                block(1, pose, radius: radius, glyph: false)
                block(2, pose, radius: radius, glyph: true).frame(width: deviceWidth * 0.12)
            }
            .frame(height: inner * 0.17)
            HStack(spacing: gap) {
                block(3, pose, radius: radius, glyph: true)
                playBlock(pose, radius: radius).frame(width: deviceWidth * 0.34)
                block(5, pose, radius: radius, glyph: true)
            }
            .frame(height: inner * 0.42)
            scrubBar(pose, radius: radius)
                .frame(height: inner * 0.13)
            HStack(spacing: gap) {
                ForEach(7..<11, id: \.self) { index in block(index, pose, radius: radius, glyph: true) }
            }
            .frame(height: inner * 0.28)
        }
        .padding(.horizontal, padH)
        .padding(.vertical, padV)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func block(_ index: Int, _ pose: DuoFoldTimeline.Pose, radius: CGFloat, glyph: Bool) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Self.tile)
            .overlay {
                if glyph {
                    Circle().fill(Color.white.opacity(0.75)).frame(width: deviceWidth * 0.045)
                }
            }
            .arriving(pose.tile(index), lift: deviceWidth * 0.03)
    }

    private func playBlock(_ pose: DuoFoldTimeline.Pose, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(themeManager.accentContainer)
            .overlay {
                PlayTriangle()
                    .fill(Color.white)
                    .frame(width: deviceWidth * 0.07, height: deviceWidth * 0.09)
                    .offset(x: deviceWidth * 0.008)
            }
            .arriving(pose.tile(4), lift: deviceWidth * 0.03)
    }

    private func scrubBar(_ pose: DuoFoldTimeline.Pose, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Self.tile)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    let track = proxy.size.width * 0.84
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22)).frame(width: track)
                        Capsule().fill(Color.white).frame(width: track * pose.progress)
                    }
                    .frame(height: proxy.size.height * 0.14)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, proxy.size.width * 0.08)
                }
            }
            .arriving(pose.tile(6), lift: deviceWidth * 0.03)
    }
}

/// The loop's pure timing, so the choreography is testable without a clock.
enum DuoFoldTimeline {
    static let period: Double = 7

    struct Pose: Equatable {
        /// 0 lying open, 1 folded onto the table.
        var fold: Double
        /// The light the folded screen throws on the table.
        var glow: Double
        /// How far the film has played on the deck's scrub bar.
        var progress: Double
        /// Each deck block's arrival, 0…1, in reading order.
        var tiles: [Double]

        func tile(_ index: Int) -> Double { tiles.indices.contains(index) ? tiles[index] : 1 }
    }

    static let tileCount = 11

    /// Where `time` falls in the loop, 0…1.
    static func phase(at time: Double) -> Double {
        let t = time.truncatingRemainder(dividingBy: period) / period
        return t < 0 ? t + 1 : t
    }

    /// `nil` = still: folded, everything in place — Motion Effects off.
    static func pose(at phase: Double?) -> Pose {
        guard let p = phase else {
            return Pose(fold: 1, glow: 1, progress: 0.38, tiles: Array(repeating: 1, count: tileCount))
        }
        let fold = ramp(p, up: 0.14...0.36, down: 0.82...0.96)
        let tiles = (0..<tileCount).map { index in
            let start = 0.30 + Double(index) * 0.01
            return ramp(p, up: start...(start + 0.08), down: 0.84...0.92)
        }
        let progress = 0.2 + 0.32 * eased(clamp((p - 0.40) / 0.44))
        return Pose(fold: fold, glow: ramp(p, up: 0.20...0.40, down: 0.82...0.95), progress: progress, tiles: tiles)
    }

    /// 0 before `up`, rising through it, 1 until `down`, falling back to 0.
    private static func ramp(_ p: Double, up: ClosedRange<Double>, down: ClosedRange<Double>) -> Double {
        if p < up.lowerBound || p >= down.upperBound { return 0 }
        if p < up.upperBound { return eased((p - up.lowerBound) / (up.upperBound - up.lowerBound)) }
        if p < down.lowerBound { return 1 }
        return 1 - eased((p - down.lowerBound) / (down.upperBound - down.lowerBound))
    }

    private static func eased(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}

private extension View {
    /// A deck block fading in while it rises into place.
    func arriving(_ amount: Double, lift: CGFloat) -> some View {
        opacity(amount).offset(y: (1 - amount) * lift)
    }
}

/// The play glyph. Private: the illustration file's `Triangle` is private too,
/// and a shape shared by two motifs is not worth a design-system entry.
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
