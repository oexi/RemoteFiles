import Foundation
import NFSKit

final class NFSProvider: RemoteFileProvider, RemoteChunkReadableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .createDirectory, .delete, .move, .randomRead, .permissions, .symbolicLinks])
    let client: NFSClient
    var connected = false

    init(profile: ConnectionProfile) throws {
        self.profile = profile
        guard let url = URL(string: "nfs://\(profile.host):\(profile.port)"),
              let client = try NFSClient(url: url) else {
            throw RemoteProviderError.invalidConfiguration("Invalid NFS host or port.")
        }
        self.client = client
    }

    func connect() async throws {
        guard !profile.nfsExport.isEmpty else {
            throw RemoteProviderError.invalidConfiguration("NFS requires an export path.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.connect(export: profile.nfsExport) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        connected = true
    }

    func disconnect() async {
        guard connected else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.disconnect(export: profile.nfsExport, gracefully: true) { _ in continuation.resume() }
        }
        connected = false
    }

    func list(path: String) async throws -> [RemoteItem] {
        try await ensureConnected()
        let rows = try await client.contentsOfDirectory(atPath: nfsPath(path)).get()
        return rows.compactMap { row in
            guard let name = row[.nameKey] as? String, name != ".", name != ".." else { return nil }
            let isDirectory = (row[.isDirectoryKey] as? NSNumber)?.boolValue ?? false
            let isLink = (row[.isSymbolicLinkKey] as? NSNumber)?.boolValue ?? false
            let size = (row[.fileSizeKey] as? NSNumber)?.int64Value
            let modified = row[.contentModificationDateKey] as? Date
            return RemoteItem(
                name: name,
                path: RemotePath.join(path, name),
                kind: isDirectory ? .directory : (isLink ? .symbolicLink : .file),
                size: isDirectory ? nil : size,
                modifiedAt: modified,
                createdAt: row[.creationDateKey] as? Date,
                isHidden: name.hasPrefix("."),
                revision: .init(modifiedAt: modified, size: size, opaqueIdentifier: (row[.documentIdentifierKey] as? NSNumber)?.stringValue)
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data {
        try await ensureConnected()
        let lower = Int64(clamping: offset)
        let upper = lower.addingReportingOverflow(Int64(length))
        let end = upper.overflow ? Int64.max : upper.partialValue
        return try await client.contents(atPath: nfsPath(path), range: lower..<end, progress: nil).get()
    }

    func openReadSession(path: String, offset: UInt64) async throws -> (any RemoteChunkReadSession)? {
        try await ensureConnected()
        return NFSReadSession(
            client: client,
            path: nfsPath(path),
            offset: Int64(clamping: offset)
        )
    }

    func ensureConnected() async throws {
        if !connected { try await connect() }
    }

    func nfsPath(_ path: String) -> String { RemotePath.normalize(path) }
}

private final class NFSReadSession: RemoteChunkReadSession, @unchecked Sendable {
    private let slots: DispatchSemaphore
    private let stateLock = NSLock()
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var pendingData: Data?
    private var pendingOffset = 0
    private var producerTask: Task<Void, Never>?
    private var isClosed = false

    init(client: NFSClient, path: String, offset: Int64) {
        let slots = DispatchSemaphore(value: 1)
        let (stream, continuation) = Self.makeStream()
        self.slots = slots
        self.iterator = stream.makeAsyncIterator()
        self.continuation = continuation
        self.pendingData = nil

        self.producerTask = Task<Void, Never> { [client, path, offset, continuation, slots] in
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                guard !Task.isCancelled else {
                    continuation.finish()
                    done.resume()
                    return
                }
                client.contents(
                    atPath: path,
                    offset: offset,
                    fetchedData: { _, _, data in
                        slots.wait()
                        let result = continuation.yield(data)
                        switch result {
                        case .enqueued:
                            return true
                        case .dropped:
                            continuation.finish(throwing: RemoteProviderError.invalidResponse(
                                "NFS read session buffer overflowed."
                            ))
                            slots.signal()
                            return false
                        case .terminated:
                            slots.signal()
                            return false
                        @unknown default:
                            continuation.finish(throwing: RemoteProviderError.invalidResponse(
                                "NFS returned an unsupported stream buffering result."
                            ))
                            slots.signal()
                            return false
                        }
                    },
                    completionHandler: { error in
                        if let error {
                            continuation.finish(throwing: error)
                        } else {
                            continuation.finish()
                        }
                        done.resume()
                    }
                )
            }
        }
    }

    func read(length: Int) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await readNext(length: length)
        }, onCancel: {
            cancel()
        })
    }

    private func readNext(length: Int) async throws -> Data {
        guard length > 0, !isClosedState() else { return Data() }
        try Task.checkCancellation()
        var result = Data()
        result.reserveCapacity(length)
        while !isClosedState(), result.count < length {
            if let data = takePending(length: length - result.count) {
                if result.isEmpty, data.count == length {
                    return data
                }
                result.append(contentsOf: data)
                continue
            }
            do {
                guard let data = try await iterator.next() else {
                    try Task.checkCancellation()
                    return result
                }
                slots.signal()
                try Task.checkCancellation()
                guard !data.isEmpty else { continue }
                pendingData = data
            } catch {
                slots.signal()
                throw error
            }
        }
        return result
    }

    func close() async {
        let producerTask = cancel()
        await producerTask?.value
        clearProducerTask()
    }

    private func clearProducerTask() {
        stateLock.lock()
        self.producerTask = nil
        stateLock.unlock()
    }

    @discardableResult
    private func cancel() -> Task<Void, Never>? {
        stateLock.lock()
        guard !isClosed else {
            let producerTask = self.producerTask
            stateLock.unlock()
            return producerTask
        }
        isClosed = true
        let producerTask = self.producerTask
        stateLock.unlock()

        continuation.finish()
        producerTask?.cancel()
        slots.signal()
        return producerTask
    }

    private func isClosedState() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isClosed
    }

    private func takePending(length: Int) -> Data? {
        guard let pendingData else { return nil }
        let available = pendingData.count - pendingOffset
        guard available > 0 else {
            self.pendingData = nil
            pendingOffset = 0
            return nil
        }

        let count = min(length, available)
        let result: Data
        if pendingOffset == 0, count == pendingData.count {
            result = pendingData
        } else {
            result = pendingData.subdata(in: pendingOffset..<(pendingOffset + count))
        }
        pendingOffset += count
        if pendingOffset == pendingData.count {
            self.pendingData = nil
            pendingOffset = 0
        }
        return result
    }

    private static func makeStream() -> (
        AsyncThrowingStream<Data, Error>,
        AsyncThrowingStream<Data, Error>.Continuation
    ) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(1)) {
            continuation = $0
        }
        return (stream, continuation)
    }
}
