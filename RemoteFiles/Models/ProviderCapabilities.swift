import Foundation

enum ProviderCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case list, read, write, createDirectory, delete, move, copy
    case randomRead, randomWrite, resume, serverSideCopy
    case permissions, accessControl, symbolicLinks, search, trash, fileRevisions
}

struct ProviderCapabilities: Hashable, Sendable {
    var values: Set<ProviderCapability>

    init(_ values: Set<ProviderCapability>) { self.values = values }
    func contains(_ capability: ProviderCapability) -> Bool { values.contains(capability) }

    static let readOnly = ProviderCapabilities([.list, .read])
    static let basicReadWrite = ProviderCapabilities([.list, .read, .write, .createDirectory, .delete, .move])
}

