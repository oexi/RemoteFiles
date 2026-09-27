import Foundation

enum RemoteFileOperations {
    /// Replaces the contents of a remote file without leaving it truncated if
    /// the connection drops mid-write: the new contents are uploaded next to
    /// the file first and swapped in with renames once complete. Unix
    /// permissions are carried over when the provider exposes them.
    ///
    /// Falls back to an in-place overwrite when the provider cannot rename,
    /// when the target is a symbolic link (renaming would replace the link
    /// with a regular file), or when the staged copy cannot be created, for
    /// example because the user may write the file but not its directory.
    static func replaceFile(
        at path: String,
        with localURL: URL,
        provider: any RemoteFileProvider
    ) async throws {
        let target = RemotePath.normalize(path)
        guard provider.capabilities.contains(.move) else {
            try await provider.upload(from: localURL, to: target, overwrite: true)
            return
        }

        let existing: RemoteItem?
        do {
            existing = try await provider.attributes(path: target)
        } catch {
            guard RemoteProviderError.isNotFound(error) else { throw error }
            existing = nil
        }
        if let existing {
            guard !existing.isDirectory else {
                throw RemoteProviderError.conflict("A folder already exists at \(target).")
            }
            var isLink = existing.kind == .symbolicLink
            if !isLink, let inspector = provider as? any RemoteSymbolicLinkInspecting {
                isLink = try await inspector.isSymbolicLink(path: target)
            }
            if isLink {
                try await provider.upload(from: localURL, to: target, overwrite: true)
                return
            }
        }

        let parent = RemotePath.parent(target)
        let token = UUID().uuidString.lowercased()
        let staged = RemotePath.join(parent, ".remotefiles-\(token).saving")
        do {
            try await provider.upload(from: localURL, to: staged, overwrite: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? await provider.remove(path: staged, isDirectory: false)
            try await provider.upload(from: localURL, to: target, overwrite: true)
            return
        }

        do {
            if let permissions = existing?.permissions, provider.capabilities.contains(.permissions) {
                // Best effort: a server that refuses chmod still gets the new
                // contents with its default mode rather than a failed save.
                try? await provider.setPermissions(path: staged, permissions: permissions)
            }
            guard existing != nil else {
                try await provider.move(from: staged, to: target, overwrite: false)
                return
            }
            let previous = RemotePath.join(parent, ".remotefiles-\(token).previous")
            try await provider.move(from: target, to: previous, overwrite: false)
            do {
                try await provider.move(from: staged, to: target, overwrite: false)
            } catch {
                try? await provider.move(from: previous, to: target, overwrite: false)
                throw error
            }
            try? await provider.remove(path: previous, isDirectory: false)
        } catch {
            try? await provider.remove(path: staged, isDirectory: false)
            throw error
        }
    }

    /// Renames `source` onto the existing file at `destination` for servers whose rename never
    /// replaces its target (SFTP v3 RENAME, SMB without ReplaceIfExists). The old file is moved
    /// aside first, put back if the final rename fails, and deleted once the new file is in place.
    static func renameReplacingFile(
        from source: String,
        to destination: String,
        rename: (_ from: String, _ to: String) async throws -> Void,
        remove: (_ path: String) async throws -> Void
    ) async throws {
        let token = UUID().uuidString.lowercased()
        let aside = RemotePath.join(RemotePath.parent(destination), ".remotefiles-\(token).replaced")
        try await rename(destination, aside)
        do {
            try await rename(source, destination)
        } catch {
            try? await rename(aside, destination)
            throw error
        }
        try? await remove(aside)
    }

    /// Downloads a file and reports `(receivedBytes, totalBytes)` as it arrives. Providers
    /// with chunked reads are read piece by piece; others use their native download, which
    /// reports nothing until it returns.
    static func download(
        _ item: RemoteItem,
        from provider: any RemoteFileProvider,
        to localURL: URL,
        progress: (_ receivedBytes: UInt64, _ totalBytes: UInt64) -> Void
    ) async throws {
        var canReadChunks = provider is any RemoteChunkReadableProvider
        if canReadChunks, let probing = provider as? any RemoteChunkReadSupportProbing {
            canReadChunks = try await probing.supportsChunkedReads(path: item.path)
        }
        guard canReadChunks, let reader = provider as? any RemoteChunkReadableProvider else {
            try await provider.download(path: item.path, to: localURL)
            return
        }
        // The listing's size can be stale, and a chunked read must know exactly where to stop.
        let size: Int64?
        do {
            size = try await provider.attributes(path: item.path).size
        } catch RemoteProviderError.unsupported {
            size = item.size
        }
        guard let size, size >= 0 else {
            try await provider.download(path: item.path, to: localURL)
            return
        }

        let totalBytes = UInt64(size)
        guard FileManager.default.createFile(atPath: localURL.path, contents: nil) else {
            throw RemoteProviderError.invalidResponse("Unable to create \(localURL.lastPathComponent).")
        }
        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }
        var session: (any RemoteChunkReadSession)?
        do {
            session = try await reader.openReadSession(path: item.path, offset: 0)
            var offset: UInt64 = 0
            progress(0, totalBytes)
            while offset < totalBytes {
                try Task.checkCancellation()
                let length = Int(min(UInt64(transferChunkSize), totalBytes - offset))
                let data: Data
                if let session {
                    data = try await session.read(length: length)
                } else {
                    data = try await reader.readChunk(path: item.path, offset: offset, length: length)
                }
                guard !data.isEmpty, data.count <= length else {
                    throw RemoteProviderError.invalidResponse("The source ended before the expected file size was reached.")
                }
                try handle.write(contentsOf: data)
                offset += UInt64(data.count)
                progress(offset, totalBytes)
            }
            await session?.close()
        } catch {
            await session?.close()
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }
    }

