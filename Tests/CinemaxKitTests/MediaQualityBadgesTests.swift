import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
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

    @Test("Badges describe the ranked source, not the server's first one")
    func badgesFollowTheRankedPick() {
        // The 1080p version is listed first; the badge row must still describe
        // the 4K one, because that's what playback will open.
        var dto = BaseItemDto()
        dto.mediaSources = [
            MediaSourceInfo(id: "hd", mediaStreams: [MediaStream(height: 1080, index: 0, type: .video)]),
            MediaSourceInfo(id: "uhd", mediaStreams: [MediaStream(height: 2160, index: 0, type: .video)])
        ]
        #expect(MediaQualityBadges.badgeLabels(for: dto).contains("4K"))
    }

    @Test("An explicit source overrides the ranked pick")
    func explicitSourceWins() {
        var dto = BaseItemDto()
        let hd = MediaSourceInfo(id: "hd", mediaStreams: [MediaStream(height: 1080, index: 0, type: .video)])
        let uhd = MediaSourceInfo(id: "uhd", mediaStreams: [MediaStream(height: 2160, index: 0, type: .video)])
        dto.mediaSources = [hd, uhd]
        // The user picked the 1080p version in the detail screen's version row.
        #expect(MediaQualityBadges.badgeLabels(for: dto, source: hd).contains("1080p"))
    }
}

// MARK: - Ranking

// Un-isolated: `MediaSourceQuality` is deliberately free of actor isolation so
// the view layer and `JellyfinAPIClient` can both call it synchronously.
@Suite("MediaSourceQuality")
struct MediaSourceQualityTests {

    // MARK: Builders

    private func video(
        width: Int? = nil,
        height: Int? = nil,
        codec: String = "hevc",
        range: VideoRangeType? = nil
    ) -> MediaStream {
        MediaStream(codec: codec, height: height, index: 0, type: .video, videoRangeType: range, width: width)
    }

    private func audio(
        codec: String,
        channels: Int? = nil,
        displayTitle: String? = nil,
        profile: String? = nil
    ) -> MediaStream {
        MediaStream(
            channels: channels, codec: codec, displayTitle: displayTitle,
            index: 1, profile: profile, type: .audio
        )
    }

    private func source(
        id: String,
        name: String? = nil,
        path: String? = nil,
        bitrate: Int? = nil,
        size: Int? = nil,
        streams: [MediaStream] = []
    ) -> MediaSourceInfo {
        MediaSourceInfo(bitrate: bitrate, id: id, mediaStreams: streams, name: name, path: path, size: size)
    }

    /// 4K Dolby Vision + TrueHD Atmos 7.1 — the "best" shape used across tests.
    private var uhdAtmos: MediaSourceInfo {
        source(id: "uhd", name: "Remux 4K", bitrate: 54_000_000, streams: [
            video(height: 2160, range: .dovi),
            audio(codec: "truehd", channels: 8, displayTitle: "TrueHD Atmos 7.1", profile: "Dolby Atmos")
        ])
    }

    private var hd1080: MediaSourceInfo {
        source(id: "hd", name: "1080p", bitrate: 9_800_000, streams: [
            video(height: 1080, codec: "h264", range: .sdr),
            audio(codec: "eac3", channels: 6)
        ])
    }

    // MARK: Ordering

    @Test("Resolution outranks every other dimension")
    func resolutionDominates() {
        // 1080p with the best possible audio still loses to a 4K SDR stereo source.
        let richHD = source(id: "hd", streams: [
            video(height: 1080, range: .sdr),
            audio(codec: "truehd", channels: 8, profile: "Dolby Atmos")
        ])
        let poor4K = source(id: "uhd", streams: [
            video(height: 2160, range: .sdr),
            audio(codec: "aac", channels: 2)
        ])
        #expect(MediaSourceQuality.best(of: [richHD, poor4K])?.id == "uhd")
    }

