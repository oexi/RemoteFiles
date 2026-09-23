import CryptoKit
import Foundation
import QuickLookThumbnailing
import UIKit

@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()
    nonisolated static let defaultMaximumBytes: Int64 = 128 * 1024 * 1024

    private let memory = NSCache<NSString, UIImage>()
    private let root: URL
    private let maximumBytes: Int64
    private var generation = 0

    init(root: URL? = nil, maximumBytes: Int64 = ThumbnailStore.defaultMaximumBytes) {
        if let root {
            self.root = root
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.root = caches.appendingPathComponent("RemoteFiles/Thumbnails", isDirectory: true)
        }
        self.maximumBytes = max(0, maximumBytes)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        memory.countLimit = 200
    }

    func canThumbnail(_ item: RemoteItem) -> Bool {
        guard !item.isFolderLike else { return false }
        if let size = item.size, size > 25 * 1024 * 1024 { return false }
        let ext = (item.name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "heic", "webp", "pdf"].contains(ext)
    }

    func thumbnail(provider: any RemoteFileProvider, item: RemoteItem, size: CGSize) async -> UIImage? {
        guard canThumbnail(item) else { return nil }
        let key = cacheKey(provider: provider, item: item)
        if let image = memory.object(forKey: key as NSString) {
            touch(root.appendingPathComponent(key).appendingPathExtension("png"))
            return image
        }

        let diskURL = root.appendingPathComponent(key).appendingPathExtension("png")
        if let image = UIImage(contentsOfFile: diskURL.path) {
            touch(diskURL)
            memory.setObject(image, forKey: key as NSString)
            return image
        }

        do {
            let capturedGeneration = generation
            let local = try await CacheManager.shared.materialize(provider: provider, item: item)
            let request = QLThumbnailGenerator.Request(
                fileAt: local,
                size: size,
                scale: UIScreen.main.scale,
                representationTypes: .thumbnail
            )
            let representation: QLThumbnailRepresentation = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<QLThumbnailRepresentation, Error>) in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let representation { continuation.resume(returning: representation) }
                    else { continuation.resume(throwing: RemoteProviderError.invalidResponse("No thumbnail representation.")) }
                }
            }
            let image = representation.uiImage
            guard capturedGeneration == generation else { return image }
            memory.setObject(image, forKey: key as NSString)
            if let data = image.pngData() {
                // The generated image is already available to the caller. Disk
                // persistence and eviction are best-effort and must not make a
                // successful preview appear to have failed.
                do {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try data.write(to: diskURL, options: Data.WritingOptions.atomic)
                    try? enforceLimit(protecting: [diskURL])
                } catch {
                    // Keep returning the in-memory image when the cache volume is
                    // unavailable, full, or read-only.
                }
            }
            return image
        } catch {
            return nil
        }
    }

    func diskUsage() throws -> Int64 {
        try thumbnailFiles().reduce(into: Int64.zero) { total, url in
            total += try fileSize(of: url)
        }
    }

    func clear() throws {
        generation &+= 1
        memory.removeAllObjects()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var firstError: Error?
        for url in try thumbnailFiles() {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    private func enforceLimit(protecting protectedURLs: [URL]) throws {
        var files = try thumbnailFiles()
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

    private func thumbnailFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).filter {
            let name = $0.lastPathComponent
            guard !name.hasPrefix("."), !name.hasSuffix(".staging") else { return false }
            return (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private func fileSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    private func cacheKey(provider: any RemoteFileProvider, item: RemoteItem) -> String {
        let revision = [
            item.revision.eTag ?? "",
            item.revision.modifiedAt.map { String($0.timeIntervalSince1970) } ?? "",
            item.revision.size.map(String.init) ?? ""
        ].joined(separator: "|")
        let raw = "\(provider.profile.id.uuidString)|\(item.path)|\(revision)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
