import SwiftUI

// MARK: - Skeleton building blocks

/// Shimmering placeholder block used to sketch a screen's layout while its
/// data loads (replaces the centered spinner on Home / Library, which gave no
/// hint of what was coming and made load latency feel longer).
///
/// The sweep is a translating linear-gradient highlight; when Motion Effects
/// is off the block renders as a static tinted shape (no animation at all,
/// matching the app-wide motion gate).
struct SkeletonBlock: View {
    var cornerRadius: CGFloat = CinemaRadius.large

    @Environment(\.motionEffectsEnabled) private var motionEffects
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(CinemaColor.surfaceContainerHigh)
            .overlay {
                if motionEffects {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [
                                .clear,
                                CinemaColor.surfaceContainerHighest.opacity(0.9),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.6)
                        // phase -1…1 maps the highlight from fully off-screen
                        // left to fully off-screen right.
                        .offset(x: phase * geo.size.width * 1.6)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onAppear {
                guard motionEffects else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Page skeleton (Home / Library browse)

/// Full-page placeholder mirroring the hero + content-rows layout shared by
/// `HomeScreen` and `MediaLibraryScreen`'s browse view. Sizing is injected by
/// the caller so the skeleton matches the screen's own adaptive metrics
/// (tvOS vs iPhone vs iPad) without duplicating them here.
struct MediaPageSkeleton: View {
    enum RowKind {
        /// 16:9 wide cards (continue watching).
        case wide
        /// 2:3 poster cards (recently added, genre rows).
        case poster
    }

    let heroHeight: CGFloat
    let rows: [RowKind]
    let posterCardWidth: CGFloat
    let wideCardWidth: CGFloat
    let horizontalPadding: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
            SkeletonBlock(cornerRadius: 0)
                .frame(maxWidth: .infinity)
                .frame(height: heroHeight)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, kind in
                rowSkeleton(kind)
            }

            Spacer(minLength: 0)
        }
        // Static sketch — never scrollable, never interactive.
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    @ViewBuilder
    private func rowSkeleton(_ kind: RowKind) -> some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            // Row title placeholder.
            SkeletonBlock(cornerRadius: CinemaRadius.small)
                .frame(width: 160, height: CinemaScale.pt(18))
                .padding(.horizontal, horizontalPadding)

            HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
                switch kind {
                case .wide:
                    ForEach(0..<6, id: \.self) { _ in
                        SkeletonBlock()
                            .frame(width: wideCardWidth, height: wideCardWidth * 9 / 16)
                    }
                case .poster:
                    ForEach(0..<10, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                            SkeletonBlock()
                                .frame(width: posterCardWidth, height: posterCardWidth * 3 / 2)
                            SkeletonBlock(cornerRadius: CinemaRadius.small)
                                .frame(width: posterCardWidth * 0.7, height: CinemaScale.pt(12))
                        }
                    }
                }
            }
            .padding(.horizontal, horizontalPadding)
        }
    }
}

#if DEBUG
#Preview("MediaPageSkeleton") {
    MediaPageSkeleton(
        heroHeight: 360,
        rows: [.wide, .poster],
        posterCardWidth: 140,
        wideCardWidth: 280,
        horizontalPadding: CinemaSpacing.spacing3
    )
    .background(CinemaColor.surface)
}
#endif
