import Testing
@testable import CinemaxKit

@Suite("CinemaxKit Tests")
struct CinemaxKitTests {

    @Test("MediaItem runtime calculation")
    func testRuntimeMinutes() {
        let item = MediaItem(
            id: "test",
            name: "Test Movie",
            type: .movie,
            runTimeTicks: 72_000_000_000 // 120 minutes
        )
        #expect(item.runtimeMinutes == 120)
    }

    @Test("MediaItem without runtime")
    func testNoRuntime() {
        let item = MediaItem(
            id: "test",
            name: "Test",
            type: .movie
        )
        #expect(item.runtimeMinutes == nil)
    }

    @Test("ServerInfo initialization")
    func testServerInfo() {
        let info = ServerInfo(
            name: "Test Server",
            serverID: "abc123",
            version: "10.8.10",
            url: URL(string: "http://localhost:8096")!
        )
        #expect(info.name == "Test Server")
        #expect(info.version == "10.8.10")
    }

    @Test("ImageURLBuilder generates correct URLs")
    func testImageURLBuilder() {
        let builder = ImageURLBuilder(serverURL: URL(string: "http://localhost:8096")!)
        let url = builder.imageURL(itemId: "item123", imageType: .primary, maxWidth: 300)
        #expect(url.path().contains("/Items/item123/Images/Primary"))
        #expect(url.absoluteString.contains("maxWidth=300"))
    }
}
