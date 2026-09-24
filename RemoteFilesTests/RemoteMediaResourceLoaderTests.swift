import XCTest
@testable import RemoteFiles

final class RemoteMediaResourceLoaderTests: XCTestCase {
    func testRangeHonoursCurrentOffsetAndClampsToFile() {
        XCTAssertEqual(
            RemoteMediaByteReader.range(requestedOffset: 0, requestedLength: 2, currentOffset: 0, toEnd: false, size: 100),
            0..<2
        )
        XCTAssertEqual(
            RemoteMediaByteReader.range(requestedOffset: 10, requestedLength: 50, currentOffset: 30, toEnd: false, size: 100),
            30..<60
        )
        XCTAssertEqual(
            RemoteMediaByteReader.range(requestedOffset: 90, requestedLength: 50, currentOffset: 90, toEnd: false, size: 100),
            90..<100
        )
        XCTAssertEqual(
            RemoteMediaByteReader.range(requestedOffset: 40, requestedLength: 1, currentOffset: 40, toEnd: true, size: 100),
            40..<100
        )
        XCTAssertTrue(
            RemoteMediaByteReader.range(requestedOffset: 200, requestedLength: 5, currentOffset: 200, toEnd: false, size: 100).isEmpty
        )
    }

    func testReadDeliversRangeInBoundedChunks() async throws {
        let bytes = Data((0..<(RemoteMediaByteReader.chunkSize * 2 + 10)).map { UInt8(truncatingIfNeeded: $0) })
        let provider = ChunkProvider(bytes: bytes)
        let reader = RemoteMediaByteReader(provider: provider, path: "/v.mp4", size: UInt64(bytes.count))

        var received = Data()
        var chunkSizes: [Int] = []
        try await reader.read(5..<UInt64(bytes.count)) { data in
            received.append(data)
            chunkSizes.append(data.count)
        }

        XCTAssertEqual(received, bytes[5...])
        XCTAssertTrue(chunkSizes.allSatisfy { $0 <= RemoteMediaByteReader.chunkSize })
    }

    func testReadFailsWhenFileIsShorterThanExpected() async {
        let provider = ChunkProvider(bytes: Data(repeating: 1, count: 10))
        let reader = RemoteMediaByteReader(provider: provider, path: "/v.mp4", size: 20)

        do {
            try await reader.read(0..<20) { _ in }
            XCTFail("Expected a short-read error")
        } catch let error as RemoteProviderError {
            guard case .invalidResponse = error else { return XCTFail("Unexpected \(error)") }
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testReadStopsWhenCancelled() async {
        let provider = ChunkProvider(bytes: Data(repeating: 0, count: RemoteMediaByteReader.chunkSize * 4))
        let reader = RemoteMediaByteReader(provider: provider, path: "/v.mp4", size: UInt64(RemoteMediaByteReader.chunkSize * 4))

        let task = Task {
            var deliveries = 0
            try await reader.read(0..<reader.size) { _ in
                deliveries += 1
                if deliveries == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return deliveries
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testFTPAndUnplayableFormatsAreNotStreamed() {
        XCTAssertFalse(RemoteMediaResourceLoader.protocolSupportsStreaming(.ftp))
        XCTAssertFalse(RemoteMediaResourceLoader.protocolSupportsStreaming(.ftps))
        XCTAssertTrue(RemoteMediaResourceLoader.protocolSupportsStreaming(.smb))
        XCTAssertNotNil(RemoteMediaResourceLoader.playableType(forFileName: "movie.mp4"))
        XCTAssertNotNil(RemoteMediaResourceLoader.playableType(forFileName: "song.MP3"))
        XCTAssertNil(RemoteMediaResourceLoader.playableType(forFileName: "notes.txt"))
        XCTAssertNil(RemoteMediaResourceLoader.playableType(forFileName: "noextension"))
    }
}

private final class ChunkProvider: RemoteChunkReadableProvider, @unchecked Sendable {
    let bytes: Data

    init(bytes: Data) { self.bytes = bytes }

    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data {
        guard offset < UInt64(bytes.count) else { return Data() }
        let start = Int(offset)
        return bytes[start..<min(bytes.count, start + length)]
    }
}
