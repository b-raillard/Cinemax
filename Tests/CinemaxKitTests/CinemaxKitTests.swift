import Testing
import Foundation
import JellyfinAPI
@testable import CinemaxKit

@Suite("CinemaxKit Tests")
struct CinemaxKitTests {

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
