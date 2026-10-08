import SwiftUI

/// The motif shown on a « Quoi de neuf » page.
///
/// Same register and the same reasons as `CinemaIllustration`: drawn from
/// SwiftUI shapes and **never a screenshot**. A captured screen goes stale at
/// the next UI change and has to be re-shot per platform, per theme, per accent
/// — which is precisely how a "what's new" screen ends up showing an interface
/// the user is not looking at. These follow the user's accent, flip with
/// dark/light and scale through `CinemaScale`, and the motifs do not animate,
/// so there is nothing for Motion Effects or Reduce Motion to switch off — the
/// two exceptions have their own views, whose motion both of them stop:
/// `.halloweenNight` (`WhatsNewHalloweenScene`) and `.duoTable`
/// (`WhatsNewDuoScene`). The onboarding draws its pages with this enum too.
///
/// Kept apart from `CinemaIllustration` on purpose: that enum is the vocabulary
/// of empty and error states, and folding feature art into it would make "which
/// ones may an empty state use?" a question nobody can answer from the type.
enum WhatsNewIllustration: Equatable, Sendable, CaseIterable {
    /// Watch Together — several people on one film.
    case watchTogether
    /// « Lire sur… » — a phone handing a film to the television.
    case playOn
    /// Playlists — a list being reordered.
    case playlists
    /// A release that changed nothing on screen — fixes and performance.
    case underTheHood
    /// The app changed its name, not its content.
    case newName
    /// Parental controls — a longer code being typed.
    case parentalLock
    /// Accessibility — a card held by the VoiceOver cursor.
    case accessibility
    /// The ephemeral « Nuit d'Halloween » theme — a full night scene, wide
    /// rather than square (`isScene`).
    case halloweenNight
    /// The app in the device's language — two speech bubbles, the old one
    /// faded, the new one in the accent.
    case language
    /// iPhone Duo's table mode — a Duo folding onto the table, the film above,
    /// the controls arriving below (`WhatsNewDuoScene`, animated).
    case duoTable
    /// The layout pass for the Duo, folded and open — two screens, one hero.
    case everyScreen
    /// Playback speed that keeps sound and picture together.
    case smoothSpeed
    /// Onboarding — your own server.
    case server
    /// Onboarding — Quick Connect's code.
    case quickConnect
    /// Onboarding — the accent colour and the menu are yours.
    case personalize

    /// Drawn as a wide scene across the page, not a motif on the halo.
    var isScene: Bool { self == .halloweenNight }
}

