#if os(tvOS)
import SwiftUI

// MARK: - Player State

@MainActor @Observable
final class TVPlayerState {
    var currentTime: Double = 0
    var duration: Double = 0
    var isPlaying: Bool = false
    var isBuffering: Bool = true
    var showControls: Bool = true
    var currentAudioIdx: Int?
    var currentSubtitleIdx: Int?
    var title: String = ""
    var previousEpisode: EpisodeRef?
    var nextEpisode: EpisodeRef?

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, currentTime / duration)
    }

    var formattedCurrentTime: String { Self.format(currentTime) }

    var formattedRemaining: String {
        guard duration > 0 else { return "" }
        return "-" + Self.format(max(0, duration - currentTime))
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }
}
#endif
