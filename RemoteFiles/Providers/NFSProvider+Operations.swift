import Foundation

extension NFSProvider {
    func attributes(path: String) async throws -> RemoteItem {
        try await ensureConnected()
        let row: [URLResourceKey: Any]
        do {
            row = try await client.attributesOfItem(atPath: nfsPath(path)).get()
        } catch {
            if RemoteProviderError.isNotFound(error) {
                throw RemoteProviderError.notFound("The remote item was not found at \(path).")
            }
            throw error
        }
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
        let _: Void = try await withProviderCancellation { complete, isCancelled -> Progress? in
            client.downloadItem(atPath: nfsPath(path), to: localURL, progress: { _, _ in
                !isCancelled()
            }) { error in
                if let error {
                    complete(.failure(error))
                } else {
                    complete(.success(()))
                }
            }
            return nil
        }
    }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws {
        try await ensureConnected()
        if !overwrite {
            do {
                _ = try await attributes(path: path)
                throw RemoteProviderError.conflict("An item already exists at \(path).")
            } catch {
                guard RemoteProviderError.isNotFound(error) else { throw error }
            }
        }
        let _: Void = try await withProviderCancellation { complete, isCancelled -> Progress? in
            client.uploadItem(at: localURL, toPath: nfsPath(path), progress: { _ in
                !isCancelled()
            }) { error in
                if let error {
                    complete(.failure(error))
                } else {
                    complete(.success(()))
                }
            }
            return nil
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
        if !overwrite {
            do {
                _ = try await attributes(path: to)
                throw RemoteProviderError.conflict("An item already exists at \(to).")
            } catch {
                guard RemoteProviderError.isNotFound(error) else { throw error }
            }
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
