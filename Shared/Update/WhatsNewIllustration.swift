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
            case .underTheHood:  underTheHood(u)
            case .newName:       newName(u)
            case .parentalLock:  parentalLock(u)
            case .accessibility: accessibility(u)
            case .language:      language(u)
            case .everyScreen:   everyScreen(u)
            case .smoothSpeed:   smoothSpeed(u)
            case .server:        server(u)
            case .quickConnect:  quickConnect(u)
            case .personalize:   personalize(u)
            case .halloweenNight, .duoTable: EmptyView()   // drawn by `body` as scenes
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

    /// Two screens side by side, the closed Duo's narrow one and the open
    /// one, each topped by the same accent hero: one layout, every screen.
    private func everyScreen(_ u: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 8 * u) {
            screen(u, width: 26, columns: 2)
            screen(u, width: 40, columns: 3)
        }
    }

    private func screen(_ u: CGFloat, width: CGFloat, columns: Int) -> some View {
        VStack(spacing: 5 * u) {
            Rectangle()
                .fill(accentGradient)
                .frame(height: 20 * u)
            HStack(spacing: 3 * u) {
                ForEach(0..<columns, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2 * u)
                        .fill(CinemaColor.surfaceContainerHigh)
                        .frame(height: 13 * u)
                }
            }
            .padding(.horizontal, 4 * u)
            Spacer(minLength: 0)
        }
        .frame(width: width * u, height: 54 * u)
        .background(CinemaColor.surfaceContainerHighest)
        .clipShape(RoundedRectangle(cornerRadius: 6 * u))
    }

    /// A double chevron over a progress bar: faster, and still in step.
    private func smoothSpeed(_ u: CGFloat) -> some View {
        VStack(spacing: 8 * u) {
            HStack(spacing: 0) {
                Triangle().fill(accentGradient).frame(width: 13 * u, height: 16 * u)
                Triangle().fill(themeManager.accentDim).frame(width: 13 * u, height: 16 * u)
            }
            .frame(width: 56 * u, height: 30 * u)
            .background(CinemaColor.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: 9 * u))
            ZStack(alignment: .leading) {
                Capsule().fill(CinemaColor.surfaceContainerHigh).frame(width: 56 * u, height: 5 * u)
                Capsule().fill(accentGradient).frame(width: 36 * u, height: 5 * u)
            }
        }
    }

    /// Three stacked units, the top one lit in the accent: a server of your
    /// own, switched on.
    private func server(_ u: CGFloat) -> some View {
        VStack(spacing: 6 * u) {
            ForEach(0..<3, id: \.self) { unit in
                RoundedRectangle(cornerRadius: 5 * u)
                    .fill(unit == 2 ? CinemaColor.surfaceContainerHigh : CinemaColor.surfaceContainerHighest)
                    .frame(width: 50 * u, height: 16 * u)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(CinemaColor.onSurfaceVariant.opacity(0.35))
                            .frame(width: 18 * u, height: 3 * u)
                            .padding(.leading, 7 * u)
                    }
                    .overlay(alignment: .trailing) {
                        Circle()
                            .fill(unit == 0 ? AnyShapeStyle(accentGradient)
                                            : AnyShapeStyle(CinemaColor.onSurfaceVariant.opacity(0.35)))
                            .frame(width: 6 * u, height: 6 * u)
                            .padding(.trailing, 7 * u)
                    }
            }
        }
    }

    /// Four code tiles, the third one being typed in the accent.
    private func quickConnect(_ u: CGFloat) -> some View {
        HStack(spacing: 4 * u) {
            ForEach(0..<4, id: \.self) { digit in
                RoundedRectangle(cornerRadius: 5 * u)
                    .fill(digit == 2 ? AnyShapeStyle(accentGradient)
                                     : AnyShapeStyle(digit == 3 ? CinemaColor.surfaceContainerHigh
                                                                : CinemaColor.surfaceContainerHighest))
                    .frame(width: 16 * u, height: 22 * u)
                    .overlay {
                        if digit < 2 {
                            Circle()
                                .fill(CinemaColor.onSurfaceVariant.opacity(0.6))
                                .frame(width: 4 * u, height: 4 * u)
                        }
                    }
            }
        }
    }

    /// Three swatches, the accent one picked, over a slider: the colour and
    /// the text size are yours.
    private func personalize(_ u: CGFloat) -> some View {
        VStack(spacing: 10 * u) {
            HStack(spacing: 5 * u) {
                head(u, size: 20, fill: AnyShapeStyle(CinemaColor.surfaceContainerHighest))
                head(u, size: 24, fill: AnyShapeStyle(accentGradient))
                head(u, size: 20, fill: AnyShapeStyle(CinemaColor.surfaceContainerHigh))
            }
            ZStack(alignment: .leading) {
                Capsule().fill(CinemaColor.surfaceContainerHigh).frame(width: 60 * u, height: 7 * u)
                Capsule().fill(accentGradient).frame(width: 38 * u, height: 7 * u)
                Circle().fill(CinemaColor.onSurface).frame(width: 13 * u, height: 13 * u).offset(x: 31 * u)
            }
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
