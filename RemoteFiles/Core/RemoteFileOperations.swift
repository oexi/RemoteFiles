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
