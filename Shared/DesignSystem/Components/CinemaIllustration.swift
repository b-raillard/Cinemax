import SwiftUI

/// Themed vector illustrations for the app's empty and error states.
///
/// Drawn from SwiftUI shapes, never raster assets, so they follow the user's
/// accent, flip with dark / light mode (every fill is a `CinemaColor` token or
/// a `themeManager.accent*` slot) and scale through `CinemaScale` — the tvOS
/// 1.4× base and the user's text-size slider included. Deliberately few and
/// quiet, in the Cinema Glass register: a soft accent halo, one or two neutral
/// tiles, one accent gesture, no strokes. Static — nothing here animates, so
/// there is nothing for Motion Effects or Reduce Motion to switch off.
///
/// Opt-in: `EmptyStateView` / `ErrorStateView` take an optional
/// `illustration:` and keep their SF Symbol when it is `nil`.
enum CinemaIllustration: CaseIterable, Sendable {
    /// A library with nothing in it (Home's all-empty state).
    case emptyLibrary
    /// A search that matched nothing.
    case noResults
    /// The server could not be reached.
    case offline
    /// No favourites yet.
    case noFavorites
}

struct CinemaIllustrationView: View {
    let kind: CinemaIllustration
    /// Edge of the square canvas in points, before `CinemaScale`.
    var baseSize: CGFloat = 112

    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        let side = CinemaScale.pt(baseSize)
        // Every motif is laid out on a 100 × 100 grid centred on the canvas;
        // `u` converts grid units to points.
        let u = side / 100
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [themeManager.accent.opacity(0.22), themeManager.accent.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: side / 2
                    )
                )

            switch kind {
            case .emptyLibrary: emptyLibrary(u)
            case .noResults:    noResults(u)
            case .offline:      offline(u)
            case .noFavorites:  noFavorites(u)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    // MARK: - Motifs

    /// Accent fill shared by the one "gesture" of each motif.
    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [themeManager.accentContainer, themeManager.accentDim],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Three posters on a shelf — the front one carries a play mark.
    private func emptyLibrary(_ u: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(CinemaColor.onSurface.opacity(0.08))
                .frame(width: 64 * u, height: 5 * u)
                .offset(y: 34 * u)

            RoundedRectangle(cornerRadius: 5 * u, style: .continuous)
                .fill(CinemaColor.surfaceContainerHighest)
                .frame(width: 32 * u, height: 46 * u)
                .rotationEffect(.degrees(-12))
                .offset(x: -18 * u, y: 4 * u)

            RoundedRectangle(cornerRadius: 5 * u, style: .continuous)
                .fill(CinemaColor.surfaceContainerHigh)
                .frame(width: 32 * u, height: 46 * u)
                .rotationEffect(.degrees(12))
                .offset(x: 18 * u, y: 4 * u)

            RoundedRectangle(cornerRadius: 6 * u, style: .continuous)
                .fill(accentGradient)
                .frame(width: 38 * u, height: 54 * u)

            PlayTriangle()
                .fill(themeManager.onAccent.opacity(0.9))
                .frame(width: 13 * u, height: 15 * u)
                .offset(x: 1.5 * u)
        }
    }

    /// An empty lens over two faint result cards.
    private func noResults(_ u: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4 * u, style: .continuous)
                .fill(CinemaColor.surfaceContainerHigh)
                .frame(width: 26 * u, height: 36 * u)
                .rotationEffect(.degrees(-8))
                .offset(x: -23 * u, y: 10 * u)

            RoundedRectangle(cornerRadius: 4 * u, style: .continuous)
                .fill(CinemaColor.surfaceContainerHigh)
                .frame(width: 26 * u, height: 36 * u)
                .rotationEffect(.degrees(8))
                .offset(x: 23 * u, y: 10 * u)

            // Handle first, so the ring overlaps its root.
            Capsule()
                .fill(themeManager.accent)
                .frame(width: 8 * u, height: 24 * u)
                .rotationEffect(.degrees(-45))
                .offset(x: 16 * u, y: 15 * u)

            // Ring as two fills rather than a stroke: an accent disc under a
            // neutral one.
            Circle()
                .fill(themeManager.accent)
                .frame(width: 46 * u, height: 46 * u)
                .offset(x: -5 * u, y: -6 * u)

            // Left empty on purpose: a dash in the lens reads as "zoom out".
            Circle()
                .fill(CinemaColor.surfaceContainerHighest)
                .frame(width: 34 * u, height: 34 * u)
                .offset(x: -5 * u, y: -6 * u)
        }
    }

    /// A cloud crossed out — the server is out of reach.
    private func offline(_ u: CGFloat) -> some View {
        ZStack {
            // Four opaque shapes in ONE token read as a single cloud; they must
            // stay fully opaque or the overlaps would show.
            Group {
                Circle()
                    .frame(width: 28 * u, height: 28 * u)
                    .offset(x: -14 * u, y: 4 * u)
                Circle()
                    .frame(width: 36 * u, height: 36 * u)
                    .offset(x: 2 * u, y: -4 * u)
                Circle()
                    .frame(width: 24 * u, height: 24 * u)
                    .offset(x: 17 * u, y: 6 * u)
                Capsule()
                    .frame(width: 66 * u, height: 24 * u)
                    .offset(x: 1 * u, y: 10 * u)
            }
            .foregroundStyle(CinemaColor.surfaceContainerHighest)

            Capsule()
                .fill(themeManager.accent)
                .frame(width: 7 * u, height: 72 * u)
                .rotationEffect(.degrees(-45))
                .offset(y: 2 * u)
        }
    }

    /// An empty heart: an accent heart under a neutral one, plus two sparkles.
    private func noFavorites(_ u: CGFloat) -> some View {
        ZStack {
            HeartShape()
                .fill(accentGradient)
                .frame(width: 60 * u, height: 55 * u)
                .offset(y: 2 * u)

            HeartShape()
                .fill(CinemaColor.surfaceContainerHighest)
                .frame(width: 44 * u, height: 40 * u)
                .offset(y: 1 * u)

            SparkleShape()
                .fill(themeManager.accent)
                .frame(width: 12 * u, height: 12 * u)
                .offset(x: 31 * u, y: -26 * u)

            SparkleShape()
                .fill(themeManager.accent.opacity(0.6))
                .frame(width: 8 * u, height: 8 * u)
                .offset(x: -33 * u, y: -18 * u)
        }
    }
}

