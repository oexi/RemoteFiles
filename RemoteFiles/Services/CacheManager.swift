import CryptoKit
import Foundation

actor CacheManager {
    static let shared = CacheManager()

    static let defaultMaximumBytes: Int64 = 512 * 1024 * 1024

    private let root: URL
    private let maximumBytes: Int64
    private struct InFlightEntry {
        let token: UUID
        let task: Task<URL, Error>
    }
    private var inFlight: [String: InFlightEntry] = [:]
    private var generation = 0

    init(root: URL? = nil, maximumBytes: Int64 = CacheManager.defaultMaximumBytes) {
        if let root {
            self.root = root
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.root = caches.appendingPathComponent("RemoteFiles", isDirectory: true)
        }
        self.maximumBytes = max(0, maximumBytes)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func materialize(provider: any RemoteFileProvider, item: RemoteItem, forceRefresh: Bool = false) async throws -> URL {
        let directory = root.appendingPathComponent(provider.profile.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let revision = item.revision
        let keyInput = [
            provider.profile.id.uuidString,
            item.path,
            revision.eTag ?? "",
            revision.modifiedAt.map { String($0.timeIntervalSince1970) } ?? "",
            revision.size.map { String($0) } ?? "",
            revision.opaqueIdentifier ?? ""
        ].joined(separator: "\u{1F}")
        let key = SHA256.hash(data: Data(keyInput.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = (item.name as NSString).pathExtension
        let fileName = ext.isEmpty ? key : "\(key).\(ext)"
        let destination = directory.appendingPathComponent(fileName)
        let canReuseCachedFile = revision.eTag?.isEmpty == false
            || (revision.modifiedAt != nil && revision.size != nil)
        if !forceRefresh,
           canReuseCachedFile,
           FileManager.default.fileExists(atPath: destination.path) {
            try? touch(destination)
            return destination
        }

        let entry: InFlightEntry
        if let existing = inFlight[key] {
            entry = existing
        } else {
            let token = UUID()
            let capturedGeneration = generation
            let task = Task<URL, Error> {
                let staging = directory.appendingPathComponent(".\(fileName).\(UUID().uuidString).staging")
                do {
                    try await provider.download(path: item.path, to: staging)
                    try Task.checkCancellation()
                    guard capturedGeneration == generation else {
                        try? FileManager.default.removeItem(at: staging)
                        throw CancellationError()
                    }
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
                    } else {
                        try FileManager.default.moveItem(at: staging, to: destination)
                    }
                    // Cache maintenance must never turn a successful download into a
                    // failed preview. The downloaded destination is still usable even
                    // when an old cache entry cannot be inspected or removed.
                    try? enforceLimit(protecting: [destination])
                    return destination
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    throw error
                }
            }
            entry = InFlightEntry(token: token, task: task)
            inFlight[key] = entry
        }

        do {
            let result = try await entry.task.value
            if inFlight[key]?.token == entry.token {
                inFlight.removeValue(forKey: key)
            }
            return result
        } catch {
            if inFlight[key]?.token == entry.token {
                inFlight.removeValue(forKey: key)
            }
            throw error
        }
    }

    func temporaryURL(fileName: String) throws -> URL {
        let directory = root.appendingPathComponent("Transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString + "-" + fileName)
    }

    func cacheSize() throws -> Int64 {
        try cachedFiles().reduce(into: Int64.zero) { total, url in
            total += try fileSize(of: url)
        }
    }

    func clear() throws {
        for entry in inFlight.values {
            entry.task.cancel()
        }
        inFlight.removeAll()
        generation &+= 1
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var firstError: Error?
        for url in try cachedFiles() {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    private func enforceLimit(protecting protectedURLs: [URL]) throws {
        var files = try cachedFiles()
        var total = try files.reduce(into: Int64.zero) { total, url in
            total += try fileSize(of: url)
        }
        guard total > maximumBytes else { return }

        let protectedPaths = Set(protectedURLs.map { $0.standardizedFileURL.path })
        files.sort { lhs, rhs in
            modificationDate(of: lhs) < modificationDate(of: rhs)
        }
        for url in files where total > maximumBytes {
            guard !protectedPaths.contains(url.standardizedFileURL.path) else { continue }
            let size = try fileSize(of: url)
            try FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    private func cachedFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try cachedFiles(in: root)
    }

    private func cachedFiles(in directory: URL) throws -> [URL] {
        var files: [URL] = []
        for child in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
        ) {
            let name = child.lastPathComponent
            if name == "Transfers" || name == "OfflineExports" || name == "Thumbnails" {
                continue
            }
            // Hidden entries are reserved for in-progress/staging work. Keep the
            // entire entry out of both accounting and eviction so a clear or LRU
            // pass can never remove a partially written file.
            if name.hasPrefix(".") || name.hasSuffix(".staging") {
                continue
            }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                files.append(contentsOf: try cachedFiles(in: child))
            } else if values.isRegularFile == true {
                files.append(child)
            }
        }
        return files
    }

    private func fileSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }
}
