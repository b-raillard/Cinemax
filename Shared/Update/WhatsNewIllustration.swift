import SwiftUI

/// The motif shown on a « Quoi de neuf » page.
///
/// Same register and the same reasons as `CinemaIllustration`: drawn from
/// SwiftUI shapes and **never a screenshot**. A captured screen goes stale at
/// the next UI change and has to be re-shot per platform, per theme, per accent
/// — which is precisely how a "what's new" screen ends up showing an interface
/// the user is not looking at. These follow the user's accent, flip with
/// dark/light and scale through `CinemaScale`, and nothing here animates, so
/// there is nothing for Motion Effects or Reduce Motion to switch off.
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
}

struct WhatsNewIllustrationView: View {
    let kind: WhatsNewIllustration
    /// Edge of the square canvas in points, before `CinemaScale`.
    var baseSize: CGFloat = 132

    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        let side = CinemaScale.pt(baseSize)
        // Every motif is laid out on a 100 × 100 grid centred on the canvas;
        // `u` converts grid units to points — the same convention as
        // `CinemaIllustrationView`, so the two read alike side by side.
        let u = side / 100
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [themeManager.accent.opacity(0.20), themeManager.accent.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: side / 2
                    )
                )

            switch kind {
            case .watchTogether: watchTogether(u)
            case .playOn:        playOn(u)
            case .playlists:     playlists(u)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
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

    private func bar(_ u: CGFloat, width: CGFloat, fill: AnyShapeStyle) -> some View {
        RoundedRectangle(cornerRadius: 3 * u)
            .fill(fill)
            .frame(width: width * u, height: 11 * u)
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
