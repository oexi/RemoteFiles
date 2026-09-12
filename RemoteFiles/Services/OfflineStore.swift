import Combine
import Foundation

@MainActor
final class OfflineStore: ObservableObject {
    @Published private(set) var items: [OfflineItem] = []
    @Published var errorMessage: String?

    private let root: URL
    private let indexURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("RemoteFiles", isDirectory: true)
        root = directory.appendingPathComponent("Offline", isDirectory: true)
        indexURL = directory.appendingPathComponent("offline.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func isPinned(profileID: UUID, path: String) -> Bool {
        items.contains { $0.profileID == profileID && $0.remotePath == path }
    }

    func pin(provider: any RemoteFileProvider, item: RemoteItem) async throws {
        if let existing = items.first(where: { $0.profileID == provider.profile.id && $0.remotePath == item.path }) {
            try? FileManager.default.removeItem(at: localURL(for: existing))
            items.removeAll { $0.id == existing.id }
        }
        let id = UUID()
        let safeName = item.name.replacingOccurrences(of: "/", with: "_")
        let stored = id.uuidString + "-" + safeName
        let destination = root.appendingPathComponent(stored)
        try await provider.download(path: item.path, to: destination)
        let record = OfflineItem(
            id: id,
            profileID: provider.profile.id,
            profileName: provider.profile.name,
            remotePath: item.path,
            fileName: item.name,
            storedFileName: stored,
            size: item.size,
            pinnedAt: Date()
        )
        items.insert(record, at: 0)
        persist()
    }

    func unpin(_ item: OfflineItem) {
        try? FileManager.default.removeItem(at: localURL(for: item))
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

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([OfflineItem].self, from: data) else { return }
        items = decoded.filter { FileManager.default.fileExists(atPath: localURL(for: $0).path) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
