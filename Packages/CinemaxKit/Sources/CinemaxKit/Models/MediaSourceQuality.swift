import Foundation
import JellyfinAPI

/// Single source of truth for "how good is this media source, and how do we
/// describe it".
///
/// A Jellyfin item can carry several `MediaSourceInfo` versions of the same
/// title (a 4K remux next to a 1080p encode, an IMAX cut next to the theatrical
/// one). Before this type existed, both the badge row and the playback call
/// independently reached for `mediaSources.first` — accidentally consistent,
/// but only because neither made a choice. The moment one of them started
/// ranking, they would have disagreed and the detail screen would advertise a
/// version the player never opened.
///
/// So ranking and description live together here, and BOTH callers go through
/// this type: `MediaQualityBadges` for the labels, `getPlaybackInfo` for the
/// pick. Keep it that way.
///
/// Deliberately un-isolated: every entry point is a pure synchronous function
/// over its arguments, so it's callable from the `@MainActor` view layer and
/// from `JellyfinAPIClient`'s nonisolated context alike without crossing an
/// isolation boundary.
public enum MediaSourceQuality {

    // MARK: - Tiers

    /// Classified on width OR height, matching Jellyfin's web client. Height
    /// alone is wrong for anything wider than 16:9 — Jellyfin stores the
    /// encoded frame with letterbox bars cropped, so a 2.39:1 4K movie is
    /// 3840×1600. Thresholds sit at ~95% of nominal to absorb cropped encodes.
    public enum Resolution: Int, Comparable, Sendable {
        case unknown = 0, sd = 1, hd720 = 2, hd1080 = 3, uhd4K = 4

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Dolby Vision outranks HDR10+ here because DV is the format this app went
    /// to libVLC for in the first place — it survives DirectPlay untouched,
    /// where the AVPlayer path can't carry it in MKV at all.
    public enum VideoRangeTier: Int, Comparable, Sendable {
        case sdr = 0, hlg = 1, hdr10 = 2, hdr10Plus = 3, dolbyVision = 4

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Object-based formats first, then lossless, then lossy by fidelity.
    public enum AudioTier: Int, Comparable, Sendable {
        case unknown = 0
        case mp3 = 1
        case lossyBasic = 2      // AAC, Opus, Vorbis
        case dolbyDigital = 3    // AC-3
        case lossless = 4        // FLAC, ALAC, PCM
        case dolbyDigitalPlus = 5
        case dts = 6
        case dtsHD = 7
        case trueHD = 8
        case atmos = 9

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    // MARK: - Score

    /// Comparable quality summary. Greater is better.
    ///
    /// Ordering is lexicographic across the dimensions, in the order the
    /// product decision fixed: picture attributes before sound attributes, with
    /// the bandwidth gate ahead of everything (see `withinBitrateCap`).
    public struct Score: Comparable, Equatable, Sendable {
        /// Whether the source fits under the caller's ceiling (`render4K`'s
        /// 120/20 Mbps). This sorts FIRST — deliberately. Handing someone an
        /// 80 GB remux when they've capped bitrate forces exactly the
        /// server-side transcode the VLC engine was adopted to avoid. It gates
        /// rather than filters so a library where every source is over the cap
        /// still resolves to something playable instead of nothing.
        public let withinBitrateCap: Bool
        public let resolution: Resolution
        public let videoRange: VideoRangeTier
        /// Heuristic — see `isIMAX(_:)`. Ranked below measured attributes.
        public let isIMAX: Bool
        public let audio: AudioTier
        public let channels: Int
        public let bitrate: Int