    /// Uploads a file to a path that must not exist yet and reports the bytes sent so far.
    /// Providers with chunked writes send it piece by piece; others use their native upload,
    /// which reports nothing until it returns.
    static func uploadNewFile(
        from localURL: URL,
        to path: String,
        provider: any RemoteFileProvider,
        progress: (_ sentBytes: UInt64) -> Void
    ) async throws {
        guard let writer = provider as? any RemoteChunkWritableProvider else {
            try await provider.upload(from: localURL, to: path, overwrite: false)
            return
        }
        let size = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let totalBytes = UInt64(max(0, size))
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }

        // Both write paths create the file exclusively, so after this point the remote file
        // is ours and may be removed if the upload fails.
        let session = try await writer.openWriteSession(path: path, overwrite: false, resumeOffset: 0)?.session
        if session == nil {
            _ = try await writer.prepareChunkedUpload(path: path, overwrite: false, resumeOffset: 0)
        }
        do {
            var offset: UInt64 = 0
            while offset < totalBytes {
                try Task.checkCancellation()
                let length = Int(min(UInt64(transferChunkSize), totalBytes - offset))
                guard let data = try handle.read(upToCount: length), !data.isEmpty else {
                    throw RemoteProviderError.invalidResponse("The local file ended before the expected size was reached.")
                }
                if let session {
                    try await session.write(data, at: offset)
                } else {
                    try await writer.writeChunk(path: path, data: data, offset: offset)
                }
                offset += UInt64(data.count)
                progress(offset)
            }
            if let session {
                try await session.finish()
            } else {
                try await writer.finishChunkedUpload(path: path)
            }
        } catch {
            if let session {
                await session.abort()
            } else {
                await writer.abortChunkedUpload(path: path)
            }
            try? await provider.remove(path: path, isDirectory: false)
            throw error
        }
    }

    private static let transferChunkSize = 1024 * 1024

    static func availablePastePath(
        for item: RemoteItem,
        in parent: String,
        provider: any RemoteFileProvider
    ) async throws -> String {
        let direct = RemotePath.join(parent, item.name)
        do {
            _ = try await provider.attributes(path: direct)
        } catch {
            guard RemoteProviderError.isNotFound(error) else { throw error }
            return direct
        }

        let split = splitName(item.name, isDirectory: item.isDirectory)
        var index = 1
        while true {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let candidateName = split.base + suffix + split.extensionPart
            let candidate = RemotePath.join(parent, candidateName)
            do {
                _ = try await provider.attributes(path: candidate)
            } catch {
                guard RemoteProviderError.isNotFound(error) else { throw error }
                return candidate
            }
            index += 1
        }
    }

    static func wouldPlaceDirectoryInsideItself(sourcePath: String, destinationParent: String) -> Bool {
        let source = RemotePath.normalize(sourcePath)
        let parent = RemotePath.normalize(destinationParent)
        return parent == source || parent.hasPrefix(source + "/")
    }

    static func removeRecursively(
        _ item: RemoteItem,
        provider: any RemoteFileProvider
    ) async throws {
        guard item.isDirectory else {
            try await provider.remove(path: item.path, isDirectory: false)
            return
        }

        let children = try await provider.list(path: item.path)
        for child in children {
            try Task.checkCancellation()
            try await removeRecursively(child, provider: provider)
        }
        try await provider.remove(path: item.path, isDirectory: true)
    }

    static func removeRecursively(
        path: String,
        provider: any RemoteFileProvider
    ) async throws {
        let item = try await provider.attributes(path: path)
        try await removeRecursively(item, provider: provider)
    }

    private static func splitName(_ name: String, isDirectory: Bool) -> (base: String, extensionPart: String) {
        guard !isDirectory,
              let dot = name.lastIndex(of: "."),
              dot != name.startIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[dot...]))
    }
}
