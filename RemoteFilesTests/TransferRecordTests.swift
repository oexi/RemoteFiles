import XCTest
@testable import RemoteFiles

final class TransferRecordTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let source = UUID()
        let destination = UUID()
        let record = TransferRecord(
            fileName: "movie.mkv",
            sourceProfileID: source,
            sourcePath: "/source/movie.mkv",
            destinationProfileID: destination,
            destinationPath: "/dest/movie.mkv",
            overwrite: true,
            source: "Source:/source/movie.mkv",
            destination: "Destination:/dest/movie.mkv",
            totalBytes: 123456
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
    }
}
