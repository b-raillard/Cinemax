import Testing
import Foundation
@testable import CinemaxKit

@Suite("DownloadItem.isOfflinePlayable")
struct DownloadItemTests {

    private func item(container: String) -> DownloadItem {
        DownloadItem(
            id: "1",
            kind: .movie,
            title: "Test",
            posterTag: nil,
            seriesId: nil,
            seriesTitle: nil,
            seasonId: nil,
            seasonName: nil,
            seasonIndex: nil,
            episodeIndex: nil,
            remoteURL: URL(string: "https://example.com/stream")!,
            containerExt: container,
            runtimeTicks: nil
        )
    }

    @Test("AVKit-friendly containers are offline-playable")
    func friendlyContainers() {
        for ext in ["mp4", "m4v", "m4a", "mov", "ts", "m2ts", "3gp", "3g2"] {
            #expect(item(container: ext).isOfflinePlayable, "\(ext) should be playable")
        }
    }

    @Test("Container check is case-insensitive")
    func caseInsensitive() {
        #expect(item(container: "MP4").isOfflinePlayable)
        #expect(item(container: "Mov").isOfflinePlayable)
    }

    @Test("Non-AVKit containers fall back to VLC (not offline-playable)")
    func unsupportedContainers() {
        for ext in ["mkv", "avi", "webm", "flv", "wmv", ""] {
            #expect(!item(container: ext).isOfflinePlayable, "\(ext) should not be AVKit-playable")
        }
    }
}
