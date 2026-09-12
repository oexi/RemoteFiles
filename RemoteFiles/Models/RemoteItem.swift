import Foundation

enum RemoteItemKind: String, Codable, Sendable {
    case file, directory, symbolicLink, unknown
}

struct RemoteRevision: Hashable, Codable, Sendable {
    var eTag: String?
    var modifiedAt: Date?
    var size: Int64?
    var opaqueIdentifier: String?
}

struct RemoteItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let kind: RemoteItemKind
    let size: Int64?
    let modifiedAt: Date?
    let createdAt: Date?
    let isHidden: Bool
    let contentType: String?
    let permissions: UInt32?
    let revision: RemoteRevision

    var isDirectory: Bool { kind == .directory }

    init(name: String, path: String, kind: RemoteItemKind, size: Int64? = nil, modifiedAt: Date? = nil, createdAt: Date? = nil, isHidden: Bool = false, contentType: String? = nil, permissions: UInt32? = nil, revision: RemoteRevision = .init()) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.isHidden = isHidden
        self.contentType = contentType
        self.permissions = permissions
        self.revision = revision
    }
}