struct WhatsNewIllustrationView: View {
    let kind: WhatsNewIllustration
    /// Edge of the square canvas in points, before `CinemaScale`.
    var baseSize: CGFloat = 132

    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.self) private var environment

    var body: some View {
        switch kind {
        case .halloweenNight: WhatsNewHalloweenScene()
        case .duoTable: WhatsNewDuoScene(side: CinemaScale.pt(baseSize))
        default: motif
        }
    }

    @ViewBuilder
    private var motif: some View {
        let side = CinemaScale.pt(baseSize)
        // Every motif is laid out on a 100 × 100 grid centred on the canvas;
        // `u` converts grid units to points — the same convention as
        // `CinemaIllustrationView`, so the two read alike side by side.
        let u = side / 100
        ZStack {
            // The approved 2.4.0 mockup's halo: 18 % wider than the motif on
            // every side, accent at 22 % fading out at its edge.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [themeManager.accent.opacity(0.22), themeManager.accent.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: side * 0.68
                    )
                )
                .frame(width: side * 1.36, height: side * 1.36)

            switch kind {
            case .watchTogether: watchTogether(u)
            case .playOn:        playOn(u)
            case .playlists:     playlists(u)
            case .underTheHood:  underTheHood(u)
            case .newName:       newName(u)
            case .parentalLock:  parentalLock(u)
            case .accessibility: accessibility(u)
            case .language:      language(u)
            case .everyScreen, .smoothSpeed, .server, .quickConnect, .personalize:
                MotifCanvas(kind: kind, ink: ink)
            case .halloweenNight, .duoTable: EmptyView()   // drawn by `body` as scenes
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    /// The 2.4.0 motifs' colours, the mockup's: neutral tiles are the text
    /// colour mixed into the page at 14 % and 22 % — opaque, so the halo
    /// stays behind them — marks in `onSurfaceVariant`, one accent gesture.
    private var ink: MotifInk {
        let mix = { (amount: Double) in
            MotifInk.mix(CinemaColor.onSurface, amount, into: CinemaColor.surface, in: environment)
        }
        return MotifInk(tile: mix(0.14), tileHigh: mix(0.22), mark: CinemaColor.onSurfaceVariant,
                        accent: themeManager.accent, text: CinemaColor.onSurface)
    }

    // MARK: - Motifs

    /// The one accent "gesture" each motif carries.
    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [themeManager.accentContainer, themeManager.accentDim],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Three heads on one row, the middle one accent: a session is several
    /// people, and one of them is you.
    private func watchTogether(_ u: CGFloat) -> some View {
        HStack(spacing: -8 * u) {
            head(u, size: 26, fill: AnyShapeStyle(CinemaColor.surfaceContainerHighest))
            head(u, size: 32, fill: AnyShapeStyle(accentGradient))
            head(u, size: 26, fill: AnyShapeStyle(CinemaColor.surfaceContainerHigh))
        }
    }

    private func head(_ u: CGFloat, size: CGFloat, fill: AnyShapeStyle) -> some View {
        Circle()
            .fill(fill)
            .frame(width: size * u, height: size * u)
    }

    /// A portrait slab handing a wide one three accent chevrons: the phone
    /// sends, the television receives.
    private func playOn(_ u: CGFloat) -> some View {
        HStack(spacing: 6 * u) {
            RoundedRectangle(cornerRadius: 3 * u)
                .fill(CinemaColor.surfaceContainerHighest)
                .frame(width: 20 * u, height: 32 * u)
            HStack(spacing: 2 * u) {
                ForEach(0..<3, id: \.self) { step in
                    Triangle()
                        .fill(accentGradient)
                        .frame(width: 5 * u, height: 8 * u)
                        .opacity(0.45 + Double(step) * 0.27)
                }
            }
            RoundedRectangle(cornerRadius: 3 * u)
                .fill(CinemaColor.surfaceContainerHigh)
                .frame(width: 38 * u, height: 24 * u)
        }
    }

    /// Three bars, the accent one pushed out of line — a list caught mid-drag.
    private func playlists(_ u: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6 * u) {
            bar(u, width: 52, fill: AnyShapeStyle(CinemaColor.surfaceContainerHighest))
            bar(u, width: 52, fill: AnyShapeStyle(accentGradient))
                .offset(x: 10 * u)
            bar(u, width: 52, fill: AnyShapeStyle(CinemaColor.surfaceContainerHigh))
        }
    }

    /// A screen with two accent sparkles over it: nothing was moved, the thing
    /// behind it was polished. Deliberately the only motif with no second
    /// object — a fix release has nothing to show, which is what it says.
    private func underTheHood(_ u: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4 * u)
                .fill(CinemaColor.surfaceContainerHighest)
                .frame(width: 54 * u, height: 34 * u)
            Sparkle()
                .fill(accentGradient)
                .frame(width: 20 * u, height: 20 * u)
                .offset(x: 21 * u, y: -19 * u)
            Sparkle()
                .fill(themeManager.accentDim)
                .frame(width: 11 * u, height: 11 * u)
                .offset(x: -23 * u, y: 15 * u)
        }
    }

    /// The same tile beside two labels, the old one faded and the accent one
    /// longer: the app did not move, only what it is called.
    private func newName(_ u: CGFloat) -> some View {
        HStack(spacing: 8 * u) {
            RoundedRectangle(cornerRadius: 9 * u)
                .fill(CinemaColor.surfaceContainerHighest)
                .frame(width: 34 * u, height: 34 * u)
            VStack(alignment: .leading, spacing: 6 * u) {
                bar(u, width: 30, fill: AnyShapeStyle(CinemaColor.surfaceContainerHighest))
                    .opacity(0.6)
                bar(u, width: 40, fill: AnyShapeStyle(accentGradient))
            }
        }
    }

    /// A screen over six code dots, four of them typed in the accent: the
    /// lock's code, now six digits and more.
    private func parentalLock(_ u: CGFloat) -> some View {
        VStack(spacing: 9 * u) {
            RoundedRectangle(cornerRadius: 4 * u)
                .fill(CinemaColor.surfaceContainerHighest)
                .frame(width: 54 * u, height: 30 * u)
            HStack(spacing: 4 * u) {
                ForEach(0..<6, id: \.self) { digit in
                    Circle()
                        .fill(digit < 4 ? AnyShapeStyle(accentGradient)
                                        : AnyShapeStyle(CinemaColor.surfaceContainerHigh))
                        .frame(width: 7 * u, height: 7 * u)
                }
            }
        }
    }

    /// A poster inside an accent frame — the VoiceOver cursor resting on a
    /// card, drawn as a slab behind it rather than a stroke (the register has
    /// none), with the card's caption beneath.
    private func accessibility(_ u: CGFloat) -> some View {
        VStack(spacing: 6 * u) {
            ZStack {
                RoundedRectangle(cornerRadius: 7 * u)
                    .fill(accentGradient)
                    .frame(width: 42 * u, height: 56 * u)
                RoundedRectangle(cornerRadius: 4 * u)
                    .fill(CinemaColor.surfaceContainerHighest)
                    .frame(width: 34 * u, height: 48 * u)
            }
            bar(u, width: 34, fill: AnyShapeStyle(CinemaColor.surfaceContainerHigh))
        }
    }

    /// Two speech bubbles: a neutral one behind, faded, and the accent one in
    /// front carrying two lines — the app answering in another language.
    private func language(_ u: CGFloat) -> some View {
        ZStack {
            bubble(u, width: 44, height: 30, fill: AnyShapeStyle(CinemaColor.surfaceContainerHighest))
                .opacity(0.6)
                .offset(x: -14 * u, y: -12 * u)
            bubble(u, width: 50, height: 34, fill: AnyShapeStyle(accentGradient))
                .overlay {
                    VStack(alignment: .leading, spacing: 5 * u) {
                        bar(u, width: 30, fill: AnyShapeStyle(CinemaColor.surfaceContainerHighest))
                        bar(u, width: 20, fill: AnyShapeStyle(CinemaColor.surfaceContainerHighest))
                    }
                    .scaleEffect(0.7)
                    .offset(y: -2 * u)
                }
                .offset(x: 12 * u, y: 12 * u)
        }
    }

    /// A rounded slab with a small tail at its bottom-leading corner.
    private func bubble(_ u: CGFloat, width: CGFloat, height: CGFloat, fill: AnyShapeStyle) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 9 * u)
                .fill(fill)
                .frame(width: width * u, height: height * u)
            Triangle()
                .fill(fill)
                .frame(width: 9 * u, height: 9 * u)
                .rotationEffect(.degrees(90))
                .offset(x: 7 * u, y: 7 * u)
        }
        .frame(width: width * u, height: (height + 7) * u, alignment: .top)
    }

    private func bar(_ u: CGFloat, width: CGFloat, fill: AnyShapeStyle) -> some View {
        RoundedRectangle(cornerRadius: 3 * u)
            .fill(fill)
            .frame(width: width * u, height: 11 * u)
    }
}

