import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let profile: ConnectionProfile
    private let codec: FileProviderPathCodec
    private let identityStore: FileProviderIdentityStore

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        guard let profileID = UUID(uuidString: domain.identifier.rawValue),
              let profile = FileProviderProfileStore.load(profileID: profileID) else {
            fatalError("Invalid RemoteFiles File Provider domain")
        }
        self.profile = profile
        codec = FileProviderPathCodec(rootPath: profile.initialPath)
        identityStore = FileProviderIdentityStore(profileID: profileID)
        super.init()
    }

    func invalidate() {}

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        FileProviderEnumerator(profile: profile, containerIdentifier: containerItemIdentifier)
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = fileProviderProgress()
        let task = Task {
            do {
                if identifier == .rootContainer {
                    completionHandler(FileProviderItem(rootName: profile.name), nil)
                } else {
                    let provider = try await connectedProvider()
                    defer { Task { await provider.disconnect() } }
                    let path = try identityStore.path(for: identifier, codec: codec)
                    let remote = try await provider.attributes(path: path)
                    completionHandler(
                        try FileProviderItem(
                            remote: remote,
                            codec: codec,
                            identityStore: identityStore,
                            providerCapabilities: provider.capabilities
                        ),
                        nil
                    )
                }
                progress.completedUnitCount = 100
            } catch {
                completionHandler(nil, error)
            }
        }
        bindCancellation(of: progress, to: task)
        return progress
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = fileProviderProgress()
        let task = Task {
            var temporaryURL: URL?
            var keepTemporaryURL = false
            defer {
                if !keepTemporaryURL, let temporaryURL {
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
            }
            do {
                let provider = try await connectedProvider()
                defer { Task { await provider.disconnect() } }
                let path = try identityStore.path(for: itemIdentifier, codec: codec)
                let remote = try await provider.attributes(path: path)
                let initialItem = try FileProviderItem(
                    remote: remote,
                    codec: codec,
                    identityStore: identityStore,
                    providerCapabilities: provider.capabilities
                )
                if let requestedVersion,
                   !fileProviderContentVersionMatches(initialItem.itemVersion, requestedVersion) {
                    throw NSFileProviderError(.cannotSynchronize)
                }
                let directory = try NSFileProviderManager(for: domain)?.temporaryDirectoryURL()
                    ?? FileManager.default.temporaryDirectory
                let url = directory.appendingPathComponent("RemoteFiles-FP-\(UUID().uuidString)-\(remote.name)")
                temporaryURL = url
                try await provider.download(path: path, to: url)
                try Task.checkCancellation()
                let confirmedRemote = try await provider.attributes(path: path)
                try Task.checkCancellation()
                let confirmedItem = try FileProviderItem(
                    remote: confirmedRemote,
                    codec: codec,
                    identityStore: identityStore,
                    providerCapabilities: provider.capabilities
                )
                guard fileProviderContentVersionMatches(initialItem.itemVersion, confirmedItem.itemVersion) else {
                    try? FileManager.default.removeItem(at: url)
                    throw NSFileProviderError(.cannotSynchronize)
                }
                progress.completedUnitCount = 100
                keepTemporaryURL = true
                completionHandler(url, confirmedItem, nil)
            } catch is CancellationError {
                completionHandler(nil, nil, CocoaError(.userCancelled))
            } catch {
                completionHandler(nil, nil, error)
            }
        }
        bindCancellation(of: progress, to: task)
        return progress
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = fileProviderProgress()
        let task = Task {
            do {
                let provider = try await connectedProvider()
                defer { Task { await provider.disconnect() } }
                let parentPath = try identityStore.path(for: itemTemplate.parentItemIdentifier, codec: codec)
                let path = try codec.childPath(parent: parentPath, filename: itemTemplate.filename)
                if itemTemplate.contentType?.conforms(to: .folder) == true {
                    try await provider.createDirectory(path: path)
                } else if let url {
                    try await provider.upload(from: url, to: path, overwrite: options.contains(.mayAlreadyExist))
                } else {
                    let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try Data().write(to: empty)
                    defer { try? FileManager.default.removeItem(at: empty) }
                    try await provider.upload(from: empty, to: path, overwrite: options.contains(.mayAlreadyExist))
                }
                let remote = try await provider.attributes(path: path)
                progress.completedUnitCount = 100
                completionHandler(
                    try FileProviderItem(
                        remote: remote,
                        codec: codec,
                        identityStore: identityStore,
                        providerCapabilities: provider.capabilities
                    ),
                    [],
                    false,
                    nil
                )
            } catch {
                completionHandler(nil, fields, false, error)
            }
        }
        bindCancellation(of: progress, to: task)
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = fileProviderProgress()
        let appliedFields: NSFileProviderItemFields = [.filename, .parentItemIdentifier, .contents]
        let pendingFields = changedFields.subtracting(appliedFields)
        let task = Task {
            do {
                let provider = try await connectedProvider()
                defer { Task { await provider.disconnect() } }
                var path = try identityStore.path(for: item.itemIdentifier, codec: codec)
                let currentRemote = try await provider.attributes(path: path)
                let currentItem = try FileProviderItem(
                    remote: currentRemote,
                    codec: codec,
                    identityStore: identityStore,
                    providerCapabilities: provider.capabilities
                )
                if #available(iOS 26.0, *),
                   options.contains(.failOnConflict),
                   !fileProviderVersionMatches(currentItem.itemVersion, version) {
                    throw NSFileProviderError(.cannotSynchronize)
                }
                let desiredParent = try identityStore.path(for: item.parentItemIdentifier, codec: codec)
                let desiredPath = try codec.childPath(parent: desiredParent, filename: item.filename)
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier),
                   desiredPath != path {
                    try await provider.move(from: path, to: desiredPath, overwrite: false)
                    try identityStore.relocate(
                        identifier: item.itemIdentifier,
                        from: path,
                        to: desiredPath,
                        codec: codec
                    )
                    path = desiredPath
                }
                if changedFields.contains(.contents), let newContents {
                    try await provider.upload(from: newContents, to: path, overwrite: true)
                }
                let remote = try await provider.attributes(path: path)
                progress.completedUnitCount = 100
                completionHandler(
                    try FileProviderItem(
                        remote: remote,
                        codec: codec,
                        identityStore: identityStore,
                        providerCapabilities: provider.capabilities
                    ),
                    pendingFields,
                    false,
                    nil
                )
            } catch {
                completionHandler(nil, changedFields, false, error)
            }
        }
        bindCancellation(of: progress, to: task)
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = fileProviderProgress()
        let task = Task {
            do {
                let provider = try await connectedProvider()
                defer { Task { await provider.disconnect() } }
                let path = try identityStore.path(for: identifier, codec: codec)
                let remote = try await provider.attributes(path: path)
                let currentItem = try FileProviderItem(
                    remote: remote,
                    codec: codec,
                    identityStore: identityStore,
                    providerCapabilities: provider.capabilities
                )
                guard fileProviderVersionMatches(currentItem.itemVersion, version) else {
                    throw NSFileProviderError(.cannotSynchronize)
                }
                try await RemoteFileOperations.removeRecursively(remote, provider: provider)
                try identityStore.remove(
                    identifier: identifier,
                    includingDescendantsOf: path
                )
                progress.completedUnitCount = 100
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
        bindCancellation(of: progress, to: task)
        return progress
    }

    private func connectedProvider() async throws -> any RemoteFileProvider {
        let credential = try CredentialVault.shared.load(for: profile.id)
        let provider = try ProviderFactory.make(for: profile, credential: credential)
        try await provider.connect()
        return provider
    }
}
