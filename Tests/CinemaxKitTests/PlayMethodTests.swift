import Testing
import Foundation
import CinemaxKit
@testable import Cinemax

@Suite("PlayMethod")
struct PlayMethodTests {

    @Test("rawValue matches Jellyfin string literals")
    func rawValues() {
        #expect(PlayMethod.directPlay.rawValue == "DirectPlay")
        #expect(PlayMethod.directStream.rawValue == "DirectStream")
        #expect(PlayMethod.transcode.rawValue == "Transcode")
    }

    @Test("description equals rawValue")
    func description() {
        #expect(PlayMethod.transcode.description == "Transcode")
    }

    @Test("PlaybackInfo stores playMethod correctly")
    func playbackInfoPlayMethod() {
        let info = PlaybackInfo(
            url: URL(string: "http://localhost/stream")!,
            playSessionId: nil,
            mediaSourceId: "item1",
            playMethod: .directStream,
            audioTracks: [],
            subtitleTracks: [],
            selectedAudioIndex: nil,
            selectedSubtitleIndex: nil,
            authToken: nil
        )
        #expect(info.playMethod == .directStream)
        #expect(info.playMethod.rawValue == "DirectStream")
    }
}

@Suite("Late subtitles (a transcode's text subtitles, after the picture)")
struct LateSubtitlesTests {
    private func track(_ id: Int, url: String?, external: Bool = false) -> MediaTrackInfo {
        MediaTrackInfo(id: id, label: "t\(id)", isDefault: false, isForced: false, codec: "subrip", language: "fre",
                       isExternal: external, deliveryURL: url.flatMap(URL.init(string:)))
    }

    private func info(_ method: PlayMethod, _ tracks: [MediaTrackInfo], source: String? = "src") -> PlaybackInfo {
        PlaybackInfo(url: URL(string: "http://localhost/master.m3u8")!, playSessionId: nil, mediaSourceId: source,
                     playMethod: method, audioTracks: [], subtitleTracks: tracks,
                     selectedAudioIndex: nil, selectedSubtitleIndex: nil, authToken: nil)
    }

    @Test("only a transcode brings subtitles in late, and only those the server offers as files")
    func whichTracks() {
        let tracks = [track(0, url: "http://h/Subtitles/0/0/Stream.srt", external: true),
                      track(2, url: "http://h/Subtitles/2/0/Stream.subrip"),
                      track(3, url: nil)] // an image subtitle: burned in by the server
        #expect(LateSubtitles.tracks(of: info(.transcode, tracks)).map(\.id) == [0, 2])
        #expect(LateSubtitles.tracks(of: info(.directStream, tracks)).isEmpty)
        #expect(LateSubtitles.tracks(of: info(.directPlay, tracks)).isEmpty)
    }

    @Test("files are cached per source and track list")
    func cacheKey() {
        let a = [track(2, url: "http://h/2.srt"), track(3, url: "http://h/3.srt")]
        let key = LateSubtitles.cacheKey(of: info(.transcode, a), itemId: "item")
        #expect(key == LateSubtitles.cacheKey(of: info(.transcode, a), itemId: "item"))
        #expect(key != LateSubtitles.cacheKey(of: info(.transcode, a, source: "other"), itemId: "item"))
        #expect(key != LateSubtitles.cacheKey(of: info(.transcode, [a[0]]), itemId: "item"))
        // No source id: the item stands in.
        #expect(LateSubtitles.cacheKey(of: info(.transcode, a, source: nil), itemId: "item").hasPrefix("item|"))
    }

    @Test("the saved file carries an extension libVLC has a parser for")
    func fileNames() throws {
        func name(_ served: String) throws -> String {
            LateSubtitles.fileName(position: 1, deliveryURL: try #require(URL(string: "http://h/Subtitles/2/0/Stream.\(served)?ApiKey=x")))
        }
        #expect(try name("subrip") == "1.srt")
        #expect(try name("srt") == "1.srt")
        #expect(try name("ass") == "1.ass")
        #expect(try name("webvtt") == "1.vtt")
        #expect(try name("js") == "1.srt")
    }

    @Test("the placeholder is a valid, silent SubRip file")
    func placeholder() throws {
        let text = try #require(String(data: LateSubtitles.placeholder, encoding: .utf8))
        #expect(text.contains("-->"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try #require(LateSubtitles.placeholderFile(in: directory))
        #expect(LateSubtitles.placeholderFile(in: directory) == file)
        #expect(try Data(contentsOf: file) == LateSubtitles.placeholder)
    }
}
