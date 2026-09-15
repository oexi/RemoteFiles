import Foundation
import XCTest
@testable import RemoteFiles

final class SFTPProviderPerformanceTests: XCTestCase {
    func testPipelineUsesCitadelPayloadBoundaryAndBoundedConcurrency() {
        XCTAssertEqual(SFTPProvider.sftpRequestSize, 32_000)
        XCTAssertEqual(SFTPProvider.maxInFlightRequests, 16)
    }

    func testWriteFailureRollbackTargetIsTheContinuousBatchPrefix() {
        XCTAssertEqual(
            SFTPProvider.writeBatchOffset(baseOffset: 123, batchStart: 512_000),
            512_123
        )
        XCTAssertNil(SFTPProvider.writeBatchOffset(baseOffset: 1, batchStart: -1))
        XCTAssertNil(SFTPProvider.writeBatchOffset(baseOffset: .max, batchStart: 1))
    }

    func testShortReadPreservesOrderAndRequestsAnExactOffsetRestart() throws {
        var result = Data()
        var offset: UInt64 = 123
        var remaining = 32_000 + 7

        let first = Data(repeating: 0x11, count: 32_000)
        XCTAssertEqual(
            try SFTPProvider.consumeReadResponse(
                data: first,
                requestedLength: 32_000,
                into: &result,
                currentOffset: &offset,
                remaining: &remaining
            ),
            .continueBatch
        )

        let short = Data([0x22, 0x23])
        XCTAssertEqual(
            try SFTPProvider.consumeReadResponse(
                data: short,
                requestedLength: 7,
                into: &result,
                currentOffset: &offset,
                remaining: &remaining
            ),
            .restartBatch
        )

        XCTAssertEqual(result.count, 32_002)
        XCTAssertEqual(Data(result.prefix(32_000)), Data(repeating: 0x11, count: 32_000))
        XCTAssertEqual(Data(result.suffix(2)), short)
        XCTAssertEqual(offset, 32_125)
        XCTAssertEqual(remaining, 5)
    }

    func testEmptyReadEndsBeforeAppendingSpeculativeData() throws {
        var result = Data([0x33])
        var offset: UInt64 = 8
        var remaining = 32

        let disposition = try SFTPProvider.consumeReadResponse(
            data: Data(),
            requestedLength: 32,
            into: &result,
            currentOffset: &offset,
            remaining: &remaining
        )

        XCTAssertEqual(disposition, .endOfFile)
        XCTAssertEqual(result, Data([0x33]))
        XCTAssertEqual(offset, 8)
        XCTAssertEqual(remaining, 32)
    }

    func testOversizedReadResponseIsRejected() {
        var result = Data()
        var offset: UInt64 = 0
        var remaining = 1

        XCTAssertThrowsError(
            try SFTPProvider.consumeReadResponse(
                data: Data([0x44, 0x45]),
                requestedLength: 1,
                into: &result,
                currentOffset: &offset,
                remaining: &remaining
            )
        )
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(offset, 0)
        XCTAssertEqual(remaining, 1)
    }
}
