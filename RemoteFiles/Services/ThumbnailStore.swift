import CryptoKit
import Foundation
import QuickLookThumbnailing
import UIKit

@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private let memory = NSCache<NSString, UIImage>()
    private let root: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        root = caches.appendingPathComponent("RemoteFiles/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        memory.countLimit = 200
    }

    func canThumbnail(_ item: RemoteItem) -> Bool {
        guard !item.isDirectory else { return false }
        if let size = item.size, size > 25 * 1024 * 1024 { return false }
        let ext = (item.name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "heic", "webp", "pdf"].contains(ext)
    }

    func thumbnail(provider: any RemoteFileProvider, item: RemoteItem, size: CGSize) async -> UIImage? {
        guard canThumbnail(item) else { return nil }
        let key = cacheKey(provider: provider, item: item)
        if let image = memory.object(forKey: key as NSString) { return image }

        let diskURL = root.appendingPathComponent(key).appendingPathExtension("png")
        if let image = UIImage(contentsOfFile: diskURL.path) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }

        do {
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
            memory.setObject(image, forKey: key as NSString)
            if let data = image.pngData() { try? data.write(to: diskURL, options: Data.WritingOptions.atomic) }
            return image
        } catch {
            return nil
        }
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
