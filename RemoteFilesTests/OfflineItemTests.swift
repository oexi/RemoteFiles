import Foundation
import XCTest
@testable import RemoteFiles

final class OfflineItemTests: XCTestCase {
    func testLegacyOfflineItemDecodesAsFile() throws {
        let item = OfflineItem(
            id: UUID(),
            profileID: UUID(),
            profileName: "Server",
            remotePath: "/document.txt",
            fileName: "document.txt",
            storedFileName: "stored-document.txt",
            size: 42,
            pinnedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
        )
        object.removeValue(forKey: "isDirectory")

        let decoded = try JSONDecoder().decode(
            OfflineItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertFalse(decoded.directory)
        XCTAssertEqual(decoded.remotePath, item.remotePath)
        XCTAssertEqual(decoded.size, 42)
    }

    func testOfflineFolderRoundTrip() throws {
        let item = OfflineItem(
            id: UUID(),
            profileID: UUID(),
            profileName: "Server",
            remotePath: "/Folder",
            fileName: "Folder",
            storedFileName: "stored-folder",
            size: 123,
            pinnedAt: Date(),
            isDirectory: true
        )

        let decoded = try JSONDecoder().decode(
            OfflineItem.self,
            from: JSONEncoder().encode(item)
        )

        XCTAssertTrue(decoded.directory)
        XCTAssertEqual(decoded.size, 123)
    }
}
