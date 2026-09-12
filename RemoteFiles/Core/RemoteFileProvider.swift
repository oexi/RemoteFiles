import Foundation

enum RemoteProviderError: LocalizedError, Sendable {
    case unsupported(String)
    case invalidConfiguration(String)
    case authenticationRequired
    case notConnected
    case conflict(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let message): message
        case .invalidConfiguration(let message): message
        case .authenticationRequired: "Authentication is required."
        case .notConnected: "The remote server is not connected."
        case .conflict(let message): message
        case .invalidResponse(let message): message
        }
    }
}

protocol RemoteFileProvider: Sendable {
    var profile: ConnectionProfile { get }
    var capabilities: ProviderCapabilities { get }

    func connect() async throws
    func disconnect() async
    func list(path: String) async throws -> [RemoteItem]
    func attributes(path: String) async throws -> RemoteItem
    func download(path: String, to localURL: URL) async throws
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws
    func createDirectory(path: String) async throws
    func remove(path: String, isDirectory: Bool) async throws
    func move(from: String, to: String, overwrite: Bool) async throws
}

protocol RemoteChunkReadableProvider: Sendable {
    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data
    func openReadSession(path: String, offset: UInt64) async throws -> (any RemoteChunkReadSession)?
}

protocol RemoteChunkReadSession: Sendable {
    func read(length: Int) async throws -> Data
    func close() async
}

extension RemoteChunkReadableProvider {
    func openReadSession(path: String, offset: UInt64) async throws -> (any RemoteChunkReadSession)? {
        nil
    }
}

protocol RemoteChunkWritableProvider: Sendable {
    /// Prepare a destination for chunked writes. Returns the byte offset that can safely resume.
    func prepareChunkedUpload(path: String, overwrite: Bool, resumeOffset: UInt64) async throws -> UInt64
    func writeChunk(path: String, data: Data, offset: UInt64) async throws
    func finishChunkedUpload(path: String) async throws
    func openWriteSession(
        path: String,
        overwrite: Bool,
        resumeOffset: UInt64
    ) async throws -> (session: any RemoteChunkWriteSession, offset: UInt64)?
}

extension RemoteChunkWritableProvider {
    func finishChunkedUpload(path: String) async throws { }

    func openWriteSession(
        path: String,
        overwrite: Bool,
        resumeOffset: UInt64
    ) async throws -> (session: any RemoteChunkWriteSession, offset: UInt64)? {
        nil
    }
}

protocol RemoteChunkWriteSession: Sendable {
    func write(_ data: Data, at offset: UInt64) async throws
    func finish() async throws
    func abort() async
}

extension RemoteFileProvider {
    func disconnect() async { }

    func attributes(path: String) async throws -> RemoteItem {
        throw RemoteProviderError.unsupported("This provider does not expose item attributes.")
    }

    func createDirectory(path: String) async throws {
        throw RemoteProviderError.unsupported("Creating folders is not supported by this provider.")
    }

    func remove(path: String, isDirectory: Bool) async throws {
        throw RemoteProviderError.unsupported("Deleting items is not supported by this provider.")
    }

    func move(from: String, to: String, overwrite: Bool) async throws {
        throw RemoteProviderError.unsupported("Moving items is not supported by this provider.")
    }
}

enum RemotePath {
    static func normalize(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + components.joined(separator: "/")
    }

    static func join(_ base: String, _ child: String) -> String {
        normalize(base + "/" + child)
    }

    static func parent(_ path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/" else { return "/" }
        let value = (normalized as NSString).deletingLastPathComponent
        return value.isEmpty ? "/" : value
    }
}

