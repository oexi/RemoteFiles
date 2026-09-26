import XCTest
@testable import RemoteFiles

final class RemoteByteStreamTests: XCTestCase {
    private let bytes = Data((0..<(RemoteByteStream.chunkSize * 2 + 100)).map { UInt8(truncatingIfNeeded: $0 &* 7) })

    func testSequentialReadsReturnWholeFileThroughOneSession() {
        let provider = StreamProvider(bytes: bytes, supportsSessions: true)
        let stream = makeSource(provider).open()

        XCTAssertEqual(readAll(stream, bufferSize: 300_000), bytes)
        XCTAssertEqual(provider.sessionOpenOffsets, [0])
        stream.close()
    }

    func testSeekReopensSessionAtNewOffset() {
        let provider = StreamProvider(bytes: bytes, supportsSessions: true)
        let stream = makeSource(provider).open()
        let target = RemoteByteStream.chunkSize + 10

        XCTAssertEqual(read(stream, count: 16), bytes[0..<16])
        XCTAssertEqual(stream.seek(to: Int64(target)), Int64(target))
        XCTAssertEqual(read(stream, count: 16), bytes[target..<(target + 16)])
        XCTAssertEqual(provider.sessionOpenOffsets, [0, UInt64(target)])
        stream.close()
    }

    func testSeekInsideBufferedChunkDoesNotRead() {
        let provider = StreamProvider(bytes: bytes, supportsSessions: false)
        let stream = makeSource(provider).open()

        XCTAssertEqual(read(stream, count: 100), bytes[0..<100])
        XCTAssertEqual(stream.seek(to: 10), 10)
        XCTAssertEqual(read(stream, count: 20), bytes[10..<30])
        XCTAssertEqual(provider.chunkReadOffsets, [0])
        stream.close()
    }

    func testReadAtEndOfFileReturnsZero() {
        let provider = StreamProvider(bytes: bytes, supportsSessions: false)
        let stream = makeSource(provider).open()

        XCTAssertEqual(stream.seek(to: Int64(bytes.count)), Int64(bytes.count))
        var byte: UInt8 = 0
        XCTAssertEqual(stream.read(into: &byte, count: 1), 0)
        stream.close()
    }

    func testShortFileFailsInsteadOfReturningEndOfFile() {
        let provider = StreamProvider(bytes: Data(repeating: 1, count: 10), supportsSessions: false)
        let source = RemoteByteStreamSource(provider: provider, path: "/movie.mkv", fileName: "movie.mkv", size: 20)
        let stream = source.open()

        XCTAssertEqual(read(stream, count: 10), Data(repeating: 1, count: 10))
        var byte: UInt8 = 0
        XCTAssertNil(stream.read(into: &byte, count: 1))
        stream.close()
    }

    func testCancelUnblocksReadThatProviderNeverFinishes() {
        let provider = StreamProvider(bytes: bytes, supportsSessions: false, hangs: true)
        let source = makeSource(provider)
        let stream = source.open()
        let finished = expectation(description: "read returned")

        DispatchQueue.global().async {
            var byte: UInt8 = 0
            XCTAssertNil(stream.read(into: &byte, count: 1))
            finished.fulfill()
        }
        provider.waitUntilReadStarts()
        source.cancelAll()

        wait(for: [finished], timeout: 5)
        XCTAssertNil(stream.seek(to: 0))
        stream.close()
    }

    private func makeSource(_ provider: StreamProvider) -> RemoteByteStreamSource {
        RemoteByteStreamSource(provider: provider, path: "/movie.mkv", fileName: "movie.mkv", size: UInt64(provider.bytes.count))
    }

