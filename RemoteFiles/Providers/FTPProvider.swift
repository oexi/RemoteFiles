import FilesProvider
import Foundation

final class FTPProvider: RemoteFileProvider, RemoteChunkReadableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .createDirectory, .delete, .move, .copy, .resume])

    private let provider: FTPFileProvider

    init(profile: ConnectionProfile, credential: Credential?) throws {
        self.profile = profile
        let scheme: String
        switch profile.protocolType {
        case .ftp:
            scheme = "ftp"
        case .ftps:
            scheme = profile.port == 990 ? "ftps" : "ftpes"
        default:
            throw RemoteProviderError.invalidConfiguration("FTPProvider requires an FTP or FTPS profile.")
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = profile.host
        components.port = profile.port
        components.path = "/"
        guard let baseURL = components.url else {
            throw RemoteProviderError.invalidConfiguration("Invalid FTP host or port.")
        }
        let user = credential?.username ?? profile.username
        let urlCredential = user.isEmpty && credential?.password.isEmpty != false
            ? nil
            : URLCredential(user: user, password: credential?.password ?? "", persistence: .none)
        guard let provider = FTPFileProvider(baseURL: baseURL, mode: .passive, credential: urlCredential) else {
            throw RemoteProviderError.invalidConfiguration("Unable to initialize the FTP client.")
        }
        self.provider = provider
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.isReachable { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: RemoteProviderError.notConnected) }
            }
        }
    }

    func list(path: String) async throws -> [RemoteItem] {
        let objects: [FileObject] = try await withCheckedThrowingContinuation { continuation in
            provider.contentsOfDirectory(path: ftpPath(path)) { objects, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: objects) }
            }
        }
        return objects.map { object in
            RemoteItem(
                name: object.name,
                path: RemotePath.join(path, object.name),
                kind: object.isDirectory ? .directory : (object.isSymLink ? .symbolicLink : .file),
                size: object.isDirectory || object.size < 0 ? nil : object.size,
                modifiedAt: object.modifiedDate,
                createdAt: object.creationDate,
                isHidden: object.isHidden || object.name.hasPrefix("."),
                revision: .init(modifiedAt: object.modifiedDate, size: object.size >= 0 ? object.size : nil)
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func attributes(path: String) async throws -> RemoteItem {
        let object: FileObject = try await withCheckedThrowingContinuation { continuation in
            provider.attributesOfItem(path: ftpPath(path)) { object, error in
                if let error { continuation.resume(throwing: error) }
                else if let object { continuation.resume(returning: object) }
                else { continuation.resume(throwing: RemoteProviderError.invalidResponse("FTP returned no attributes.")) }
            }
        }
        let name = object.name.isEmpty ? (path as NSString).lastPathComponent : object.name
        return RemoteItem(
            name: name,
            path: RemotePath.normalize(path),
            kind: object.isDirectory ? .directory : (object.isSymLink ? .symbolicLink : .file),
            size: object.isDirectory || object.size < 0 ? nil : object.size,
            modifiedAt: object.modifiedDate,
            createdAt: object.creationDate,
            isHidden: object.isHidden || name.hasPrefix("."),
            revision: .init(modifiedAt: object.modifiedDate, size: object.size >= 0 ? object.size : nil)
        )
    }

    func download(path: String, to localURL: URL) async throws {
        try? FileManager.default.removeItem(at: localURL)
        try await bridge { completion in
            _ = provider.copyItem(path: ftpPath(path), toLocalURL: localURL, completionHandler: completion)
        }
    }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws {
        try await bridge { completion in
            _ = provider.copyItem(localFile: localURL, to: ftpPath(path), overwrite: overwrite, completionHandler: completion)
        }
    }

    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.contents(path: ftpPath(path), offset: Int64(clamping: offset), length: length) { data, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    func createDirectory(path: String) async throws {
        let normalized = RemotePath.normalize(path)
        let name = (normalized as NSString).lastPathComponent
        let parent = RemotePath.parent(normalized)
        try await bridge { completion in
            _ = provider.create(folder: name, at: ftpPath(parent), completionHandler: completion)
        }
    }

    func remove(path: String, isDirectory: Bool) async throws {
        try await bridge { completion in
            _ = provider.removeItem(path: ftpPath(path), completionHandler: completion)
        }
    }

    func move(from: String, to: String, overwrite: Bool) async throws {
        try await bridge { completion in
            _ = provider.moveItem(path: ftpPath(from), to: ftpPath(to), overwrite: overwrite, completionHandler: completion)
        }
    }

    private func bridge(_ operation: (@escaping (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func ftpPath(_ path: String) -> String {
        let normalized = RemotePath.normalize(path)
        return normalized == "/" ? "/" : normalized
    }
}

