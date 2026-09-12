import Foundation

enum RemoteAccessControlEntryKind: String, Hashable, Sendable {
    case allow
    case deny
    case audit
    case unknown
}

struct RemoteAccessControlEntry: Identifiable, Hashable, Sendable {
    let id: Int
    let kind: RemoteAccessControlEntryKind
    let principal: String
    let accessMask: UInt32
    let flags: UInt8
    let rights: [String]

    var isInherited: Bool { flags & 0x10 != 0 }
}

struct RemoteAccessControlInfo: Hashable, Sendable {
    let owner: String?
    let group: String?
    let daclProtected: Bool
    let entries: [RemoteAccessControlEntry]
}
