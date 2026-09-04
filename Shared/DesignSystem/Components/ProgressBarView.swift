import SwiftUI

/// Accent-filled capsule progress bar.
/// Fills its container width via `GeometryReader`; height is configurable.
struct ProgressBarView: View {
    /// Progress value in the range 0.0–1.0.
    let progress: Double
    var height: CGFloat = 4
    var trackColor: Color = CinemaColor.surfaceContainerHighest

    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                    .frame(height: height)
                Capsule()
                    .fill(themeManager.accent)
                    .frame(width: geo.size.width * max(0, min(1, progress)), height: height)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Media Card Status

/// What a poster card says about the user's own history with the item.
///
/// A card either shows nothing, a watched check, or a progress bar — never two
/// at once, because a residual position on an item already marked played is not
/// a resume (the rule `CardPlayTargetResolver.isResumable` owns).
///
/// Library and search posters carried neither, while the very same title's
/// Continue Watching card and its episode row both did: the user could see a
/// film's progress on Home and lose it the moment they opened the library.
enum MediaCardStatus: Equatable {
    case none
    case watched
    case inProgress(Double)

    /// Derives the status from an item's own `userData`.
    ///
    /// - `positionTicks` / `runtimeTicks` are the item's own, so a series folder
    ///   resolves to `.watched` or `.none` — a series carries no position of its
    ///   own, and its next-up episode's progress belongs on that episode's card.
    /// - A progress that has not passed 1 % is reported as `.none`: a sliver of
    ///   bar reads as a rendering artefact rather than as "you started this".
    static func make(positionTicks: Int?, runtimeTicks: Int?, isPlayed: Bool?) -> MediaCardStatus {
        let played = isPlayed ?? false
        let position = positionTicks ?? 0
        guard CardPlayTargetResolver.isResumable(positionTicks: position, isPlayed: played) else {
            return played ? .watched : .none
        }
        guard let runtime = runtimeTicks, runtime > 0 else { return .none }
        let fraction = Double(position) / Double(runtime)
        guard fraction >= 0.01 else { return .none }
        return .inProgress(min(fraction, 1))
    }
}

extension View {
    /// Paints a card's watched check or progress bar over its artwork.
    ///
    /// Applied to the CLIPPED artwork box, before `.contentShape`/`.cinemaFocus`,
    /// so the bar follows the poster's rounded corners and the check sits inside
    /// them.
    func mediaCardStatusOverlay(_ status: MediaCardStatus) -> some View {
        self
            .overlay(alignment: .bottom) {
                if case .inProgress(let fraction) = status {
                    ProgressBarView(progress: fraction)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if status == .watched {
                    // Same badge the episode row and the iOS episode card draw:
                    // white over the artwork, on a dimmed disc so it survives a
                    // pale poster.
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                        .foregroundStyle(.white, CinemaColor.surface.opacity(0.8))
                        .padding(6)
                }
            }
    }
}