        public static func < (lhs: Score, rhs: Score) -> Bool {
            // Written as an explicit chain rather than tuple comparison: Swift
            // only defines `<` for tuples up to 6 elements and there are 7
            // dimensions here.
            if lhs.withinBitrateCap != rhs.withinBitrateCap { return rhs.withinBitrateCap }
            if lhs.resolution != rhs.resolution { return lhs.resolution < rhs.resolution }
            if lhs.videoRange != rhs.videoRange { return lhs.videoRange < rhs.videoRange }
            if lhs.isIMAX != rhs.isIMAX { return rhs.isIMAX }
            if lhs.audio != rhs.audio { return lhs.audio < rhs.audio }
            if lhs.channels != rhs.channels { return lhs.channels < rhs.channels }
            return lhs.bitrate < rhs.bitrate
        }
    }

    /// Scores one source. `maxBitrate` is the caller's ceiling in bits/sec
    /// (pass `nil` to score without a bandwidth gate). A source that doesn't
    /// report its bitrate is treated as within the cap — unknown is not a
    /// reason to demote.
    public static func score(for source: MediaSourceInfo, maxBitrate: Int? = nil) -> Score {
        let streams = source.mediaStreams ?? []
        let video = streams.first { $0.type == .video }
        let audio = defaultAudioStream(in: source)
        let bitrate = source.bitrate ?? 0

        let withinCap: Bool = {
            guard let maxBitrate, maxBitrate > 0, bitrate > 0 else { return true }
            return bitrate <= maxBitrate
        }()

        return Score(
            withinBitrateCap: withinCap,
            resolution: video.map(resolution(of:)) ?? .unknown,
            videoRange: video.map(videoRange(of:)) ?? .sdr,
            isIMAX: isIMAX(source),
            audio: audio.map(audioTier(of:)) ?? .unknown,
            channels: audio?.channels ?? 0,
            bitrate: bitrate
        )
    }

    // MARK: - Ranking

