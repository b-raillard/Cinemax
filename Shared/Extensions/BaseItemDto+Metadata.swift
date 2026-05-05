import JellyfinAPI
import CinemaxKit

extension BaseItemDto {
    /// Runtime formatted as "Xh Ym" or "Ym". Nil if no runtime ticks available.
    var formattedRuntime: String? {
        guard let ticks = runTimeTicks else { return nil }
        let minutes = ticks.jellyfinMinutes
        return minutes > 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// Resolve which item ID to use for backdrop image lookup. Episodes fall back
    /// to their parent's backdrop, then the series; everything else uses its own ID.
    var backdropItemID: String? {
        parentBackdropItemID ?? seriesID ?? id
    }

    /// True only when Jellyfin reports an actual backdrop tag (own or parent's).
    /// Use this to decide between rendering a `CinemaLazyImage` backdrop vs the
    /// `BackdropFallbackView`. `backdropItemID` always returns non-nil for items
    /// with an `id`, so it can't be used as an availability check.
    var hasBackdropImage: Bool {
        if let tags = backdropImageTags, !tags.isEmpty { return true }
        if let parentTags = parentBackdropImageTags, !parentTags.isEmpty { return true }
        return false
    }
}
