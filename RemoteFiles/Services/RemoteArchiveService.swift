import Foundation

/// What an archive extraction is doing, for the progress bar shown while it runs.
struct ArchiveExtractionProgress: Equatable, Sendable {
    enum Phase: Sendable {
        case downloading, extracting, uploading
    }

    var phase: Phase
    /// The completed fraction of the phase, or nil while it cannot be measured.
    var fraction: Double?
}

enum RemoteArchiveService {
    /// Extracts `item` next to itself and returns the remote folder that received the files.
    /// With `intoFolder`, a new folder named after the archive is created first; when that name
    /// is taken, a numbered name ("name 2", "name 3", …) is used instead of merging.
    @discardableResult
    static func extractHere(
        item: RemoteItem,
        provider: any RemoteFileProvider,
        intoFolder: Bool = false,
        progress: @escaping @Sendable (ArchiveExtractionProgress) -> Void = { _ in }
    ) async throws -> String {
        progress(ArchiveExtractionProgress(phase: .downloading, fraction: nil))
        let archiveURL = try await CacheManager.shared.materialize(provider: provider, item: item, forceRefresh: true)
        guard ArchiveManager.canOpen(fileName: item.name) else {
            throw RemoteProviderError.unsupported("This archive format is not supported.")
        }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteFiles-Extract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try ArchiveManager.extract(archiveURL, originalName: item.name, to: tempRoot) { fraction in
            progress(ArchiveExtractionProgress(phase: .extracting, fraction: fraction))
        }

        var destinationRoot = RemotePath.parent(item.path)
        let (directories, files) = try extractedItems(under: tempRoot)
        let plan = try extractionPlan(directories: directories, files: files, under: tempRoot)

        guard provider.capabilities.contains(.list) else {
            throw RemoteProviderError.unsupported("Extracting safely requires a provider that can list remote items.")
        }
        guard provider.capabilities.contains(.write) else {
            throw RemoteProviderError.unsupported("This provider does not support writing extracted files.")
        }
        if intoFolder {
            guard provider.capabilities.contains(.createDirectory) else {
                throw RemoteProviderError.unsupported("This provider does not support creating extracted folders.")
            }
            let parent = destinationRoot
            let folderName = ArchiveManager.extractionFolderName(
                for: item.name,
                taken: try await provider.list(path: parent).map(\.name)
            )
            destinationRoot = RemotePath.join(parent, folderName)
            try await provider.createDirectory(path: destinationRoot)
        }

        // A remote provider has no transaction primitive. Preflight every existing
        // directory before the first write, then request non-overwriting uploads.
        // Providers with an atomic no-overwrite primitive can also protect the
        // race after this preflight; providers that only check then write cannot.
        let existing = try await preflight(plan: plan, destinationRoot: destinationRoot, provider: provider)
        try validate(plan: plan, destinationRoot: destinationRoot, existing: existing)
        let needsDirectoryCreation = plan.directories.contains { directory in
            let destination = RemotePath.join(destinationRoot, directory.relativePath)
            return existing[destination] != .directory
        }
        if needsDirectoryCreation && !provider.capabilities.contains(.createDirectory) {
            throw RemoteProviderError.unsupported("This provider does not support creating extracted folders.")
        }

        for directory in plan.directories {
            let destination = RemotePath.join(destinationRoot, directory.relativePath)
            if existing[destination] == .directory {
                continue
            }
            try await provider.createDirectory(path: destination)
        }

        let uploadProgress = ByteProgressReporter(totalBytes: plan.files.reduce(0) { $0 + $1.size }) { fraction in
            progress(ArchiveExtractionProgress(phase: .uploading, fraction: fraction))
        }
        uploadProgress.advance(by: 0)
        for file in plan.files {
            try await provider.upload(
                from: file.localURL,
                to: RemotePath.join(destinationRoot, file.relativePath),
                overwrite: false
            )
            uploadProgress.advance(by: file.size)
        }
        uploadProgress.finish()
        return destinationRoot
    }

    private struct ExtractionEntry {
        let localURL: URL
        let relativePath: String
        let kind: RemoteItemKind
        /// Byte size of a file; 0 for a directory.
        var size: UInt64 = 0
    }

