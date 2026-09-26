import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private struct DomainContext {
        let profile: ConnectionProfile
        let codec: FileProviderPathCodec
        let identityStore: FileProviderIdentityStore
    }

    private let domain: NSFileProviderDomain
    /// Nil when the domain's connection profile is missing, e.g. the system
    /// launched the extension while the app was removing a deleted connection.
    /// The extension then stays alive and fails each request instead of
    /// crashing in `init`.
    private let context: DomainContext?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        if let profileID = UUID(uuidString: domain.identifier.rawValue),
           let profile = FileProviderProfileStore.load(profileID: profileID) {
            context = DomainContext(
                profile: profile,
                codec: FileProviderPathCodec(rootPath: profile.initialPath),
                identityStore: FileProviderIdentityStore(profileID: profileID)
            )
        } else {
            context = nil
        }
        super.init()
    }

    func invalidate() {}

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet || containerItemIdentifier == .trashContainer {
            return FileProviderEmptyEnumerator()
        }
        let context = try requireContext()
        return FileProviderEnumerator(profile: context.profile, containerIdentifier: containerItemIdentifier)
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = fileProviderProgress()
        let task = Task {
            do {
                let context = try requireContext()
                let codec = context.codec
                let identityStore = context.identityStore
                if identifier == .rootContainer {
                    completionHandler(FileProviderItem(rootName: context.profile.name), nil)
                } else {
                    let lease = try await FileProviderConnectionPool.shared.lease(for: context.profile)
                    defer { lease.release() }
                    let provider = lease.provider
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
                completionHandler(nil, FileProviderErrorMapping.map(error))
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
                let context = try requireContext()
                let codec = context.codec
                let identityStore = context.identityStore
                let lease = try await FileProviderConnectionPool.shared.lease(for: context.profile)
                defer { lease.release() }
                let provider = lease.provider
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
            } catch {
                completionHandler(nil, nil, FileProviderErrorMapping.map(error))
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
                let context = try requireContext()
                let codec = context.codec
                let identityStore = context.identityStore
                let lease = try await FileProviderConnectionPool.shared.lease(for: context.profile)
                defer { lease.release() }
                let provider = lease.provider
                let parentPath = try identityStore.path(for: itemTemplate.parentItemIdentifier, codec: codec)
                let path = try codec.childPath(parent: parentPath, filename: itemTemplate.filename)
                if itemTemplate.contentType?.conforms(to: .folder) == true {
                    do {
                        try await provider.createDirectory(path: path)
                    } catch let createError {
                        // Servers report an existing name with assorted errors.
                        // A folder that is already there is what the system
                        // asked for when it allows that; anything else there
                        // is a name collision the Files app can resolve.
                        guard let existing = try? await provider.attributes(path: path) else {
                            throw createError
                        }
                        guard existing.isDirectory, options.contains(.mayAlreadyExist) else {
                            throw NSFileProviderError(.filenameCollision)
                        }
                    }
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
                completionHandler(nil, fields, false, FileProviderErrorMapping.map(error))
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
                let context = try requireContext()
                let codec = context.codec
                let identityStore = context.identityStore
                let lease = try await FileProviderConnectionPool.shared.lease(for: context.profile)
                defer { lease.release() }
                let provider = lease.provider
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
                    try await RemoteFileOperations.replaceFile(at: path, with: newContents, provider: provider)
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
                completionHandler(nil, changedFields, false, FileProviderErrorMapping.map(error))
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
                let context = try requireContext()
                let codec = context.codec
                let identityStore = context.identityStore
                let lease = try await FileProviderConnectionPool.shared.lease(for: context.profile)
                defer { lease.release() }
                let provider = lease.provider
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
                // Without `.recursive` the system expects a non-empty folder
                // to be refused rather than deleted with everything inside.
                if remote.isDirectory, !options.contains(.recursive) {
                    let children = try await provider.list(path: path)
                    guard children.isEmpty else { throw NSFileProviderError(.directoryNotEmpty) }
                }
                try await RemoteFileOperations.removeRecursively(remote, provider: provider)
                try identityStore.remove(
                    identifier: identifier,
                    includingDescendantsOf: path
                )
                progress.completedUnitCount = 100
                completionHandler(nil)
            } catch {
                completionHandler(FileProviderErrorMapping.map(error))
            }
        }
        bindCancellation(of: progress, to: task)
        return progress
    }

    private func requireContext() throws -> DomainContext {
        guard let context else { throw NSFileProviderError(.providerNotFound) }
        return context
    }
}
