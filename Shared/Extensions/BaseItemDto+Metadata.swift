import JellyfinAPI
import CinemaxKit

extension BaseItemDto {
    /// Runtime formatted as "Xh Ym" or "Ym". Nil if no runtime ticks available.
    var formattedRuntime: String? {
        guard let ticks = runTimeTicks else { return nil }
        let minutes = ticks.jellyfinMinutes
        return minutes > 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
