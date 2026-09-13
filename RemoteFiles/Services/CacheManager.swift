import CryptoKit
import Foundation

actor CacheManager {
    static let shared = CacheManager()

    private let root: URL
    private struct InFlightEntry {
        let token: UUID
        let task: Task<URL, Error>
    }
    private var inFlight: [String: InFlightEntry] = [:]
    private var generation = 0

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.root = caches.appendingPathComponent("RemoteFiles", isDirectory: true)
        }
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

    func clear() throws {
        for entry in inFlight.values {
            entry.task.cancel()
        }
        inFlight.removeAll()
        generation &+= 1
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}
