import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let profile: ConnectionProfile
    private let codec: FileProviderPathCodec

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        guard let profile = ConnectionProfile(
            fileProviderDomainIdentifier: domain.identifier.rawValue,
            userInfo: domain.userInfo
        ) else {
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
                    let path = try codec.path(for: identifier)
                    let remote = try await provider.attributes(path: path)
                    await provider.disconnect()
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
        Task {
            do {
                let provider = try await connectedProvider()
                let path = try codec.path(for: itemIdentifier)
                let remote = try await provider.attributes(path: path)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("RemoteFiles-FP-\(UUID().uuidString)-\(remote.name)")
                try await provider.download(path: path, to: url)
                await provider.disconnect()
                progress.completedUnitCount = 100
                completionHandler(url, FileProviderItem(remote: remote, codec: codec, providerCapabilities: provider.capabilities), nil)
            } catch {
                completionHandler(nil, nil, error)
            }
        }
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
                let parentPath = try codec.path(for: itemTemplate.parentItemIdentifier)
                let path = RemotePath.join(parentPath, itemTemplate.filename)
                if itemTemplate.contentType.conforms(to: .folder) {
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
                await provider.disconnect()
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
        Task {
            do {
                let provider = try await connectedProvider()
                var path = try codec.path(for: item.itemIdentifier)
                let desiredParent = try codec.path(for: item.parentItemIdentifier)
                let desiredPath = RemotePath.join(desiredParent, item.filename)
                if desiredPath != path {
                    try await provider.move(from: path, to: desiredPath, overwrite: false)
                    path = desiredPath
                }
                if let newContents {
                    try await provider.upload(from: newContents, to: path, overwrite: true)
                }
                let remote = try await provider.attributes(path: path)
                await provider.disconnect()
                progress.completedUnitCount = 100
                completionHandler(FileProviderItem(remote: remote, codec: codec, providerCapabilities: provider.capabilities), [], false, nil)
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
                let path = try codec.path(for: identifier)
                let remote = try await provider.attributes(path: path)
                try await provider.remove(path: path, isDirectory: remote.isDirectory)
                await provider.disconnect()
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