// MARK: - Shapes

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

/// The Material heart, normalised to its bounding box — cubic curves only.
private struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: p(0.5, 1.0))
        path.addLine(to: p(0.4275, 0.928))
        path.addCurve(to: p(0, 0.2997), control1: p(0.17, 0.6736), control2: p(0, 0.5057))
        path.addCurve(to: p(0.275, 0), control1: p(0, 0.1319), control2: p(0.121, 0))
        path.addCurve(to: p(0.5, 0.1139), control1: p(0.362, 0), control2: p(0.4455, 0.0441))
        path.addCurve(to: p(0.725, 0), control1: p(0.5545, 0.0441), control2: p(0.638, 0))
        path.addCurve(to: p(1, 0.2997), control1: p(0.879, 0), control2: p(1, 0.1319))
        path.addCurve(to: p(0.5725, 0.9286), control1: p(1, 0.5057), control2: p(0.83, 0.6736))
        path.closeSubpath()
        return path
    }
}

/// A four-point sparkle.
private struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let kx = rect.width * 0.14
        let ky = rect.height * 0.14
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: c.y), control: CGPoint(x: c.x + kx, y: c.y - ky))
        path.addQuadCurve(to: CGPoint(x: c.x, y: rect.maxY), control: CGPoint(x: c.x + kx, y: c.y + ky))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: c.y), control: CGPoint(x: c.x - kx, y: c.y + ky))
        path.addQuadCurve(to: CGPoint(x: c.x, y: rect.minY), control: CGPoint(x: c.x - kx, y: c.y - ky))
        path.closeSubpath()
        return path
    }
}

#if DEBUG
#Preview("CinemaIllustration — all") {
    HStack(spacing: CinemaSpacing.spacing4) {
        ForEach(CinemaIllustration.allCases, id: \.self) { kind in
            CinemaIllustrationView(kind: kind)
        }
    }
    .padding(CinemaSpacing.spacing6)
    .background(CinemaColor.surface)
    .environment(ThemeManager())
}
#endif
