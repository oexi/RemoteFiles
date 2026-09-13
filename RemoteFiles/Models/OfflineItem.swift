import Foundation

struct OfflineItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let profileID: UUID
    let profileName: String
    let remotePath: String
    let fileName: String
    let storedFileName: String
    var size: Int64?
    let pinnedAt: Date
    var isDirectory: Bool?

    var directory: Bool { isDirectory ?? false }

    init(
        id: UUID,
        profileID: UUID,
        profileName: String,
        remotePath: String,
        fileName: String,
        storedFileName: String,
        size: Int64?,
        pinnedAt: Date,
        isDirectory: Bool = false
    ) {
        self.id = id
        self.profileID = profileID
        self.profileName = profileName
        self.remotePath = remotePath
        self.fileName = fileName
        self.storedFileName = storedFileName
        self.size = size
        self.pinnedAt = pinnedAt
        self.isDirectory = isDirectory
    }
}