    @Test("HDR breaks ties at equal resolution")
    func hdrBreaksResolutionTies() {
        let sdr = source(id: "sdr", streams: [video(height: 2160, range: .sdr), audio(codec: "truehd", channels: 8)])
        let dv = source(id: "dv", streams: [video(height: 2160, range: .dovi), audio(codec: "aac", channels: 2)])
        #expect(MediaSourceQuality.best(of: [sdr, dv])?.id == "dv")
    }

    @Test("Dolby Vision outranks HDR10+, HDR10, HLG")
    func videoRangeOrder() {
        #expect(MediaSourceQuality.videoRange(of: video(range: .dovi)) > MediaSourceQuality.videoRange(of: video(range: .hdr10Plus)))
        #expect(MediaSourceQuality.videoRange(of: video(range: .hdr10Plus)) > MediaSourceQuality.videoRange(of: video(range: .hdr10)))
        #expect(MediaSourceQuality.videoRange(of: video(range: .hdr10)) > MediaSourceQuality.videoRange(of: video(range: .hlg)))
        #expect(MediaSourceQuality.videoRange(of: video(range: .sdr)) == .sdr)
    }

    @Test("IMAX breaks ties below resolution and HDR, above audio")
    func imaxTier() {
        let plain = source(id: "plain", name: "Remux 4K", streams: [
            video(height: 2160, range: .dovi),
            audio(codec: "truehd", channels: 8, profile: "Dolby Atmos")
        ])
        let imax = source(id: "imax", name: "IMAX Enhanced", streams: [
            video(height: 2160, range: .dovi),
            audio(codec: "aac", channels: 2)
        ])
        // Same resolution + same HDR ⇒ IMAX wins despite far worse audio.
        #expect(MediaSourceQuality.best(of: [plain, imax])?.id == "imax")

        // But IMAX never rescues a lower resolution.
        let imaxHD = source(id: "imaxHD", name: "IMAX Enhanced", streams: [video(height: 1080, range: .dovi)])
        let plain4K = source(id: "plain4K", name: "Remux", streams: [video(height: 2160, range: .dovi)])
        #expect(MediaSourceQuality.best(of: [imaxHD, plain4K])?.id == "plain4K")
    }

    @Test("Audio format then channels break remaining ties")
    func audioTiers() {
        let atmos = source(id: "atmos", streams: [video(height: 2160), audio(codec: "truehd", channels: 8, profile: "Dolby Atmos")])
        let trueHD = source(id: "truehd", streams: [video(height: 2160), audio(codec: "truehd", channels: 8)])
        #expect(MediaSourceQuality.best(of: [trueHD, atmos])?.id == "atmos")

        // Equal format ⇒ more channels wins.
        let stereo = source(id: "stereo", streams: [video(height: 2160), audio(codec: "eac3", channels: 2)])
        let surround = source(id: "surround", streams: [video(height: 2160), audio(codec: "eac3", channels: 6)])
        #expect(MediaSourceQuality.best(of: [stereo, surround])?.id == "surround")
    }

