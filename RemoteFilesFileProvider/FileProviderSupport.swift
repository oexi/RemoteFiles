import FileProvider
import Foundation
import UniformTypeIdentifiers

struct FileProviderPathCodec {
    let rootPath: String

    func identifier(for path: String) -> NSFileProviderItemIdentifier {
        let normalized = RemotePath.normalize(path)
        if normalized == RemotePath.normalize(rootPath) { return .rootContainer }
        let encoded = Data(normalized.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return NSFileProviderItemIdentifier("path:\(encoded)")
    }

    func path(for identifier: NSFileProviderItemIdentifier) throws -> String {
        if identifier == .rootContainer { return RemotePath.normalize(rootPath) }
        guard identifier.rawValue.hasPrefix("path:") else {
            throw RemoteProviderError.invalidResponse("Unknown File Provider item identifier.")
        }
        var encoded = String(identifier.rawValue.dropFirst(5))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        guard let data = Data(base64Encoded: encoded), let value = String(data: data, encoding: .utf8) else {
            throw RemoteProviderError.invalidResponse("Invalid File Provider item identifier.")
        }
        return RemotePath.normalize(value)
    }

    func parentIdentifier(for path: String) -> NSFileProviderItemIdentifier {
        identifier(for: RemotePath.parent(path))
    }
}

final class FileProviderItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let creationDate: Date?
    let contentModificationDate: Date?
    let capabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion

    var typeIdentifier: String { contentType.identifier }

    init(remote: RemoteItem, codec: FileProviderPathCodec, providerCapabilities: ProviderCapabilities) {
        itemIdentifier = codec.identifier(for: remote.path)
        parentItemIdentifier = codec.parentIdentifier(for: remote.path)
        filename = remote.name
        contentType = remote.isDirectory ? .folder : (UTType(filenameExtension: (remote.name as NSString).pathExtension) ?? .data)
        documentSize = remote.size.map(NSNumber.init(value:))
        creationDate = remote.createdAt
        contentModificationDate = remote.modifiedAt

        var caps: NSFileProviderItemCapabilities = [.allowsReading]
        if remote.isDirectory, providerCapabilities.contains(.write) { caps.insert(.allowsAddingSubItems) }
        if providerCapabilities.contains(.write) { caps.insert(.allowsWriting) }
        if providerCapabilities.contains(.delete) { caps.insert(.allowsDeleting) }
        if providerCapabilities.contains(.move) { caps.insert(.allowsRenaming); caps.insert(.allowsReparenting) }
        capabilities = caps

        let revision = [
            remote.revision.eTag ?? "",
            remote.revision.modifiedAt.map { String($0.timeIntervalSince1970) } ?? "",
            remote.revision.size.map(String.init) ?? "",
            remote.revision.opaqueIdentifier ?? ""
        ].joined(separator: "|")
        let data = Data(revision.utf8)
        itemVersion = NSFileProviderItemVersion(contentVersion: data, metadataVersion: data)
        super.init()
    }

    init(rootName: String) {
        itemIdentifier = .rootContainer
        parentItemIdentifier = .rootContainer
        filename = rootName
        contentType = .folder
        documentSize = nil
        creationDate = nil
        contentModificationDate = nil
        capabilities = [.allowsReading, .allowsAddingSubItems]
        let data = Data("root".utf8)
        itemVersion = NSFileProviderItemVersion(contentVersion: data, metadataVersion: data)
        super.init()
    }
}

func fileProviderProgress() -> Progress {
    Progress(totalUnitCount: 100)
}

func fileProviderContentVersionMatches(_ lhs: NSFileProviderItemVersion, _ rhs: NSFileProviderItemVersion) -> Bool {
    lhs.contentVersion == rhs.contentVersion
}

func fileProviderVersionMatches(_ lhs: NSFileProviderItemVersion, _ rhs: NSFileProviderItemVersion) -> Bool {
    lhs.contentVersion == rhs.contentVersion && lhs.metadataVersion == rhs.metadataVersion
}

func bindCancellation(of progress: Progress, to task: Task<Void, Never>) {
    progress.cancellationHandler = { task.cancel() }
}
