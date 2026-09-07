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

    /// Cache-busting tag for the primary (poster) image. The poster URL is
    /// otherwise identical across metadata/poster edits, so Nuke serves a stale
    /// image forever (until reinstall). Pass this as `ImageURLBuilder`'s `tag:`.
    var primaryImageTagValue: String? { imageTags?["Primary"] }

    /// Cache-busting tag for the backdrop, mirroring `backdropItemID`'s
    /// parent-first resolution (parent backdrop wins, then the item's own).
    var backdropImageTagValue: String? {
        if parentBackdropItemID != nil { return parentBackdropImageTags?.first }
        return backdropImageTags?.first
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

    /// Cache-busting tag for the title logo — the artwork most providers ship
    /// with the title already set in the work's own typeface.
    var logoImageTagValue: String? { imageTags?["Logo"] }

    /// True only when the server actually holds a logo. Most libraries do not,
    /// so every logo call site needs a text fallback rather than a placeholder.
    var hasLogoImage: Bool { logoImageTagValue?.isEmpty == false }

    /// "S01:E02 - Deux hommes morts" — the line the « À suivre » and
    /// « Reprendre » rails print under a series title. `nil` for anything that
    /// is not an episode, and for an episode carrying neither numbers nor a
    /// name. Single-sourced so the « En direct » row can say the same thing
    /// about what someone is watching as the rails say about what you are.
    var episodeLabel: String? {
        guard type == .episode else { return nil }
        var label = ""
        if let season = parentIndexNumber, let ep = indexNumber {
            label = String(format: "S%02d:E%02d", season, ep)
        }
        if let name, !name.isEmpty {
            label = label.isEmpty ? name : "\(label) - \(name)"
        }
        return label.isEmpty ? nil : label
    }
}
