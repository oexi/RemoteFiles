import XCTest
@testable import RemoteFiles

final class FTPProviderTests: XCTestCase {
    func testFindItemMatchesNormalizedRemotePath() {
        let item = RemoteItem(
            name: "file.txt",
            path: "/folder/file.txt",
            kind: .file
        )

        let result = FTPProvider.findItem(
            at: "folder/./file.txt",
            in: [item]
        )

        XCTAssertEqual(result?.path, item.path)
    }

    func testFindItemReturnsNilForMissingPath() {
        let item = RemoteItem(
            name: "other.txt",
            path: "/folder/other.txt",
            kind: .file
        )

        XCTAssertNil(FTPProvider.findItem(at: "/folder/missing.txt", in: [item]))
    }
}
