import SwiftUI
import CinemaxKit
import JellyfinAPI

// MARK: - Shared Episode Metadata Line

/// Small secondary-text line under an episode title combining "X min remaining"
/// (or runtime) with the air date. Renders nothing when no field is available.
/// Shared by the iOS episode card and the tvOS episode row so both surfaces
/// have identical secondary metadata copy.
struct MediaDetailEpisodeMetadataLine: View {
    let episode: BaseItemDto
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        let isPlayed = episode.userData?.isPlayed ?? false
        let runtimeText: String? = {
            // Prefer "X remaining" while in-progress, otherwise show total runtime.
            if !isPlayed,
               let position = episode.userData?.playbackPositionTicks,
               let total = episode.runTimeTicks,
               position > 0, total > position {
                let remainingMinutes = (total - position).jellyfinMinutes
                if remainingMinutes <= 0 { return nil }
                return loc.remainingTime(minutes: remainingMinutes)
            }
            if let runtime = episode.runTimeTicks, runtime > 0 {
                return loc.localized("detail.runtime.min", runtime.jellyfinMinutes)
            }
            return nil
        }()

        let dateText: String? = episode.premiereDate.map {
            $0.formatted(.dateTime.month(.abbreviated).day().year())
        }

        let parts: [String] = [runtimeText, dateText].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " • "))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
    }
}