    /// Every source, best first. The order is **total and deterministic**:
    /// after the quality dimensions it falls through to source id, then to the
    /// server's original order. That matters because the badge row and the
    /// playback call rank independently — if ties resolved arbitrarily the two
    /// could disagree about which version won, which is precisely the bug this
    /// type exists to prevent.
    public static func ranked(_ sources: [MediaSourceInfo], maxBitrate: Int? = nil) -> [MediaSourceInfo] {
        sources
            .enumerated()
            .map { (offset: $0.offset, source: $0.element, score: score(for: $0.element, maxBitrate: maxBitrate)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let lid = lhs.source.id ?? "", rid = rhs.source.id ?? ""
                if lid != rid { return lid < rid }
                return lhs.offset < rhs.offset
            }
            .map(\.source)
    }

    /// The source that should play by default.
    public static func best(of sources: [MediaSourceInfo], maxBitrate: Int? = nil) -> MediaSourceInfo? {
        ranked(sources, maxBitrate: maxBitrate).first
    }

    /// Resolves the source a caller should use: an explicit `id` when the user
    /// has overridden the default and it still exists, otherwise the ranked
    /// pick. A stale override (server re-scanned, version deleted) silently
    /// falls back rather than failing playback.
    public static func resolve(
        _ sources: [MediaSourceInfo],
        preferredID: String?,
        maxBitrate: Int? = nil
    ) -> MediaSourceInfo? {
        if let preferredID, let match = sources.first(where: { $0.id == preferredID }) {
            return match
        }
        return best(of: sources, maxBitrate: maxBitrate)
    }

    // MARK: - Classification

    public static func resolution(of stream: MediaStream) -> Resolution {
        let w = stream.width ?? 0, h = stream.height ?? 0
        guard w > 0 || h > 0 else { return .unknown }
        if w >= 3800 || h >= 2100 { return .uhd4K }
        if w >= 1800 || h >= 1000 { return .hd1080 }
        if w >= 1200 || h >= 700 { return .hd720 }
        return .sd
    }

    public static func videoRange(of stream: MediaStream) -> VideoRangeTier {
        if let t = stream.videoRangeType {
            switch t {
            case .dovi, .doviWithHDR10, .doviWithHLG, .doviWithSDR,
                 .doviWithEL, .doviWithHDR10Plus, .doviWithELHDR10Plus, .doviInvalid:
                return .dolbyVision
            case .hdr10Plus: return .hdr10Plus
            case .hdr10:     return .hdr10
            case .hlg:       return .hlg
            case .sdr, .unknown: break
            }
        }
        return stream.videoRange == .hdr ? .hdr10 : .sdr
    }

    public static func audioTier(of stream: MediaStream) -> AudioTier {
        let profile = stream.profile?.lowercased() ?? ""
        let title = stream.displayTitle?.lowercased() ?? ""
        if profile.contains("atmos") || title.contains("atmos") { return .atmos }

        guard let codec = stream.codec?.lowercased(), !codec.isEmpty else { return .unknown }
        switch codec {
        case "truehd": return .trueHD
        case "eac3":   return .dolbyDigitalPlus
        case "ac3":    return .dolbyDigital
        case "flac", "alac", "pcm", "pcm_s16le", "pcm_s24le": return .lossless
        case "aac", "opus", "vorbis": return .lossyBasic
        case "mp3":    return .mp3
        default:
            guard codec.contains("dts") else { return .unknown }
            // DTS-HD MA / DTS-X arrive as codec "dts" with the variant in the
            // profile, so the codec alone can't separate them.
            let hd = profile.contains("ma") || profile.contains("hd")
                || profile.contains("x") || title.contains("dts-hd") || title.contains("dts:x")
            return hd ? .dtsHD : .dts
        }
    }

    /// IMAX / open-matte detection — **a heuristic, not a measurement**.
    /// Jellyfin exposes no structured flag for it, so this matches the source's
    /// version name and file path.
    ///
    /// Safe in practice because it only ever breaks ties *between sources of
    /// the same item*: a title that genuinely contains "IMAX" puts the token in
    /// every one of its sources, so the signal cancels out rather than skewing
    /// the pick. Ranked below every measured attribute for the same reason.
    public static func isIMAX(_ source: MediaSourceInfo) -> Bool {
        let haystack = [source.name, source.path]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        guard !haystack.isEmpty else { return false }
        return haystack.contains("imax")
            || haystack.contains("open matte")
            || haystack.contains("open-matte")
            || haystack.contains("openmatte")
    }

    /// The audio stream a player would actually use: the server's negotiated
    /// default when it names one, else the first audio track.
    public static func defaultAudioStream(in source: MediaSourceInfo) -> MediaStream? {
        let streams = source.mediaStreams ?? []
        if let idx = source.defaultAudioStreamIndex,
           let match = streams.first(where: { $0.type == .audio && $0.index == idx }) {
            return match
        }
        return streams.first { $0.type == .audio }
    }

    // MARK: - Display

    /// Badge strings for one source: resolution, HDR, codec, audio format,
    /// channels. Empty when the source carries no usable streams.
    public static func badgeLabels(for source: MediaSourceInfo) -> [String] {
        let streams = source.mediaStreams ?? []
        let video = streams.first { $0.type == .video }
        let audio = defaultAudioStream(in: source)

        var labels: [String] = []
        if let v = video, let r = resolutionLabel(of: v) { labels.append(r) }
        if let v = video, let h = hdrLabel(of: v) { labels.append(h) }
        if let v = video, let c = videoCodecLabel(of: v) { labels.append(c) }
        if let a = audio, let f = audioFormatLabel(of: a) { labels.append(f) }
        if let a = audio, let c = channelsLabel(of: a) { labels.append(c) }
        return labels
    }

    /// Condensed one-line spec for the version row and the picker menu —
    /// resolution, HDR, audio format. Drops the codec and channel count that
    /// the full badge row carries, because at row width they push the useful
    /// distinctions off the end.
    public static func summary(for source: MediaSourceInfo) -> String {
        let streams = source.mediaStreams ?? []
        let video = streams.first { $0.type == .video }
        let audio = defaultAudioStream(in: source)

        var parts: [String] = []
        if let v = video, let r = resolutionLabel(of: v) { parts.append(r) }
        if let v = video, let h = hdrLabel(of: v) { parts.append(h) }
        if let a = audio, let f = audioFormatLabel(of: a) { parts.append(f) }
        return parts.joined(separator: " · ")
    }

    /// The server-provided version name, trimmed. Nil when absent or blank so
    /// the UI can substitute a localized fallback (CinemaxKit has no access to
    /// `LocalizationManager`).
    public static func versionName(for source: MediaSourceInfo) -> String? {
        guard let name = source.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    /// Localized file size, e.g. "82 Go" / "82 GB". Nil when the server doesn't
    /// report one.
    public static func sizeLabel(for source: MediaSourceInfo) -> String? {
        guard let size = source.size, size > 0 else { return nil }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(size))
    }

    /// Overall bitrate in Mbps, e.g. "68 Mbps" / "9.8 Mbps". Nil when unknown.
    public static func bitrateLabel(for source: MediaSourceInfo) -> String? {
        guard let bitrate = source.bitrate, bitrate > 0 else { return nil }
        let mbps = Double(bitrate) / 1_000_000
        let rendered = mbps >= 10
            ? String(format: "%.0f", mbps)
            : String(format: "%.1f", mbps)
        return "\(rendered) Mbps"
    }

    // MARK: - Label helpers

    private static func resolutionLabel(of stream: MediaStream) -> String? {
        switch resolution(of: stream) {
        case .unknown: return nil
        case .sd:      return "SD"
        case .hd720:   return "720p"
        case .hd1080:  return "1080p"
        case .uhd4K:   return "4K"
        }
    }

    private static func hdrLabel(of stream: MediaStream) -> String? {
        switch videoRange(of: stream) {
        case .sdr:          return nil
        case .hlg:          return "HDR"
        case .hdr10:        return "HDR10"
        case .hdr10Plus:    return "HDR10+"
        case .dolbyVision:  return "Dolby Vision"
        }
    }

    private static func videoCodecLabel(of stream: MediaStream) -> String? {
        guard let codec = stream.codec?.lowercased(), !codec.isEmpty else { return nil }
        switch codec {
        case "hevc", "h265": return "HEVC"
        case "h264":         return "H.264"
        case "av1":          return "AV1"
        case "vp9":          return "VP9"
        default:             return codec.uppercased()
        }
    }

    private static func audioFormatLabel(of stream: MediaStream) -> String? {
        switch audioTier(of: stream) {
        case .atmos:            return "Dolby Atmos"
        case .trueHD:           return "TrueHD"
        case .dtsHD:            return "DTS-HD"
        case .dts:              return "DTS"
        case .dolbyDigitalPlus: return "Dolby Digital+"
        case .dolbyDigital:     return "Dolby Digital"
        case .lossless, .lossyBasic, .mp3:
            // These map several codecs onto one tier, so fall back to the codec
            // name rather than inventing a label the tier can't distinguish.
            guard let codec = stream.codec?.lowercased(), !codec.isEmpty else { return nil }
            switch codec {
            case "aac":  return "AAC"
            case "flac": return "FLAC"
            case "alac": return "ALAC"
            case "opus": return "Opus"
            case "mp3":  return "MP3"
            default:     return codec.uppercased()
            }
        case .unknown:
            guard let codec = stream.codec?.lowercased(), !codec.isEmpty else { return nil }
            return codec.uppercased()
        }
    }

    private static func channelsLabel(of stream: MediaStream) -> String? {
        if let layout = stream.channelLayout, !layout.isEmpty {
            switch layout.lowercased() {
            case "stereo": return "Stereo"
            case "mono":   return "Mono"
            default:       return layout.uppercased()
            }
        }
        guard let ch = stream.channels else { return nil }
        switch ch {
        case 8: return "7.1"
        case 6: return "5.1"
        case 2: return "Stereo"
        case 1: return "Mono"
        default: return "\(ch)ch"
        }
    }
}