    @Test("DTS-HD outranks plain DTS via the profile")
    func dtsVariants() {
        #expect(MediaSourceQuality.audioTier(of: audio(codec: "dts", profile: "DTS-HD MA")) == .dtsHD)
        #expect(MediaSourceQuality.audioTier(of: audio(codec: "dts")) == .dts)
        #expect(MediaSourceQuality.audioTier(of: audio(codec: "dts", profile: "DTS-HD MA"))
                > MediaSourceQuality.audioTier(of: audio(codec: "dts")))
    }

    @Test("Bitrate is the last quality tiebreak")
    func bitrateTiebreak() {
        let low = source(id: "low", bitrate: 10_000_000, streams: [video(height: 2160), audio(codec: "eac3", channels: 6)])
        let high = source(id: "high", bitrate: 40_000_000, streams: [video(height: 2160), audio(codec: "eac3", channels: 6)])
        #expect(MediaSourceQuality.best(of: [low, high])?.id == "high")
    }

    // MARK: Bitrate cap

    @Test("A source over the cap is demoted below one within it")
    func bitrateCapGates() {
        // The 4K remux is better on every quality dimension but blows the cap.
        let over = source(id: "over", bitrate: 68_000_000, streams: [
            video(height: 2160, range: .dovi),
            audio(codec: "truehd", channels: 8, profile: "Dolby Atmos")
        ])
        let under = source(id: "under", bitrate: 9_800_000, streams: [
            video(height: 1080, range: .sdr),
            audio(codec: "aac", channels: 2)
        ])
        #expect(MediaSourceQuality.best(of: [over, under], maxBitrate: 20_000_000)?.id == "under")
        // Without a cap the quality ranking stands.
        #expect(MediaSourceQuality.best(of: [over, under])?.id == "over")
    }

    @Test("Every source over the cap still resolves to the best of them")
    func bitrateCapNeverStarves() {
        let a = source(id: "a", bitrate: 60_000_000, streams: [video(height: 1080)])
        let b = source(id: "b", bitrate: 80_000_000, streams: [video(height: 2160)])
        // Gating, not filtering — a library where nothing fits must still play.
        #expect(MediaSourceQuality.best(of: [a, b], maxBitrate: 20_000_000)?.id == "b")
    }

    @Test("A source that reports no bitrate is not demoted")
    func unknownBitrateIsNotPenalised() {
        let unknown = source(id: "unknown", streams: [video(height: 2160, range: .dovi)])
        let known = source(id: "known", bitrate: 5_000_000, streams: [video(height: 1080, range: .sdr)])
        #expect(MediaSourceQuality.best(of: [unknown, known], maxBitrate: 20_000_000)?.id == "unknown")
    }

    // MARK: Total order

    @Test("Ties resolve deterministically by source id")
    func totalOrderIsStable() {
        // Identical on every quality dimension — only the id can separate them.
        let streams = [video(height: 2160, range: .dovi), audio(codec: "eac3", channels: 6)]
        let b = source(id: "bbb", bitrate: 10_000_000, streams: streams)
        let a = source(id: "aaa", bitrate: 10_000_000, streams: streams)

        // Same answer regardless of the order the server listed them in — this
        // is what keeps the badge row and the playback call agreeing.
        #expect(MediaSourceQuality.best(of: [b, a])?.id == "aaa")
        #expect(MediaSourceQuality.best(of: [a, b])?.id == "aaa")
        #expect(MediaSourceQuality.ranked([b, a]).map(\.id) == ["aaa", "bbb"])
    }

    @Test("ranked returns every source exactly once")
    func rankedIsAPermutation() {
        let sources = [uhdAtmos, hd1080, source(id: "third", streams: [video(height: 720)])]
        let ranked = MediaSourceQuality.ranked(sources)
        #expect(ranked.count == 3)
        #expect(Set(ranked.compactMap(\.id)) == Set(["uhd", "hd", "third"]))
    }

    @Test("Empty input resolves to nil")
    func emptyInput() {
        #expect(MediaSourceQuality.best(of: []) == nil)
        #expect(MediaSourceQuality.ranked([]).isEmpty)
        #expect(MediaSourceQuality.resolve([], preferredID: "anything") == nil)
    }

    // MARK: resolve

    @Test("An explicit preferred id wins over the ranked pick")
    func resolveHonorsOverride() {
        let sources = [uhdAtmos, hd1080]
        #expect(MediaSourceQuality.resolve(sources, preferredID: nil)?.id == "uhd")
        #expect(MediaSourceQuality.resolve(sources, preferredID: "hd")?.id == "hd")
    }

    @Test("A stale preferred id falls back to the ranked pick")
    func resolveFallsBackWhenOverrideVanishes() {
        // Server re-scanned and the chosen version no longer exists — playback
        // must continue with the default rather than fail.
        #expect(MediaSourceQuality.resolve([uhdAtmos, hd1080], preferredID: "deleted")?.id == "uhd")
    }

    // MARK: IMAX heuristic

    @Test("IMAX detection reads the version name and the path")
    func imaxDetection() {
        #expect(MediaSourceQuality.isIMAX(source(id: "1", name: "IMAX Enhanced")))
        #expect(MediaSourceQuality.isIMAX(source(id: "2", name: "Dune (2024) imax")))
        #expect(MediaSourceQuality.isIMAX(source(id: "3", path: "/media/Dune.2024.IMAX.2160p.mkv")))
        #expect(MediaSourceQuality.isIMAX(source(id: "4", name: "Open Matte")))
        #expect(MediaSourceQuality.isIMAX(source(id: "5", name: "openmatte")))
        #expect(!MediaSourceQuality.isIMAX(source(id: "6", name: "Remux 4K")))
        #expect(!MediaSourceQuality.isIMAX(source(id: "7")))
    }

    // MARK: Description

    @Test("Badge labels describe the given source")
    func badgeLabels() {
        let labels = MediaSourceQuality.badgeLabels(for: uhdAtmos)
        #expect(labels.contains("4K"))
        #expect(labels.contains("Dolby Vision"))
        #expect(labels.contains("HEVC"))
        #expect(labels.contains("Dolby Atmos"))
        #expect(labels.contains("7.1"))
    }

    @Test("Resolution classifies on width for scope aspect ratios")
    func scopeResolution() {
        // A 2.39:1 4K movie is 3840x1600 — height alone would call it 1080p.
        #expect(MediaSourceQuality.resolution(of: video(width: 3840, height: 1600)) == .uhd4K)
        #expect(MediaSourceQuality.resolution(of: video(width: 1920, height: 800)) == .hd1080)
        #expect(MediaSourceQuality.resolution(of: video()) == .unknown)
    }

    @Test("Summary is a condensed resolution / HDR / audio line")
    func summary() {
        #expect(MediaSourceQuality.summary(for: uhdAtmos) == "4K · Dolby Vision · Dolby Atmos")
        #expect(MediaSourceQuality.summary(for: hd1080) == "1080p · Dolby Digital+")
        #expect(MediaSourceQuality.summary(for: source(id: "bare")).isEmpty)
    }

    @Test("Version name is trimmed and blank names read as absent")
    func versionName() {
        #expect(MediaSourceQuality.versionName(for: source(id: "1", name: "  IMAX  ")) == "IMAX")
        #expect(MediaSourceQuality.versionName(for: source(id: "2", name: "   ")) == nil)
        #expect(MediaSourceQuality.versionName(for: source(id: "3")) == nil)
    }

    @Test("Bitrate label switches precision at 10 Mbps")
    func bitrateLabel() {
        #expect(MediaSourceQuality.bitrateLabel(for: source(id: "1", bitrate: 68_000_000)) == "68 Mbps")
        #expect(MediaSourceQuality.bitrateLabel(for: source(id: "2", bitrate: 9_800_000)) == "9.8 Mbps")
        #expect(MediaSourceQuality.bitrateLabel(for: source(id: "3")) == nil)
        #expect(MediaSourceQuality.bitrateLabel(for: source(id: "4", bitrate: 0)) == nil)
    }

    @Test("Default audio stream index is honored when present")
    func defaultAudioStream() {
        let aac = audio(codec: "aac")
        var dts = audio(codec: "dts")
        dts.index = 2
        var src = MediaSourceInfo(mediaStreams: [video(height: 1080), aac, dts])
        src.defaultAudioStreamIndex = 2
        #expect(MediaSourceQuality.defaultAudioStream(in: src)?.codec == "dts")

        // Without a declared default, the first audio track stands in.
        let noDefault = MediaSourceInfo(mediaStreams: [video(height: 1080), aac, dts])
        #expect(MediaSourceQuality.defaultAudioStream(in: noDefault)?.codec == "aac")
    }
}
