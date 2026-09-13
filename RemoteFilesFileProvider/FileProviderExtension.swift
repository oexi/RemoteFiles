import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let profile: ConnectionProfile
    private let codec: FileProviderPathCodec

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        guard let profileID = UUID(uuidString: domain.identifier.rawValue),
              let profile = FileProviderProfileStore.load(profileID: profileID) else {
            fatalError("Invalid RemoteFiles File Provider domain")
        }
        self.profile = profile
        codec = FileProviderPathCodec(rootPath: profile.initialPath)
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
        Task {
            do {
                if identifier == .rootContainer {
                    completionHandler(FileProviderItem(rootName: profile.name), nil)
                } else {
                    let provider = try await connectedProvider()
                    defer { Task { await provider.disconnect() } }
                    let path = try codec.path(for: identifier)
                    let remote = try await provider.attributes(path: path)
                    completionHandler(FileProviderItem(remote: remote, codec: codec, providerCapabilities: provider.capabilities), nil)
                }
                progress.completedUnitCount = 100
            } catch {
                completionHandler(nil, error)
            }
        }
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
                let path = try codec.path(for: itemIdentifier)
                let remote = try await provider.attributes(path: path)
                let initialItem = FileProviderItem(remote: remote, codec: codec, providerCapabilities: provider.capabilities)
                if let requestedVersion,
                   !fileProviderContentVersionMatches(initialItem.itemVersion, requestedVersion) {
                    throw NSFileProviderError(.versionNoLongerAvailable)
                }
                let directory = try NSFileProviderManager(for: domain)?.temporaryDirectoryURL()
                    ?? FileManager.default.temporaryDirectory
                let url = directory.appendingPathComponent("RemoteFiles-FP-\(UUID().uuidString)-\(remote.name)")
                temporaryURL = url
                try await provider.download(path: path, to: url)
                try Task.checkCancellation()
                let confirmedRemote = try await provider.attributes(path: path)
                try Task.checkCancellation()
                let confirmedItem = FileProviderItem(remote: confirmedRemote, codec: codec, providerCapabilities: provider.capabilities)
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
        Task {
            do {
                let provider = try await connectedProvider()
                defer { Task { await provider.disconnect() } }
                let parentPath = try codec.path(for: itemTemplate.parentItemIdentifier)
                let path = RemotePath.join(parentPath, itemTemplate.filename)
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
                completionHandler(FileProviderItem(remote: remote, codec: codec, providerCapabilities: provider.capabilities), [], false, nil)
            } catch {
                completionHandler(nil, fields, false, error)
            }
        }
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
        Task {
            do {
                let provider = try await connectedProvider()
                defer { Task { await provider.disconnect() } }
                var path = try codec.path(for: item.itemIdentifier)
                let currentRemote = try await provider.attributes(path: path)
                let currentItem = FileProviderItem(remote: currentRemote, codec: codec, providerCapabilities: provider.capabilities)
                if options.contains(.failOnConflict),
                   !fileProviderVersionMatches(currentItem.itemVersion, version) {
                    throw NSFileProviderError(.cannotSynchronize)
                }
                let desiredParent = try codec.path(for: item.parentItemIdentifier)
                let desiredPath = RemotePath.join(desiredParent, item.filename)
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier),
                   desiredPath != path {
                    try await provider.move(from: path, to: desiredPath, overwrite: false)
                    path = desiredPath
                }
                if changedFields.contains(.contents), let newContents {
                    try await provider.upload(from: newContents, to: path, overwrite: true)
                }
                let remote = try await provider.attributes(path: path)
                progress.completedUnitCount = 100
                completionHandler(FileProviderItem(remote: remote, codec: codec, providerCapabilities: provider.capabilities), pendingFields, false, nil)
            } catch {
                completionHandler(nil, changedFields, false, error)
            }
        }
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
        Task {
            do {
                let provider = try await connectedProvider()
                defer { Task { await provider.disconnect() } }
                let path = try codec.path(for: identifier)
                let remote = try await provider.attributes(path: path)
                let currentItem = FileProviderItem(remote: remote, codec: codec, providerCapabilities: provider.capabilities)
                guard fileProviderVersionMatches(currentItem.itemVersion, version) else {
                    throw NSFileProviderError(.cannotSynchronize)
                }
                try await RemoteFileOperations.removeRecursively(remote, provider: provider)
                progress.completedUnitCount = 100
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
        return progress
    }

    private func connectedProvider() async throws -> any RemoteFileProvider {
        let credential = try CredentialVault.shared.load(for: profile.id)
        let provider = try ProviderFactory.make(for: profile, credential: credential)
        try await provider.connect()
        return provider
    }
}
