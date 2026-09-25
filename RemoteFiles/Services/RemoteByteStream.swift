import Foundation

/// Opens blocking, seekable streams over one remote file, for players such as libmpv
/// that read on their own threads. Nothing is written to disk.
final class RemoteByteStreamSource: @unchecked Sendable {
    let provider: any RemoteChunkReadableProvider
    let path: String
    let fileName: String
    let size: UInt64

    private let lock = NSLock()
    private var openStreams: [ObjectIdentifier: RemoteByteStream] = [:]

    init(provider: any RemoteChunkReadableProvider, path: String, fileName: String, size: UInt64) {
        self.provider = provider
        self.path = path
        self.fileName = fileName
        self.size = size
    }

    /// Returns nil when the file cannot be streamed; callers then download it instead.
    convenience init?(provider: any RemoteFileProvider, item: RemoteItem) {
        guard let chunkProvider = provider as? any RemoteChunkReadableProvider,
              RemoteMediaResourceLoader.protocolSupportsStreaming(provider.profile.protocolType),
              let size = item.size, size > 0 else { return nil }
        self.init(provider: chunkProvider, path: item.path, fileName: item.name, size: UInt64(size))
    }

    func open() -> RemoteByteStream {
        let stream = RemoteByteStream(source: self)
        lock.withLock { openStreams[ObjectIdentifier(stream)] = stream }
        return stream
    }

    /// Interrupts every open stream, so a blocked read returns an error at once.
    func cancelAll() {
        let streams = lock.withLock { Array(openStreams.values) }
        streams.forEach { $0.cancel() }
    }

    fileprivate func didClose(_ stream: RemoteByteStream) {
        _ = lock.withLock { openStreams.removeValue(forKey: ObjectIdentifier(stream)) }
    }
}

/// A read(2)-style view of a remote file. `read`, `seek` and `close` are called from
/// one reader thread and block it while the provider fetches data; `cancel` may be
/// called from any thread.
final class RemoteByteStream: @unchecked Sendable {
    static let chunkSize = 1024 * 1024

    let size: UInt64

    private let source: RemoteByteStreamSource
    private var position: UInt64 = 0
    private var buffer = Data()
    private var bufferOffset: UInt64 = 0
    private var session: (any RemoteChunkReadSession)?
    private var sessionOffset: UInt64 = 0
    private var sessionsSupported = true

    private let lock = NSLock()
    private var cancelled = false
    private var inFlight: (task: Task<Void, Never>, semaphore: DispatchSemaphore)?

    fileprivate init(source: RemoteByteStreamSource) {
        self.source = source
        self.size = source.size
    }

    /// Copies up to `count` bytes at the current position. Returns 0 at the end of the
    /// file and nil when the read failed or the stream was cancelled.
    func read(into destination: UnsafeMutableRawPointer, count: Int) -> Int? {
        guard count > 0, position < size else { return 0 }
        let bufferEnd = bufferOffset + UInt64(buffer.count)
        if position < bufferOffset || position >= bufferEnd {
            do {
                buffer = try fetch(offset: position, length: Int(min(UInt64(Self.chunkSize), size - position)))
                bufferOffset = position
            } catch {
                return nil
            }
        }
        let start = Int(position - bufferOffset)
        let copied = min(count, buffer.count - start)
        buffer.withUnsafeBytes { bytes in
            destination.copyMemory(from: bytes.baseAddress! + start, byteCount: copied)
        }
        position += UInt64(copied)
        return copied
    }

    /// Moves the read position. Data is fetched lazily by the next `read`.
    func seek(to offset: Int64) -> Int64? {
        guard offset >= 0, !isCancelled else { return nil }
        position = UInt64(offset)
        return offset
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            // Wake the reader even when the provider ignores task cancellation.
            inFlight?.task.cancel()
            inFlight?.semaphore.signal()
        }
    }

    func close() {
        cancel()
        closeSession()
        buffer = Data()
        source.didClose(self)
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    private func fetch(offset: UInt64, length: Int) throws -> Data {
        if session != nil, sessionOffset != offset {
            closeSession()
        }
        let provider = source.provider
        let path = source.path
        if session == nil, sessionsSupported {
            if let opened = try wait({ try await provider.openReadSession(path: path, offset: offset) }) {
                session = opened
                sessionOffset = offset
            } else {
                sessionsSupported = false
            }
        }

        var data: Data
        do {
            if let session {
                data = try wait { try await session.read(length: length) }
            } else {
                data = try wait { try await provider.readChunk(path: path, offset: offset, length: length) }
            }
        } catch {
            // The session may be broken (dropped connection); the next read reopens it.
            closeSession()
            throw error
        }
        guard !data.isEmpty else {
            closeSession()
            throw RemoteProviderError.invalidResponse("The file ended before the requested range.")
        }
        if data.count > length { data = data.prefix(length) }
        if session != nil { sessionOffset += UInt64(data.count) }
        return data
    }

    private func closeSession() {
        guard let session else { return }
        self.session = nil
        Task { await session.close() }
    }

    /// Runs `operation` and blocks the calling (reader) thread until it finishes.
    private func wait<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        let started: Bool = lock.withLock {
            guard !cancelled else { return false }
            let task = Task {
                let result: Result<T, Error>
                do {
                    result = .success(try await operation())
                } catch {
                    result = .failure(error)
                }
                box.set(result)
                semaphore.signal()
            }
            inFlight = (task, semaphore)
            return true
        }
        guard started else { throw CancellationError() }
        semaphore.wait()
        let wasCancelled = lock.withLock {
            inFlight = nil
            return cancelled
        }
        guard !wasCancelled, let result = box.get() else { throw CancellationError() }
        return try result.get()
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func set(_ result: Result<T, Error>) {
        lock.withLock { self.result = result }
    }

    func get() -> Result<T, Error>? {
        lock.withLock { result }
    }
}
