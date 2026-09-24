import Foundation
import Combine

/// Persists favorite locations and recently opened files.
@MainActor
final class LocationHistoryStore: ObservableObject {
    static let recentLimit = 30

    @Published private(set) var favorites: [LocationBookmark] = []
    @Published private(set) var recents: [LocationBookmark] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directory = base.appendingPathComponent("RemoteFiles", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("locations.json")
        }
        load()
    }

    func isFavorite(profileID: UUID, path: String) -> Bool {
        favorites.contains { $0.refers(to: profileID, path: path) }
    }

    func toggleFavorite(profileID: UUID, path: String, name: String, isDirectory: Bool) {
        if isFavorite(profileID: profileID, path: path) {
            favorites.removeAll { $0.refers(to: profileID, path: path) }
        } else {
            favorites.append(LocationBookmark(
                profileID: profileID,
                path: RemotePath.normalize(path),
                name: name,
                isDirectory: isDirectory,
                date: Date()
            ))
        }
        persist()
    }

    func recordOpened(profileID: UUID, path: String, name: String, isDirectory: Bool = false) {
        recents.removeAll { $0.refers(to: profileID, path: path) }
        recents.insert(LocationBookmark(
            profileID: profileID,
            path: RemotePath.normalize(path),
            name: name,
            isDirectory: isDirectory,
            date: Date()
        ), at: 0)
        if recents.count > Self.recentLimit {
            recents.removeLast(recents.count - Self.recentLimit)
        }
        persist()
    }

    func remove(_ bookmark: LocationBookmark) {
        favorites.removeAll { $0.id == bookmark.id }
        recents.removeAll { $0.id == bookmark.id }
        persist()
    }

    func clearRecents() {
        recents.removeAll()
        persist()
    }

    /// Drops everything that belongs to a deleted connection.
    func removeAll(for profileID: UUID) {
        favorites.removeAll { $0.profileID == profileID }
        recents.removeAll { $0.profileID == profileID }
        persist()
    }

    private struct Snapshot: Codable {
        var favorites: [LocationBookmark]
        var recents: [LocationBookmark]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        favorites = snapshot.favorites
        recents = Array(snapshot.recents.prefix(Self.recentLimit))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Snapshot(favorites: favorites, recents: recents)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
