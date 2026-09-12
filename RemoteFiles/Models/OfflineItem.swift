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
}
