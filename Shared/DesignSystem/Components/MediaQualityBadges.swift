import SwiftUI
import CinemaxKit
import JellyfinAPI

/// Horizontal row of small pill badges summarising the technical quality of a
/// media source: resolution, HDR, video codec, audio format, channels.
///
/// Classification lives in `CinemaxKit.MediaSourceQuality`, NOT here — the same
/// type also decides which source plays. Keeping one owner is what stops the
/// badges from advertising a version the player never opens (see the type's own
/// doc comment).
struct MediaQualityBadges: View {
    let item: BaseItemDto
    /// Explicit source to describe. `nil` falls back to the ranked pick, which
    /// is what playback would choose. Pass the user's selection when the detail
    /// screen has one so the badges track the version row.
    var source: MediaSourceInfo?

    init(item: BaseItemDto, source: MediaSourceInfo? = nil) {
        self.item = item
        self.source = source
    }

    var body: some View {
        let labels = Self.badgeLabels(for: item, source: source)
        if labels.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(labels, id: \.self) { label in
                        Text(label)
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.onSurface)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(CinemaColor.surfaceContainerHigh)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Derivation

    /// Labels for `source` when given, else for the source playback would pick.
    static func badgeLabels(for item: BaseItemDto, source: MediaSourceInfo? = nil) -> [String] {
        guard let resolved = source ?? MediaSourceQuality.best(of: item.mediaSources ?? []) else {
            return []
        }
        return MediaSourceQuality.badgeLabels(for: resolved)
    }
}
