import Foundation

enum RemoteArchiveService {
    static func extractHere(item: RemoteItem, provider: any RemoteFileProvider) async throws {
        let archiveURL = try await CacheManager.shared.materialize(provider: provider, item: item, forceRefresh: true)
        guard ArchiveManager.canOpen(archiveURL) else {
            throw RemoteProviderError.unsupported("Only ZIP archives are enabled in the first implementation. libarchive integration will add 7z/RAR/tar formats.")
        }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteFiles-Extract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try ArchiveManager.extract(archiveURL, to: tempRoot)

        let destinationRoot = RemotePath.parent(item.path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: tempRoot, includingPropertiesForKeys: keys) else { return }

        var directories: [URL] = []
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true { directories.append(url) }
            else if values.isRegularFile == true { files.append(url) }
        }

        for directory in directories.sorted(by: { $0.pathComponents.count < $1.pathComponents.count }) {
            let relative = relativePath(directory, under: tempRoot)
            try? await provider.createDirectory(path: RemotePath.join(destinationRoot, relative))
        }

        for file in files {
            let relative = relativePath(file, under: tempRoot)
            try await provider.upload(from: file, to: RemotePath.join(destinationRoot, relative), overwrite: true)
        }
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