/// A four-pointed star with concave sides — `underTheHood`'s sparkles.
private struct Sparkle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: CGPoint(x: c.x, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: c.y), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: rect.maxY), control: c)
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: c.y), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: rect.minY), control: c)
        path.closeSubpath()
        return path
    }
}

/// A plain right-pointing triangle — `playOn`'s chevrons. Declared here rather
/// than in the design system: nothing else draws one, and a shared shape nobody
/// shares is just a wider surface.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Colours of the motifs drawn by `MotifCanvas`.
struct MotifInk {
    let tile: Color
    let tileHigh: Color
    let mark: Color
    let accent: Color
    let text: Color

    /// `color-mix(in srgb, a amount, b)`, resolved for this environment.
    static func mix(_ a: Color, _ amount: Double, into b: Color, in environment: EnvironmentValues) -> Color {
        let x = a.resolve(in: environment), y = b.resolve(in: environment)
        let f = Float(amount)
        return Color(.sRGB,
                     red: Double(x.red * f + y.red * (1 - f)),
                     green: Double(x.green * f + y.green * (1 - f)),
                     blue: Double(x.blue * f + y.blue * (1 - f)))
    }
}

/// The motifs introduced with 2.4.0 (onboarding + « Quoi de neuf »), drawn on
/// the 100 × 100 grid exactly as the approved mockup's SVG — same rectangles,
/// radii and opacities — so the app and the design cannot drift.
private struct MotifCanvas: View {
    let kind: WhatsNewIllustration
    let ink: MotifInk