    private struct ExtractionPlan {
        let directories: [ExtractionEntry]
        let files: [ExtractionEntry]

        var allEntries: [ExtractionEntry] { directories + files }
    }

    private static func extractionPlan(
        directories: [URL],
        files: [(url: URL, size: UInt64)],
        under root: URL
    ) throws -> ExtractionPlan {
        var paths: [String: RemoteItemKind] = [:]
        var directoryEntries: [ExtractionEntry] = []
        var fileEntries: [ExtractionEntry] = []

        func append(
            _ url: URL,
            kind: RemoteItemKind,
            size: UInt64 = 0,
            to entries: inout [ExtractionEntry]
        ) throws {
            let relative = relativePath(url, under: root)
            guard !relative.isEmpty else { return }
            if let previous = paths[relative], previous != kind {
                throw RemoteProviderError.invalidResponse(
                    "The archive contains both a file and a folder at \(relative)."
                )
            }
            guard paths[relative] == nil else { return }
            paths[relative] = kind
            entries.append(ExtractionEntry(localURL: url, relativePath: relative, kind: kind, size: size))
        }

        for directory in directories {
            try append(directory, kind: .directory, to: &directoryEntries)
        }
        for file in files {
            try append(file.url, kind: .file, size: file.size, to: &fileEntries)
        }

        directoryEntries.sort { lhs, rhs in
            let leftDepth = lhs.relativePath.split(separator: "/").count
            let rightDepth = rhs.relativePath.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
        fileEntries.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return ExtractionPlan(directories: directoryEntries, files: fileEntries)
    }

    /// Lists only paths that can already exist. Once a component is absent, its
    /// descendants cannot exist in a normal remote filesystem, so no further
    /// listing is needed. A listing error is always propagated; it is unsafe to
    /// interpret an unavailable directory as an empty one.
    private static func preflight(
        plan: ExtractionPlan,
        destinationRoot: String,
        provider: any RemoteFileProvider
    ) async throws -> [String: RemoteItemKind] {
        guard !plan.allEntries.isEmpty else { return [:] }

        var listings: [String: [RemoteItem]] = [:]
        var existing: [String: RemoteItemKind] = [:]
        let entries = plan.allEntries.sorted {
            let leftDepth = $0.relativePath.split(separator: "/").count
            let rightDepth = $1.relativePath.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return $0.relativePath < $1.relativePath
        }

        for entry in entries {
            var parent = RemotePath.normalize(destinationRoot)
            for component in entry.relativePath.split(separator: "/") {
                let destination = RemotePath.join(parent, String(component))
                let children: [RemoteItem]
                if let cached = listings[parent] {
                    children = cached
                } else {
                    children = try await provider.list(path: parent)
                    listings[parent] = children
                }

                guard let child = children.first(where: {
                    RemotePath.normalize($0.path) == destination
                }) else {
                    break
                }

                existing[destination] = child.kind
                guard child.kind == .directory else { break }
                parent = destination
            }
        }
        return existing
    }

    private static func validate(
        plan: ExtractionPlan,
        destinationRoot: String,
        existing: [String: RemoteItemKind]
    ) throws {
        for entry in plan.allEntries {
            var parent = RemotePath.normalize(destinationRoot)
            let components = entry.relativePath.split(separator: "/")
            for (index, component) in components.enumerated() {
                let destination = RemotePath.join(parent, String(component))
                guard let kind = existing[destination] else { break }

                let isLeaf = index == components.count - 1
                if isLeaf {
                    if entry.kind != .directory || kind != .directory {
                        throw RemoteProviderError.conflict("An item already exists at \(destination).")
                    }
                } else if kind != .directory {
                    throw RemoteProviderError.conflict(
                        "Cannot extract \(entry.relativePath) because \(destination) is not a folder."
                    )
                }
                parent = destination
            }
        }
    }

    private static func extractedItems(
        under root: URL
    ) throws -> (directories: [URL], files: [(url: URL, size: UInt64)]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return ([], [])
        }
        var directories: [URL] = []
        var files: [(url: URL, size: UInt64)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true { directories.append(url) }
            else if values.isRegularFile == true { files.append((url, UInt64(max(values.fileSize ?? 0, 0)))) }
        }
        return (directories, files)
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
