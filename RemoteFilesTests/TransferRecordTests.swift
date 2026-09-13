import Foundation
import XCTest
@testable import RemoteFiles

final class TransferRecordTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let source = UUID()
        let destination = UUID()
        let sourceRevision = RemoteRevision(
            eTag: "etag-1",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            size: 123456,
            opaqueIdentifier: "opaque-1"
        )
        let record = TransferRecord(
            fileName: "movie.mkv",
            sourceProfileID: source,
            sourcePath: "/source/movie.mkv",
            destinationProfileID: destination,
            destinationPath: "/dest/movie.mkv",
            overwrite: true,
            source: "Source:/source/movie.mkv",
            destination: "Destination:/dest/movie.mkv",
            totalBytes: 123456,
            sourceRevision: sourceRevision
        )

        let decoded = try JSONDecoder().decode(
            TransferRecord.self,
            from: JSONEncoder().encode(record)
        )

        XCTAssertEqual(decoded.sourceProfileID, source)
        XCTAssertEqual(decoded.destinationProfileID, destination)
        XCTAssertEqual(decoded.sourcePath, "/source/movie.mkv")
        XCTAssertEqual(decoded.destinationPath, "/dest/movie.mkv")
        XCTAssertTrue(decoded.overwrite)
        XCTAssertEqual(decoded.totalBytes, 123456)
        XCTAssertEqual(decoded.sourceRevision, sourceRevision)
    }

    func testLegacyDecodeWithoutSourceRevision() throws {
        let record = TransferRecord(
            fileName: "movie.mkv",
            sourceProfileID: UUID(),
            sourcePath: "/source/movie.mkv",
            destinationProfileID: UUID(),
            destinationPath: "/dest/movie.mkv",
            overwrite: true,
            source: "Source:/source/movie.mkv",
            destination: "Destination:/dest/movie.mkv",
            totalBytes: 123456,
            sourceRevision: RemoteRevision(
                eTag: "etag-1",
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                size: 123456,
                opaqueIdentifier: "opaque-1"
            )
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )
        object.removeValue(forKey: "sourceRevision")

        let decoded = try JSONDecoder().decode(
            TransferRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.sourceRevision)
        XCTAssertEqual(decoded.fileName, record.fileName)
        XCTAssertEqual(decoded.sourcePath, record.sourcePath)
        XCTAssertEqual(decoded.destinationPath, record.destinationPath)
        XCTAssertEqual(decoded.totalBytes, record.totalBytes)
    }

    func testLegacyDecodeDefaultsToServerTransfer() throws {
        let record = TransferRecord(
            fileName: "legacy.bin",
            sourceProfileID: UUID(),
            sourcePath: "/legacy.bin",
            destinationProfileID: UUID(),
            destinationPath: "/legacy.bin",
            overwrite: false,
            source: "A:/legacy.bin",
            destination: "B:/legacy.bin",
            totalBytes: 10
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )
        object.removeValue(forKey: "kind")
        object.removeValue(forKey: "bytesPerSecond")
        object.removeValue(forKey: "startedAt")

        let decoded = try JSONDecoder().decode(
            TransferRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.operationKind, .serverToServer)
        XCTAssertNil(decoded.bytesPerSecond)
        XCTAssertNil(decoded.startedAt)
    }

    func testResumePolicyETagRules() {
        let transferredBytes: UInt64 = 42
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(String, RemoteRevision?, RemoteRevision, TransferResumeDecision)] = [
            (
                "matching ETag ignores other metadata",
                RemoteRevision(eTag: "etag", modifiedAt: oldDate, size: 10, opaqueIdentifier: "old"),
                RemoteRevision(eTag: "etag", modifiedAt: newDate, size: 20, opaqueIdentifier: "new"),
                .resume(transferredBytes)
            ),
            (
                "different ETag restarts",
                RemoteRevision(eTag: "old-etag", modifiedAt: oldDate, size: 10, opaqueIdentifier: "same"),
                RemoteRevision(eTag: "new-etag", modifiedAt: oldDate, size: 10, opaqueIdentifier: "same"),
                .restart
            ),
            (
                "ETag only on persisted revision restarts",
                RemoteRevision(eTag: "etag", modifiedAt: oldDate, size: 10, opaqueIdentifier: "same"),
                RemoteRevision(eTag: nil, modifiedAt: oldDate, size: 10, opaqueIdentifier: "same"),
                .restart
            ),
            (
                "ETag only on current revision restarts",
                RemoteRevision(eTag: nil, modifiedAt: oldDate, size: 10, opaqueIdentifier: "same"),
                RemoteRevision(eTag: "etag", modifiedAt: oldDate, size: 10, opaqueIdentifier: "same"),
                .restart
            )
        ]

        assertDecisions(cases, transferredBytes: transferredBytes)
    }

    func testResumePolicyMetadataFallbackRules() {
        let transferredBytes: UInt64 = 42
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(String, RemoteRevision?, RemoteRevision, TransferResumeDecision)] = [
            (
                "weak ETags fall back to matching metadata",
                RemoteRevision(eTag: "W/\"old\"", modifiedAt: date, size: 10, opaqueIdentifier: nil),
                RemoteRevision(eTag: "W/\"new\"", modifiedAt: date, size: 10, opaqueIdentifier: nil),
                .resume(transferredBytes)
            ),
            (
                "matching modified date and size ignore opaque identifier",
                RemoteRevision(eTag: nil, modifiedAt: date, size: 10, opaqueIdentifier: "old"),
                RemoteRevision(eTag: nil, modifiedAt: date, size: 10, opaqueIdentifier: "new"),
                .resume(transferredBytes)
            ),
            (
                "changed modified date restarts",
                RemoteRevision(eTag: nil, modifiedAt: date, size: 10, opaqueIdentifier: nil),
                RemoteRevision(eTag: nil, modifiedAt: date.addingTimeInterval(1), size: 10, opaqueIdentifier: nil),
                .restart
            ),
            (
                "changed size restarts",
                RemoteRevision(eTag: nil, modifiedAt: date, size: 10, opaqueIdentifier: nil),
                RemoteRevision(eTag: nil, modifiedAt: date, size: 11, opaqueIdentifier: nil),
                .restart
            )
        ]

        assertDecisions(cases, transferredBytes: transferredBytes)
    }

    func testResumePolicyRequiresCompletePersistedRevision() {
        let currentRevision = RemoteRevision(
            eTag: nil,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            size: 10,
            opaqueIdentifier: "current"
        )
        let cases: [(String, RemoteRevision?, RemoteRevision, TransferResumeDecision)] = [
            ("nil persisted revision restarts", nil, currentRevision, .restart),
            (
                "size-only revisions restart",
                RemoteRevision(eTag: nil, modifiedAt: nil, size: 10, opaqueIdentifier: nil),
                RemoteRevision(eTag: nil, modifiedAt: nil, size: 10, opaqueIdentifier: nil),
                .restart
            ),
            (
                "opaque-only revisions restart",
                RemoteRevision(eTag: nil, modifiedAt: nil, size: nil, opaqueIdentifier: "same"),
                RemoteRevision(eTag: nil, modifiedAt: nil, size: nil, opaqueIdentifier: "same"),
                .restart
            )
        ]

        assertDecisions(cases, transferredBytes: 42)
    }

    private func assertDecisions(
        _ cases: [(String, RemoteRevision?, RemoteRevision, TransferResumeDecision)],
        transferredBytes: UInt64
    ) {
        for (name, persistedRevision, currentRevision, expected) in cases {
            let actual = TransferResumePolicy.decision(
                transferredBytes: transferredBytes,
                persistedRevision: persistedRevision,
                currentRevision: currentRevision
            )
            XCTAssertEqual(actual, expected, name)
        }
    }
}
