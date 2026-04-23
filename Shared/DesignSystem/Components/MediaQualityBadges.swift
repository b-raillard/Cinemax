import SwiftUI
import CinemaxKit
import JellyfinAPI

/// Horizontal row of small pill badges summarising the technical quality of the
/// primary media source: resolution, HDR, video codec, audio format, channels.
struct MediaQualityBadges: View {
    let item: BaseItemDto

    var body: some View {
        let labels = Self.badgeLabels(for: item)
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

    static func badgeLabels(for item: BaseItemDto) -> [String] {
        guard let source = item.mediaSources?.first else { return [] }
        let streams = source.mediaStreams ?? []
        let videoStream = streams.first { $0.type == .video }

        let defaultAudioIndex = source.defaultAudioStreamIndex
        let audioStream: MediaStream? = {
            if let idx = defaultAudioIndex,
               let match = streams.first(where: { $0.type == .audio && $0.index == idx }) {
                return match
            }
            return streams.first { $0.type == .audio }
        }()

        var labels: [String] = []

        if let v = videoStream, let res = resolutionLabel(for: v) {
            labels.append(res)
        }
        if let v = videoStream, let hdr = hdrLabel(for: v) {
            labels.append(hdr)
        }
        if let v = videoStream, let codec = videoCodecLabel(for: v) {
            labels.append(codec)
        }
        if let a = audioStream, let audio = audioFormatLabel(for: a) {
            labels.append(audio)
        }
        if let a = audioStream, let ch = channelsLabel(for: a) {
            labels.append(ch)
        }

        return labels
    }

    // MARK: - Resolution

    private static func resolutionLabel(for stream: MediaStream) -> String? {
        guard let h = stream.height else { return nil }
        switch h {
        case let x where x >= 2160: return "4K"
        case let x where x >= 1080: return "1080p"
        case let x where x >= 720:  return "720p"
        default:                    return "SD"
        }
    }

    // MARK: - HDR

    private static func hdrLabel(for stream: MediaStream) -> String? {
        if let t = stream.videoRangeType {
            switch t {
            case .dovi, .doviWithHDR10, .doviWithHLG, .doviWithSDR,
                 .doviWithEL, .doviWithHDR10Plus, .doviWithELHDR10Plus, .doviInvalid:
                return "Dolby Vision"
            case .hdr10Plus:
                return "HDR10+"
            case .hdr10:
                return "HDR10"
            case .hlg:
                return "HDR"
            case .sdr, .unknown:
                break
            }
        }
        if stream.videoRange == .hdr {
            return "HDR"
        }
        return nil
    }

    // MARK: - Video codec

    private static func videoCodecLabel(for stream: MediaStream) -> String? {
        guard let codec = stream.codec?.lowercased(), !codec.isEmpty else { return nil }
        switch codec {
        case "hevc", "h265": return "HEVC"
        case "h264":         return "H.264"
        case "av1":          return "AV1"
        case "vp9":          return "VP9"
        default:             return codec.uppercased()
        }
    }

    // MARK: - Audio format

    private static func audioFormatLabel(for stream: MediaStream) -> String? {
        let profile = stream.profile?.lowercased() ?? ""
        let displayTitle = stream.displayTitle?.lowercased() ?? ""
        if profile.contains("atmos") || displayTitle.contains("atmos") {
            return "Dolby Atmos"
        }
        guard let codec = stream.codec?.lowercased(), !codec.isEmpty else { return nil }
        switch codec {
        case "truehd": return "TrueHD"
        case "eac3":   return "Dolby Digital+"
        case "ac3":    return "Dolby Digital"
        case "aac":    return "AAC"
        case "flac":   return "FLAC"
        case "opus":   return "Opus"
        case "mp3":    return "MP3"
        default:
            if codec == "dts" || codec.contains("dts") {
                return "DTS"
            }
            return codec.uppercased()
        }
    }

    // MARK: - Channels

    private static func channelsLabel(for stream: MediaStream) -> String? {
        if let layout = stream.channelLayout, !layout.isEmpty {
            let lower = layout.lowercased()
            switch lower {
            case "stereo": return "Stereo"
            case "mono":   return "Mono"
            default:       return layout.uppercased()
            }
        }
        if let ch = stream.channels {
            switch ch {
            case 8: return "7.1"
            case 6: return "5.1"
            case 2: return "Stereo"
            case 1: return "Mono"
            default: return "\(ch)ch"
            }
        }
        return nil
    }
}
