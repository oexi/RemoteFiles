import Combine
import Foundation

@MainActor
final class OfflineStore: ObservableObject {
    @Published private(set) var items: [OfflineItem] = []
    @Published var errorMessage: String?

    private let root: URL
    private let indexURL: URL
    private let exportRoot: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("RemoteFiles", isDirectory: true)
        root = directory.appendingPathComponent("Offline", isDirectory: true)
        indexURL = directory.appendingPathComponent("offline.json")
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        exportRoot = caches.appendingPathComponent("RemoteFiles/OfflineExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: exportRoot)
        try? FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        load()
    }

    func isPinned(profileID: UUID, path: String) -> Bool {
        items.contains { $0.profileID == profileID && $0.remotePath == path }
    }

    func pin(
        provider: any RemoteFileProvider,
        item: RemoteItem,
        transfers: TransferEngine
    ) async throws {
        if let existing = items.first(where: { $0.profileID == provider.profile.id && $0.remotePath == item.path }) {
            try? FileManager.default.removeItem(at: localURL(for: existing))
            try? FileManager.default.removeItem(at: exportRoot.appendingPathComponent(existing.id.uuidString, isDirectory: true))
            items.removeAll { $0.id == existing.id }
        }
        let id = UUID()
        let safeName = item.name.replacingOccurrences(of: "/", with: "_")
        let stored = id.uuidString + "-" + safeName
        let destination = root.appendingPathComponent(stored, isDirectory: item.isDirectory)
        let totalSize: Int64?
        if item.isDirectory {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            do {
                totalSize = try await downloadDirectory(
                    provider: provider,
                    remotePath: item.path,
                    localDirectory: destination,
                    transfers: transfers
                )
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        } else {
            do {
                try await transfers.downloadFile(
                    item: item,
                    from: provider,
                    to: destination,
                    destinationLabel: "Offline"
                )
                if let size = item.size {
                    totalSize = size
                } else {
                    totalSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        .map(Int64.init)
                }
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
        let record = OfflineItem(
            id: id,
            profileID: provider.profile.id,
            profileName: provider.profile.name,
            remotePath: item.path,
            fileName: item.name,
            storedFileName: stored,
            size: totalSize,
            pinnedAt: Date(),
            isDirectory: item.isDirectory
        )
        items.insert(record, at: 0)
        persist()
    }

    func unpin(_ item: OfflineItem) {
        try? FileManager.default.removeItem(at: localURL(for: item))
        try? FileManager.default.removeItem(at: exportRoot.appendingPathComponent(item.id.uuidString, isDirectory: true))
        items.removeAll { $0.id == item.id }
        persist()
    }

    func unpin(profileID: UUID, path: String) {
        guard let item = items.first(where: { $0.profileID == profileID && $0.remotePath == path }) else { return }
        unpin(item)
    }

    func localURL(for item: OfflineItem) -> URL {
        root.appendingPathComponent(item.storedFileName)
    }

    func fileDidChange(_ item: OfflineItem) {
        if item.directory {
            let id = item.id
            let directoryURL = localURL(for: item)
            Task { [weak self] in
                let size = await Task.detached(priority: .utility) {
                    try? Self.localTreeSize(at: directoryURL)
                }.value
                guard let self,
                      let index = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[index].size = size
                try? FileManager.default.removeItem(
                    at: self.exportRoot.appendingPathComponent(id.uuidString, isDirectory: true)
                )
                self.persist()
            }
            return
        }

        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let size = (try? localURL(for: item).resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map { Int64($0) }
        items[index].size = size
        try? FileManager.default.removeItem(at: exportRoot.appendingPathComponent(item.id.uuidString, isDirectory: true))
        persist()
    }

    func externalURL(for item: OfflineItem) async throws -> URL {
        let source = localURL(for: item)
        let directory = exportRoot.appendingPathComponent(item.id.uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent(item.fileName)
        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            do {
                try FileManager.default.linkItem(at: source, to: destination)
            } catch {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            return destination
        }.value
    }

    func copyToServer(
        _ item: OfflineItem,
        destination profile: ConnectionProfile,
        transfers: TransferEngine
    ) async throws {
        let provider = try ProviderFactory.make(for: profile)
        try await provider.connect()
        do {
            let parent = RemotePath.normalize(profile.initialPath)
            let descriptor = RemoteItem(
                name: item.fileName,
                path: item.remotePath,
                kind: item.directory ? .directory : .file,
                size: item.size
            )
            let target = await RemoteFileOperations.availablePastePath(
                for: descriptor,
                in: parent,
                provider: provider
            )
            if item.directory {
                try await uploadDirectory(
                    localDirectory: localURL(for: item),
                    remotePath: target,
                    provider: provider,
                    transfers: transfers
                )
            } else {
                try await transfers.uploadFile(
                    localURL: localURL(for: item),
                    to: provider,
                    destinationPath: target,
                    overwrite: false
                )
            }
            await provider.disconnect()
        } catch {
            await provider.disconnect()
            throw error
        }
    }

    @discardableResult
    func extractArchive(_ item: OfflineItem) async throws -> Int {
        let archiveURL = localURL(for: item)
        guard ArchiveManager.canOpen(fileName: item.fileName) else {
            throw RemoteProviderError.unsupported("This offline file is not a supported archive.")
        }

        let offlineRoot = root
        let inserted = try await Task.detached(priority: .userInitiated) {
            let extractionRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("RemoteFilesOfflineExtract", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: extractionRoot) }

            try ArchiveManager.extract(archiveURL, originalName: item.fileName, to: extractionRoot)
            let files = try Self.regularFiles(under: extractionRoot)
            var records: [OfflineItem] = []
            var copiedDestinations: [URL] = []

            do {
                for file in files {
                    let id = UUID()
                    let safeName = file.lastPathComponent.replacingOccurrences(of: "/", with: "_")
                    let stored = id.uuidString + "-" + safeName
                    let destination = offlineRoot.appendingPathComponent(stored)
                    try FileManager.default.copyItem(at: file, to: destination)
                    copiedDestinations.append(destination)
                    let values = try? file.resourceValues(forKeys: [.fileSizeKey])
                    let relativePath = file.path.replacingOccurrences(of: extractionRoot.path + "/", with: "")
                    records.append(OfflineItem(
                        id: id,
                        profileID: item.profileID,
                        profileName: item.profileName + " · extracted",
                        remotePath: item.remotePath + "::" + relativePath,
                        fileName: file.lastPathComponent,
                        storedFileName: stored,
                        size: values?.fileSize.map { Int64($0) },
                        pinnedAt: Date()
                    ))
                }
            } catch {
                for destination in copiedDestinations {
                    try? FileManager.default.removeItem(at: destination)
                }
                throw error
            }
            return records
        }.value

        items.insert(contentsOf: inserted, at: 0)
        persist()
        return inserted.count
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([OfflineItem].self, from: data) else { return }
        items = decoded.filter { FileManager.default.fileExists(atPath: localURL(for: $0).path) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func downloadDirectory(
        provider: any RemoteFileProvider,
        remotePath: String,
        localDirectory: URL,
        transfers: TransferEngine
    ) async throws -> Int64 {
        try Task.checkCancellation()
        let children = try await provider.list(path: remotePath)
        var total: Int64 = 0
        for child in children {
            try Task.checkCancellation()
            let localChild = localDirectory.appendingPathComponent(child.name, isDirectory: child.isDirectory)
            if child.isDirectory {
                try FileManager.default.createDirectory(at: localChild, withIntermediateDirectories: true)
                total += try await downloadDirectory(
                    provider: provider,
                    remotePath: child.path,
                    localDirectory: localChild,
                    transfers: transfers
                )
            } else {
                try await transfers.downloadFile(
                    item: child,
                    from: provider,
                    to: localChild,
                    destinationLabel: "Offline"
                )
                if let size = child.size {
                    total += max(0, size)
                } else if let size = try? localChild.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    private func uploadDirectory(
        localDirectory: URL,
        remotePath: String,
        provider: any RemoteFileProvider,
        transfers: TransferEngine
    ) async throws {
        do {
            try await provider.createDirectory(path: remotePath)
        } catch {
            let existing = try? await provider.attributes(path: remotePath)
            guard existing?.isDirectory == true else { throw error }
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: localDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for child in children {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            let childRemotePath = RemotePath.join(remotePath, child.lastPathComponent)
            if values.isDirectory == true {
                try await uploadDirectory(
                    localDirectory: child,
                    remotePath: childRemotePath,
                    provider: provider,
                    transfers: transfers
                )
            } else {
                try await transfers.uploadFile(
                    localURL: child,
                    to: provider,
                    destinationPath: childRemotePath,
                    overwrite: false
                )
            }
        }
    }

    private nonisolated static func regularFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { files.append(url) }
        }
        return files
    }

    private nonisolated static func localTreeSize(at root: URL) throws -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true, let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
