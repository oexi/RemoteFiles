import XCTest
@testable import RemoteFiles

final class TransferExecutionOwnershipTests: XCTestCase {
    func testInvalidatedExecutionCannotFinishOrOwnRetry() {
        var ownership = TransferExecutionOwnership()
        let cancelled = ownership.begin()

        ownership.invalidate()
        let retry = ownership.begin()

        XCTAssertFalse(ownership.owns(cancelled))
        XCTAssertTrue(ownership.owns(retry))
        XCTAssertFalse(ownership.finish(cancelled))
        XCTAssertTrue(ownership.owns(retry))
        XCTAssertTrue(ownership.finish(retry))
        XCTAssertFalse(ownership.owns(retry))
    }
}
