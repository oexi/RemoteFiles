import FileProvider
import Foundation
import UniformTypeIdentifiers

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

    init(
        remote: RemoteItem,
        codec: FileProviderPathCodec,
        identityStore: FileProviderIdentityStore,
        providerCapabilities: ProviderCapabilities
    ) throws {
        itemIdentifier = try identityStore.identifier(for: remote.path, codec: codec)
        parentItemIdentifier = try identityStore.identifier(
            for: RemotePath.parent(remote.path),
            codec: codec
        )
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
