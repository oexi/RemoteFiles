import XCTest
@testable import RemoteFiles

final class SMBShareInfoTests: XCTestCase {
    func testBrowsableKeepsOnlyVisibleDiskShares() {
        let shares = [
            share("video", 0x0000_0000),
            share("IPC$", 0x8000_0003),
            share("ADMIN$", 0x8000_0000),
            share("C$", 0x0000_0000),
            share("printer", 0x0000_0001),
            share("Backup", 0x0200_0000),
            share("docs", 0x4000_0000)
        ]

        XCTAssertEqual(SMBShareInfo.browsable(shares).map(\.name), ["Backup", "docs", "video"])
    }

    func testDiskShareDetectionIgnoresFlagBits() {
        XCTAssertTrue(share("a", 0x0800_0000).isDiskShare)
        XCTAssertFalse(share("a", 0x0000_0002).isDiskShare)
        XCTAssertTrue(share("a", 0x8000_0000).isSpecial)
    }

    private func share(_ name: String, _ type: UInt32) -> SMBShareInfo {
        SMBShareInfo(name: name, comment: "", rawType: type)
    }
}