    var body: some View {
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 100, y: size.height / 100)
            draw(in: &ctx)
        }
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

    private func draw(in ctx: inout GraphicsContext) {
        switch kind {
        case .server:
            // Three units, the top one switched on.
            rect(&ctx, box(26, 20, 48, 16), 5, ink.tile)
            rect(&ctx, box(26, 42, 48, 16), 5, ink.tile)
            rect(&ctx, box(26, 64, 48, 16), 5, ink.tileHigh)
            dot(&ctx, 64, 28, 3.2, ink.accent)
            dot(&ctx, 64, 50, 3.2, ink.mark, 0.5)
            dot(&ctx, 64, 72, 3.2, ink.mark, 0.5)
            for y in [26.5, 48.5, 70.5] as [CGFloat] { rect(&ctx, box(33, y, 18, 3), 1.5, ink.mark, 0.5) }
        case .quickConnect:
            // Four code tiles, the third being typed.
            rect(&ctx, box(14, 40, 16, 22), 5, ink.tile)
            rect(&ctx, box(34, 40, 16, 22), 5, ink.tile)
            rect(&ctx, box(54, 40, 16, 22), 5, ink.accent)
            rect(&ctx, box(74, 40, 16, 22), 5, ink.tileHigh)
            rect(&ctx, box(20, 49.5, 4, 4), 2, ink.mark)
            rect(&ctx, box(40, 49.5, 4, 4), 2, ink.mark)
            rect(&ctx, box(80, 49.5, 4, 4), 2, ink.mark, 0.5)
        case .personalize:
            // Three swatches, the accent picked, over a slider.
            dot(&ctx, 34, 40, 11, ink.tile)
            dot(&ctx, 54, 40, 11, ink.accent)
            dot(&ctx, 74, 40, 11, ink.tileHigh)
            rect(&ctx, box(20, 62, 62, 8), 4, ink.tile)
            rect(&ctx, box(20, 62, 38, 8), 4, ink.accent)
            dot(&ctx, 58, 66, 7, ink.text)
        case .everyScreen:
            // The closed Duo's narrow screen and the open one, the same hero on both.
            rect(&ctx, box(16, 22, 26, 54), 6, ink.tile)
            rect(&ctx, box(16, 22, 26, 22), 6, ink.accent)
            rect(&ctx, box(20, 50, 8, 11), 2, ink.mark, 0.45)
            rect(&ctx, box(30, 50, 8, 11), 2, ink.mark, 0.45)
            rect(&ctx, box(50, 22, 38, 54), 6, ink.tile)
            rect(&ctx, box(50, 22, 38, 22), 6, ink.accent)
            for x in [54, 65, 76] as [CGFloat] { rect(&ctx, box(x, 50, 9, 12), 2, ink.mark, 0.45) }
        case .smoothSpeed:
            // Fast-forward over a progress bar: faster, still in step.
            rect(&ctx, box(18, 34, 64, 30), 9, ink.tile)
            triangle(&ctx, [CGPoint(x: 38, y: 40), CGPoint(x: 52, y: 49), CGPoint(x: 38, y: 58)], ink.accent)
            triangle(&ctx, [CGPoint(x: 52, y: 40), CGPoint(x: 66, y: 49), CGPoint(x: 52, y: 58)], ink.accent, 0.55)
            rect(&ctx, box(18, 70, 64, 5), 2.5, ink.tileHigh)
            rect(&ctx, box(18, 70, 40, 5), 2.5, ink.accent)
        default:
            break
        }
    }
}
