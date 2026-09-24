import Foundation

/// A remembered remote location: a favorite, or a recently opened file.
struct LocationBookmark: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    let profileID: UUID
    let path: String
    let name: String
    let isDirectory: Bool
    var date: Date

    func refers(to profileID: UUID, path: String) -> Bool {
        self.profileID == profileID && RemotePath.normalize(self.path) == RemotePath.normalize(path)
    }
}
