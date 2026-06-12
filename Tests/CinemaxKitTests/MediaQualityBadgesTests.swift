import Testing
import Foundation
import JellyfinAPI
@testable import Cinemax

// `badgeLabels(for:)` is `@MainActor`-isolated (MediaQualityBadges is a View),
// so the whole suite is pinned to the main actor — calling it off-main traps.
@MainActor
@Suite("MediaQualityBadges.badgeLabels")
struct MediaQualityBadgesTests {

    private func item(streams: [MediaStream], defaultAudioIndex: Int? = nil) -> BaseItemDto {
        var dto = BaseItemDto()
        let source = MediaSourceInfo(
            defaultAudioStreamIndex: defaultAudioIndex,
            mediaStreams: streams
        )
        dto.mediaSources = [source]
        return dto
    }

    @Test("No media source yields no badges")
    func empty() {
        #expect(MediaQualityBadges.badgeLabels(for: BaseItemDto()) == [])
    }

    @Test("4K Dolby Vision HEVC with Atmos 7.1")
    func richStream() {
        let video = MediaStream(
            channelLayout: nil,
            codec: "hevc",
            height: 2160,
            index: 0,
            type: .video,
            videoRangeType: .dovi
        )
        let audio = MediaStream(
            channelLayout: "7.1",
            channels: 8,
            codec: "truehd",
            displayTitle: "TrueHD Atmos 7.1",
            index: 1,
            profile: "Dolby Atmos",
            type: .audio
        )
        let labels = MediaQualityBadges.badgeLabels(for: item(streams: [video, audio]))
        #expect(labels.contains("4K"))
        #expect(labels.contains("Dolby Vision"))
        #expect(labels.contains("HEVC"))
        #expect(labels.contains("Dolby Atmos"))
        #expect(labels.contains("7.1"))
    }

    @Test("Resolution buckets by height")
    func resolutionBuckets() {
        func res(_ h: Int) -> [String] {
            MediaQualityBadges.badgeLabels(for: item(streams: [
                MediaStream(height: h, index: 0, type: .video)
            ]))
        }
        #expect(res(2160).contains("4K"))
        #expect(res(1080).contains("1080p"))
        #expect(res(720).contains("720p"))
        #expect(res(480).contains("SD"))
    }

    @Test("H.264 SDR stream omits HDR badge")
    func sdrNoHDR() {
        let video = MediaStream(codec: "h264", height: 1080, index: 0, type: .video, videoRangeType: .sdr)
        let labels = MediaQualityBadges.badgeLabels(for: item(streams: [video]))
        #expect(labels.contains("H.264"))
        #expect(!labels.contains("HDR"))
        #expect(!labels.contains("Dolby Vision"))
    }

    @Test("Default audio stream index is honored")
    func defaultAudioSelection() {
        let video = MediaStream(height: 1080, index: 0, type: .video)
        let aac = MediaStream(codec: "aac", index: 1, type: .audio)
        let dts = MediaStream(codec: "dts", index: 2, type: .audio)
        // Prefer index 2 (DTS) over the first audio stream (AAC).
        let labels = MediaQualityBadges.badgeLabels(for: item(streams: [video, aac, dts], defaultAudioIndex: 2))
        #expect(labels.contains("DTS"))
        #expect(!labels.contains("AAC"))
    }
}
