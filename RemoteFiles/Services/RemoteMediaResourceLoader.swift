import AVFoundation
import UniformTypeIdentifiers

/// Serves an `AVURLAsset` from a remote file with range reads, so audio and video
/// start playing and can seek without downloading the whole file first.
final class RemoteMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "remotefiles-stream"

    let assetURL: URL
    let queue = DispatchQueue(label: "RemoteFiles.MediaResourceLoader")

    private let reader: RemoteMediaByteReader
    private let contentType: String
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Returns nil when the file cannot be streamed; callers then download it instead.
    init?(provider: any RemoteFileProvider, item: RemoteItem) {
        guard let chunkProvider = provider as? any RemoteChunkReadableProvider,
              Self.protocolSupportsStreaming(provider.profile.protocolType),
              let size = item.size, size > 0,
              let type = Self.playableType(forFileName: item.name) else { return nil }
        reader = RemoteMediaByteReader(provider: chunkProvider, path: item.path, size: UInt64(size))
        contentType = type.identifier
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "media"
        components.path = "/" + item.name
        assetURL = components.url ?? URL(string: "\(Self.scheme)://media/stream")!
        super.init()
    }

    /// FTP opens a new control and data connection for every range, which is too slow to stream.
    static func protocolSupportsStreaming(_ type: RemoteProtocol) -> Bool {
        switch type {
        case .sftp, .smb, .webdav, .nfs: true
        case .ftp, .ftps: false
        }
    }

    /// The file's type when AVFoundation can play it (MP4, MOV, M4A, MP3, …); nil for MKV, AVI and others.
    static func playableType(forFileName name: String) -> UTType? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              type.conforms(to: .audiovisualContent) else { return nil }
        let playable = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))
        return playable.contains(type.identifier) ? type : nil
    }

    func cancelAll() {
        lock.withLock {
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(reader.size)
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let range = RemoteMediaByteReader.range(
            requestedOffset: dataRequest.requestedOffset,
            requestedLength: dataRequest.requestedLength,
            currentOffset: dataRequest.currentOffset,
            toEnd: dataRequest.requestsAllDataToEndOfResource,
            size: reader.size
        )
        let key = ObjectIdentifier(loadingRequest)
        let reader = reader
        let queue = queue
        let task = Task { [weak self] in
            do {
                try await reader.read(range) { data in
                    queue.sync { dataRequest.respond(with: data) }
                }
                queue.sync { loadingRequest.finishLoading() }
            } catch is CancellationError {
                // AVFoundation cancelled the request; it must not be finished.
            } catch {
                queue.sync { loadingRequest.finishLoading(with: error) }
            }
            self?.lock.withLock { self?.tasks[key] = nil }
        }
        lock.withLock { tasks[key] = task }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let task = lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }
        task?.cancel()
    }
}

/// Reads a byte range of a remote file in bounded chunks.
struct RemoteMediaByteReader: Sendable {
    static let chunkSize = 512 * 1024

    let provider: any RemoteChunkReadableProvider
    let path: String
    let size: UInt64

    /// The bytes an AVFoundation data request still needs, clamped to the file.
    static func range(
        requestedOffset: Int64,
        requestedLength: Int,
        currentOffset: Int64,
        toEnd: Bool,
        size: UInt64
    ) -> Range<UInt64> {
        let start = min(UInt64(max(0, max(requestedOffset, currentOffset))), size)
        let requestedEnd = UInt64(max(0, requestedOffset)) + UInt64(max(0, requestedLength))
        let end = toEnd ? size : min(requestedEnd, size)
        return start..<max(start, end)
    }

    /// Delivers `range` in order. Uses a sequential read session where the provider has one.
    func read(_ range: Range<UInt64>, deliver: (Data) async throws -> Void) async throws {
        guard !range.isEmpty else { return }
        var offset = range.lowerBound
        let session = try await provider.openReadSession(path: path, offset: offset)
        do {
            while offset < range.upperBound {
                try Task.checkCancellation()
                let length = Int(min(UInt64(Self.chunkSize), range.upperBound - offset))
                var data: Data
                if let session {
                    data = try await session.read(length: length)
                } else {
                    data = try await provider.readChunk(path: path, offset: offset, length: length)
                }
                guard !data.isEmpty else {
                    throw RemoteProviderError.invalidResponse("The file ended before the requested range.")
                }
                if data.count > length { data = data.prefix(length) }
                try await deliver(data)
                offset += UInt64(data.count)
            }
        } catch {
            await session?.close()
            throw error
        }
        await session?.close()
    }
}
