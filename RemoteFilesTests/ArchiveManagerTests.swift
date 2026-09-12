import XCTest
@testable import RemoteFiles

final class ArchiveManagerTests: XCTestCase {
    func testSupportedArchiveNames() {
        for name in [
            "a.zip", "a.7z", "a.rar", "a.tar", "a.tgz", "a.tar.gz",
            "a.tbz2", "a.tar.bz2", "a.txz", "a.tar.xz", "a.gz", "a.bz2", "a.xz"
        ] {
            XCTAssertTrue(ArchiveManager.canOpen(fileName: name), name)
        }
        XCTAssertFalse(ArchiveManager.canOpen(fileName: "not-an-archive.txt"))
    }
}
