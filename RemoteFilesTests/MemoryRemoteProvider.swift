import Foundation
@testable import RemoteFiles

/// In-memory remote file system shared by tests that need a writable provider.
/// Several provider instances can point at the same `Storage` to model
/// separate connections to one server.
final class MemoryRemoteProvider: RemoteFileProvider, @unchecked Sendable {
    final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: Data] = [:]
        private var directories: Set<String> = ["/"]
        private var links: Set<String> = []
        private var modes: [String: UInt32] = [:]
        private(set) var operations: [String] = []

        func withLock<T>(_ body: (Storage) throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body(self)
        }

        func write(_ path: String, _ data: Data) {
            withLock { $0.files[RemotePath.normalize(path)] = data }
        }

        func makeDirectory(_ path: String) {
            withLock { _ = $0.directories.insert(RemotePath.normalize(path)) }
        }

        func markSymbolicLink(_ path: String) {
            withLock { _ = $0.links.insert(RemotePath.normalize(path)) }
        }

        func setMode(_ path: String, _ mode: UInt32) {
            withLock { $0.modes[RemotePath.normalize(path)] = mode }
        }

        func data(_ path: String) -> Data? {
            withLock { $0.files[RemotePath.normalize(path)] }
        }

        func mode(_ path: String) -> UInt32? {
            withLock { $0.modes[RemotePath.normalize(path)] }
        }

        func exists(_ path: String) -> Bool {
            let normalized = RemotePath.normalize(path)
            return withLock { $0.files[normalized] != nil || $0.directories.contains(normalized) }
        }

        func isDirectory(_ path: String) -> Bool {
            let normalized = RemotePath.normalize(path)
            return withLock { $0.directories.contains(normalized) }
        }

        var allFiles: [String] {
            withLock { $0.files.keys.sorted() }
        }

        fileprivate func record(_ operation: String) {
            withLock { $0.operations.append(operation) }
        }

        fileprivate func item(at path: String) -> RemoteItem? {
            let normalized = RemotePath.normalize(path)
            return withLock { storage in
                let name = normalized == "/" ? "/" : (normalized as NSString).lastPathComponent
                if storage.directories.contains(normalized) {
                    return RemoteItem(name: name, path: normalized, kind: .directory)
                }
                guard let data = storage.files[normalized] else { return nil }
                let size = Int64(data.count)
                return RemoteItem(
                    name: name,
                    path: normalized,
                    kind: storage.links.contains(normalized) ? .symbolicLink : .file,
                    size: size,
                    permissions: storage.modes[normalized],
                    revision: .init(modifiedAt: Date(timeIntervalSince1970: 1), size: size)
                )
            }
        }

        fileprivate func children(of path: String) -> [String] {
            let parent = RemotePath.normalize(path)
            return withLock { storage in
                (Array(storage.files.keys) + Array(storage.directories))
                    .filter { $0 != "/" && RemotePath.parent($0) == parent }
                    .sorted()
            }
        }

        fileprivate func move(_ from: String, _ to: String) {
            let source = RemotePath.normalize(from)
            let destination = RemotePath.normalize(to)
            withLock { storage in
                if let data = storage.files.removeValue(forKey: source) {
                    storage.files[destination] = data
                    storage.modes[destination] = storage.modes.removeValue(forKey: source)
                    if storage.links.remove(source) != nil { storage.links.insert(destination) }
                    return
                }
                for directory in storage.directories where directory == source || directory.hasPrefix(source + "/") {
                    storage.directories.remove(directory)
                    storage.directories.insert(destination + directory.dropFirst(source.count))
                }
                for (path, data) in storage.files where path.hasPrefix(source + "/") {
                    storage.files.removeValue(forKey: path)
                    storage.files[destination + path.dropFirst(source.count)] = data
                }
            }
        }

        fileprivate func remove(_ path: String) {
            let normalized = RemotePath.normalize(path)
            withLock { storage in
                storage.files.removeValue(forKey: normalized)
                storage.directories.remove(normalized)
                storage.links.remove(normalized)
                storage.modes.removeValue(forKey: normalized)
            }
        }
    }

    enum Failure: Error {
        case injected(String)
    }

    let profile: ConnectionProfile
    let capabilities: ProviderCapabilities
    let storage: Storage
    /// Returns an error to throw for an operation such as "upload:/a.txt".
    var failure: (@Sendable (String) -> Error?)?

    init(
        profile: ConnectionProfile = .empty(for: .sftp),
        storage: Storage = Storage(),
        capabilities: ProviderCapabilities = ProviderCapabilities([.list, .read, .write, .createDirectory, .delete, .move, .permissions])
    ) {
        self.profile = profile
        self.storage = storage
        self.capabilities = capabilities
    }

    private func check(_ operation: String) throws {
        storage.record(operation)
        if let error = failure?(operation) { throw error }
    }

    func connect() async throws { try check("connect") }

    func list(path: String) async throws -> [RemoteItem] {
        try check("list:\(RemotePath.normalize(path))")
        guard storage.isDirectory(path) else {
            throw RemoteProviderError.notFound("missing \(path)")
        }
        return storage.children(of: path).compactMap { storage.item(at: $0) }
    }

    func attributes(path: String) async throws -> RemoteItem {
        try check("stat:\(RemotePath.normalize(path))")
        guard let item = storage.item(at: path) else {
            throw RemoteProviderError.notFound("missing \(path)")
        }
        return item
    }

    func download(path: String, to localURL: URL) async throws {
        try check("download:\(RemotePath.normalize(path))")
        guard let data = storage.data(path) else { throw RemoteProviderError.notFound("missing \(path)") }
        try data.write(to: localURL)
    }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws {
        try check("upload:\(RemotePath.normalize(path))")
        if !overwrite, storage.exists(path) {
            throw RemoteProviderError.conflict("exists \(path)")
        }
        storage.write(path, try Data(contentsOf: localURL))
    }

    func createDirectory(path: String) async throws {
        try check("mkdir:\(RemotePath.normalize(path))")
        if storage.exists(path) { throw RemoteProviderError.conflict("exists \(path)") }
        storage.makeDirectory(path)
    }

    func remove(path: String, isDirectory: Bool) async throws {
        try check("remove:\(RemotePath.normalize(path))")
        guard storage.exists(path) else { throw RemoteProviderError.notFound("missing \(path)") }
        storage.remove(path)
    }

    func move(from: String, to: String, overwrite: Bool) async throws {
        try check("move:\(RemotePath.normalize(from))->\(RemotePath.normalize(to))")
        if !overwrite, storage.exists(to) { throw RemoteProviderError.conflict("exists \(to)") }
        guard storage.exists(from) else { throw RemoteProviderError.notFound("missing \(from)") }
        storage.move(from, to)
    }

    func setPermissions(path: String, permissions: UInt32) async throws {
        try check("chmod:\(RemotePath.normalize(path))")
        storage.setMode(path, permissions)
    }
}
