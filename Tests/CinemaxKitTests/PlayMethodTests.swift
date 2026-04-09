import Testing
import Foundation
import CinemaxKit

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
