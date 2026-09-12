import CryptoKit
import Foundation

actor CacheManager {
    static let shared = CacheManager()

    private let root: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        root = caches.appendingPathComponent("RemoteFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func materialize(provider: any RemoteFileProvider, item: RemoteItem, forceRefresh: Bool = false) async throws -> URL {
        let directory = root.appendingPathComponent(provider.profile.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(item.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = (item.name as NSString).pathExtension
        let fileName = ext.isEmpty ? key : "\(key).\(ext)"
        let destination = directory.appendingPathComponent(fileName)
        if forceRefresh || !FileManager.default.fileExists(atPath: destination.path) {
            do {
                try await provider.download(path: item.path, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
        return destination
    }

    func temporaryURL(fileName: String) throws -> URL {
        let directory = root.appendingPathComponent("Transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString + "-" + fileName)
    }

    func clear() throws {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}

