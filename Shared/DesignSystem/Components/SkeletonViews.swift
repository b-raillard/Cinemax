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

    /// Sweep period in seconds.
    private static let period: Double = 1.4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(CinemaColor.surfaceContainerHigh)
            .overlay {
                if motionEffects {
                    // Clock-driven sweep via TimelineView rather than a
                    // `withAnimation(.repeatForever)` started in `onAppear` —
                    // that pattern silently fails to animate when the block is
                    // part of the screen's initial render (the state change
                    // lands inside an already-committed transaction and the
                    // shimmer freezes). Deriving the phase from the timeline
                    // date can't be dropped, and all blocks sweep in sync.
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        // 0…1 over each period, remapped to -1…1 so the
                        // highlight travels from fully off-screen left to
                        // fully off-screen right, then restarts.
                        let phase = (t.truncatingRemainder(dividingBy: Self.period)) / Self.period * 2 - 1
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
                            .offset(x: phase * geo.size.width * 1.6)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
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