    private func read(_ stream: RemoteByteStream, count: Int) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: count)
        while data.count < count {
            let read = buffer.withUnsafeMutableBytes { stream.read(into: $0.baseAddress!, count: count - data.count) }
            guard let read, read > 0 else { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }

    private func readAll(_ stream: RemoteByteStream, bufferSize: Int) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let read = buffer.withUnsafeMutableBytes { stream.read(into: $0.baseAddress!, count: bufferSize) }
            guard let read, read > 0 else { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}

final class MPVPlayerFormatTests: XCTestCase {
    func testPlaysAudioAndVideoByExtension() {
        XCTAssertTrue(MPVPlayer.canPlay(fileName: "movie.mkv"))
        XCTAssertTrue(MPVPlayer.canPlay(fileName: "clip.WEBM"))
        XCTAssertTrue(MPVPlayer.canPlay(fileName: "old.avi"))
        XCTAssertTrue(MPVPlayer.canPlay(fileName: "movie.mp4"))
        XCTAssertTrue(MPVPlayer.canPlay(fileName: "song.MP3"))
        XCTAssertFalse(MPVPlayer.canPlay(fileName: "notes.txt"))
        XCTAssertFalse(MPVPlayer.canPlay(fileName: "noextension"))
    }

    func testFTPIsNotStreamed() {
        XCTAssertFalse(RemoteByteStreamSource.protocolSupportsStreaming(.ftp))
        XCTAssertFalse(RemoteByteStreamSource.protocolSupportsStreaming(.ftps))
        XCTAssertTrue(RemoteByteStreamSource.protocolSupportsStreaming(.smb))
        XCTAssertTrue(RemoteByteStreamSource.protocolSupportsStreaming(.sftp))
    }

    func testTimeString() {
        XCTAssertEqual(MPVPlayer.timeString(0), "0:00")
        XCTAssertEqual(MPVPlayer.timeString(65.9), "1:05")
        XCTAssertEqual(MPVPlayer.timeString(3_725), "1:02:05")
        XCTAssertEqual(MPVPlayer.timeString(.nan), "0:00")
    }

    func testVideoTrackSizeFollowsRotationAndPixelAspect() throws {
        let json = """
        [{"id":1,"type":"video","demux-w":1920,"demux-h":1080},
         {"id":2,"type":"video","demux-w":1920,"demux-h":1080,"demux-rotation":90},
         {"id":3,"type":"video","demux-w":720,"demux-h":576,"demux-par":1.4222},
         {"id":1,"type":"audio","lang":"jpn"},
         {"id":1,"type":"sub","lang":"chi"}]
        """
        let tracks = try JSONDecoder().decode([MPVPlayer.Track].self, from: Data(json.utf8))
        XCTAssertEqual(tracks[0].displaySize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(tracks[1].displaySize, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(Double(tracks[2].displaySize?.width ?? 0), 1024, accuracy: 0.1)
        XCTAssertNil(tracks[3].displaySize)
    }

    func testDrawableSizeKeepsAspectWithinScreen() {
        XCTAssertEqual(
            MPVPlayer.drawableSize(for: CGSize(width: 3840, height: 2160), maximumDimension: 2556),
            CGSize(width: 2556, height: 1438)
        )
        XCTAssertEqual(
            MPVPlayer.drawableSize(for: CGSize(width: 1280, height: 720), maximumDimension: 2556),
            CGSize(width: 1280, height: 720)
        )
    }
}

private final class StreamProvider: RemoteChunkReadableProvider, @unchecked Sendable {
    let bytes: Data
    private let supportsSessions: Bool
    private let hangs: Bool
    private let lock = NSLock()
    private let readStarted = DispatchSemaphore(value: 0)
    private var _sessionOpenOffsets: [UInt64] = []
    private var _chunkReadOffsets: [UInt64] = []

    init(bytes: Data, supportsSessions: Bool, hangs: Bool = false) {
        self.bytes = bytes
        self.supportsSessions = supportsSessions
        self.hangs = hangs
    }

    var sessionOpenOffsets: [UInt64] { lock.withLock { _sessionOpenOffsets } }
    var chunkReadOffsets: [UInt64] { lock.withLock { _chunkReadOffsets } }

    func waitUntilReadStarts() {
        readStarted.wait()
    }

    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data {
        lock.withLock { _chunkReadOffsets.append(offset) }
        if hangs {
            readStarted.signal()
            // Ignores cancellation, like a provider stuck on a dead connection.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) { continuation.resume() }
            }
        }
        return slice(offset: offset, length: length)
    }

    func openReadSession(path: String, offset: UInt64) async throws -> (any RemoteChunkReadSession)? {
        guard supportsSessions else { return nil }
        lock.withLock { _sessionOpenOffsets.append(offset) }
        return Session(provider: self, offset: offset)
    }

    fileprivate func slice(offset: UInt64, length: Int) -> Data {
        guard offset < UInt64(bytes.count) else { return Data() }
        let start = Int(offset)
        return bytes[start..<min(bytes.count, start + length)]
    }

    private final class Session: RemoteChunkReadSession, @unchecked Sendable {
        private let provider: StreamProvider
        private var offset: UInt64

        init(provider: StreamProvider, offset: UInt64) {
            self.provider = provider
            self.offset = offset
        }

        func read(length: Int) async throws -> Data {
            let data = provider.slice(offset: offset, length: length)
            offset += UInt64(data.count)
            return data
        }

        func close() async {}
    }
}
