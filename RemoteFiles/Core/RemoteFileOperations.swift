import Foundation

enum RemoteFileOperations {
    static func copyRecursively(
        _ item: RemoteItem,
        from source: any RemoteFileProvider,
        to destination: any RemoteFileProvider,
        destinationPath: String
    ) async throws {
        try Task.checkCancellation()
        if item.isDirectory {
            try await destination.createDirectory(path: destinationPath)
            let children = try await source.list(path: item.path)
            for child in children {
                try Task.checkCancellation()
                try await copyRecursively(
                    child,
                    from: source,
                    to: destination,
                    destinationPath: RemotePath.join(destinationPath, child.name)
                )
            }
            return
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFiles-Clipboard", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let tempURL = tempRoot.appendingPathComponent(item.name)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try await source.download(path: item.path, to: tempURL)
        try Task.checkCancellation()
        try await destination.upload(from: tempURL, to: destinationPath, overwrite: false)
    }

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
