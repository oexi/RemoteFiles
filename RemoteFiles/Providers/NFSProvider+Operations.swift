import Foundation

extension NFSProvider {
    func attributes(path: String) async throws -> RemoteItem {
        try await ensureConnected()
        let row = try await client.attributesOfItem(atPath: nfsPath(path)).get()
        let permissions = try? await permissions(at: path)
        let name = (path as NSString).lastPathComponent
        let isDirectory = (row[.isDirectoryKey] as? NSNumber)?.boolValue ?? false
        let isLink = (row[.isSymbolicLinkKey] as? NSNumber)?.boolValue ?? false
        let size = (row[.fileSizeKey] as? NSNumber)?.int64Value
        let modified = row[.contentModificationDateKey] as? Date
        return RemoteItem(
            name: name,
            path: RemotePath.normalize(path),
            kind: isDirectory ? .directory : (isLink ? .symbolicLink : .file),
            size: isDirectory ? nil : size,
            modifiedAt: modified,
            createdAt: row[.creationDateKey] as? Date,
            isHidden: name.hasPrefix("."),
            permissions: permissions,
            revision: .init(modifiedAt: modified, size: size, opaqueIdentifier: (row[.documentIdentifierKey] as? NSNumber)?.stringValue)
        )
    }

    func setPermissions(path: String, permissions: UInt32) async throws {
        try await ensureConnected()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.setPermissions(permissions & 0o7777, ofItemAtPath: nfsPath(path)) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func download(path: String, to localURL: URL) async throws {
        try await ensureConnected()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.downloadItem(atPath: nfsPath(path), to: localURL, progress: { _, _ in true }) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws {
        try await ensureConnected()
        if !overwrite, (try? await attributes(path: path)) != nil {
            throw RemoteProviderError.conflict("An item already exists at \(path).")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.uploadItem(at: localURL, toPath: nfsPath(path), progress: { _ in true }) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func createDirectory(path: String) async throws {
        try await ensureConnected()
        try await bridge { done in client.createDirectory(atPath: nfsPath(path), completionHandler: done) }
    }

    func remove(path: String, isDirectory: Bool) async throws {
        try await ensureConnected()
        try await bridge { done in client.removeItem(atPath: nfsPath(path), completionHandler: done) }
    }

    func move(from: String, to: String, overwrite: Bool) async throws {
        try await ensureConnected()
        if !overwrite, (try? await attributes(path: to)) != nil {
            throw RemoteProviderError.conflict("An item already exists at \(to).")
        }
        try await bridge { done in
            client.moveItem(atPath: nfsPath(from), toPath: nfsPath(to), completionHandler: done)
        }
    }

    private func bridge(_ operation: (@escaping (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func permissions(at path: String) async throws -> UInt32 {
        try await withCheckedThrowingContinuation { continuation in
            client.permissionsOfItem(atPath: nfsPath(path)) { result in
                continuation.resume(with: result)
            }
        }
    }
}

