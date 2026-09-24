import Foundation
import Combine

enum UploadConflictResolution: Equatable, Sendable {
    case replace
    case keepBoth
    case skip
    case stop
}

struct UploadConflict: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let existingIsFolder: Bool
}

@MainActor
final class BrowserViewModel: ObservableObject {
    let profile: ConnectionProfile
    @Published private(set) var items: [RemoteItem] = []
    @Published private(set) var currentPath: String
    @Published private(set) var loading = false
    @Published private(set) var uploading = false
    @Published var errorMessage: String?
    @Published private(set) var pendingUploadConflict: UploadConflict?

    private(set) var provider: (any RemoteFileProvider)?
    /// Incremented for every directory load so a slow, superseded listing can
    /// never replace the contents of the folder the user navigated to later.
    private var listGeneration = 0
    private let makeProvider: (ConnectionProfile) throws -> any RemoteFileProvider
    private var conflictContinuation: CheckedContinuation<(resolution: UploadConflictResolution, applyToAll: Bool), Never>?

    init(
        profile: ConnectionProfile,
        startPath: String? = nil,
        makeProvider: @escaping (ConnectionProfile) throws -> any RemoteFileProvider = { try ProviderFactory.make(for: $0) }
    ) {
        self.profile = profile
        self.makeProvider = makeProvider
        currentPath = RemotePath.normalize(startPath ?? profile.initialPath)
    }

    var capabilities: ProviderCapabilities { provider?.capabilities ?? .readOnly }
    var canGoUp: Bool { currentPath != "/" }

    func start() async {
        guard provider == nil else { return }
        await refresh()
    }

    func refresh() async {
        listGeneration += 1
        let generation = listGeneration
        let path = currentPath
        loading = true
        defer {
            if generation == listGeneration { loading = false }
        }
        do {
            let listed = try await connectedProvider().list(path: path)
            guard generation == listGeneration else { return }
            items = listed
        } catch {
            guard generation == listGeneration, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func enter(_ item: RemoteItem) async {
        guard item.isDirectory else { return }
        navigate(to: item.path)
        await refresh()
    }

    /// Follows a symbolic link. A link to a folder is entered (keeping the
    /// link's path, which the server resolves); for anything else the
    /// resolved file is returned so the caller can open it.
    func openLink(_ item: RemoteItem) async -> RemoteItem? {
        guard let provider else { return nil }
        if item.linkTargetKind == .directory {
            await enter(RemoteItem(name: item.name, path: item.path, kind: .directory))
            return nil
        }
        do {
            let target = try await provider.attributes(path: item.path)
            var isFolder = target.isDirectory
            if target.kind == .symbolicLink {
                // Providers that report the link itself (FTP) cannot stat the
                // target; a listing that is not just the entry itself means
                // the link points to a folder.
                let children = try await provider.list(path: item.path)
                isFolder = !(children.count == 1 && children[0].name == item.name)
            }
            if isFolder {
                await enter(RemoteItem(name: item.name, path: item.path, kind: .directory))
                return nil
            }
            return RemoteItem(
                name: item.name,
                path: item.path,
                kind: .file,
                size: target.size ?? item.size,
                modifiedAt: target.modifiedAt ?? item.modifiedAt,
                createdAt: target.createdAt ?? item.createdAt,
                isHidden: item.isHidden,
                contentType: target.contentType,
                permissions: target.permissions ?? item.permissions,
                revision: target.revision
            )
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func goUp() async {
        guard canGoUp else { return }
        navigate(to: RemotePath.parent(currentPath))
        await refresh()
    }

    func createFolder(name: String) async {
        guard let name = validatedName(name) else {
            errorMessage = "The name must be a single path component and cannot be empty, '.', '..', contain '/', or contain a null character."
            return
        }
        guard let provider else { return }
        do {
            try await provider.createDirectory(path: RemotePath.join(currentPath, name))
            signalFilesApp(currentPath)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ item: RemoteItem) async {
        guard let provider else { return }
        loading = true
        defer { loading = false }
        do {
            try await RemoteFileOperations.removeRecursively(item, provider: provider)
            signalFilesApp(RemotePath.parent(item.path))
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ items: [RemoteItem]) async {
        guard let provider, !items.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            defer {
                for parent in Set(items.map { RemotePath.parent($0.path) }) { signalFilesApp(parent) }
            }
            for item in items {
                try Task.checkCancellation()
                try await RemoteFileOperations.removeRecursively(item, provider: provider)
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
        }
    }

    func rename(_ item: RemoteItem, to newName: String) async {
        guard let name = validatedName(newName) else {
            errorMessage = "The name must be a single path component and cannot be empty, '.', '..', contain '/', or contain a null character."
            return
        }
        guard let provider else { return }
        guard name != item.name else { return }
        do {
            try await provider.move(
                from: item.path,
                to: RemotePath.join(RemotePath.parent(item.path), name),
                overwrite: false
            )
            signalFilesApp(RemotePath.parent(item.path))
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func paste(_ clipboard: FileOperationClipboard, using connections: ConnectionStore, transfers: TransferEngine) async {
        guard let destination = provider,
              let operation = clipboard.operation,
              let sourceProfileID = clipboard.sourceProfileID,
              !clipboard.items.isEmpty else { return }

        guard let sourceProfile = connections.profiles.first(where: { $0.id == sourceProfileID }) else {
            errorMessage = "The source connection no longer exists."
            return
        }

        loading = true
        defer { loading = false }

        let sameProfile = sourceProfileID == profile.id
        let targetDirectory = RemotePath.normalize(currentPath)
        let items = clipboard.items
        do {
            if sameProfile {
                for item in items where item.isDirectory {
                    if RemoteFileOperations.wouldPlaceDirectoryInsideItself(
                        sourcePath: item.path,
                        destinationParent: targetDirectory
                    ) {
                        throw RemoteProviderError.invalidConfiguration("A folder cannot be pasted inside itself.")
                    }
                }
            }

            var completed = true
            if operation == .move, sameProfile {
                // A move within one server is a rename; nothing is transferred.
                for item in items {
                    try Task.checkCancellation()
                    guard RemotePath.parent(item.path) != targetDirectory else { continue }
                    let target = try await RemoteFileOperations.availablePastePath(
                        for: item,
                        in: targetDirectory,
                        provider: destination
                    )
                    try await destination.move(from: item.path, to: target, overwrite: false)
                }
            } else {
                // Copies (and cross-server moves) run through the transfer
                // queue so every file shows progress and can be paused,
                // cancelled or retried from the Transfers tab.
                completed = try await transfers.copyItems(
                    items,
                    from: sourceProfile,
                    to: profile,
                    destinationDirectory: targetDirectory,
                    removeSources: operation == .move
                )
            }

            signalFilesApp(targetDirectory)
            if operation == .move {
                for parent in Set(items.map { RemotePath.parent($0.path) }) {
                    FileProviderDomainManager.signalChange(in: parent, profile: sourceProfile)
                }
            }
            if operation == .move, completed { clipboard.clear() }
            if !completed {
                errorMessage = String(localized: "Some items were not copied. See Transfers for details and to retry them.")
            }
            await refresh()
        } catch is CancellationError {
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
        }
    }

    func upload(localURLs: [URL], transfers: TransferEngine) async {
        guard let provider else { return }
        uploading = true
        defer { uploading = false }

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesImports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let targetDirectory = currentPath
        var batch = UploadBatch()

        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stagingRoot) }

            for url in localURLs {
                let stagedURL = try await Task.detached(priority: .userInitiated) {
                    try Self.stageImportedURL(url, under: stagingRoot)
                }.value
                try await uploadRecursively(
                    localURL: stagedURL,
                    remoteParent: targetDirectory,
                    provider: provider,
                    transfers: transfers,
                    batch: &batch
                )
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
        signalFilesApp(targetDirectory)
        if batch.failedFiles > 0, errorMessage == nil {
            errorMessage = String(
                localized: "\(batch.failedFiles) file(s) could not be uploaded. Retry them from Transfers."
            )
        }
        await refresh()
    }

    /// Called by the view when the user answers the name-conflict prompt.
    func resolveUploadConflict(_ resolution: UploadConflictResolution, applyToAll: Bool) {
        guard let continuation = conflictContinuation else { return }
        conflictContinuation = nil
        pendingUploadConflict = nil
        continuation.resume(returning: (resolution, applyToAll))
    }

    func stop() async {
        await provider?.disconnect()
    }

    private func signalFilesApp(_ directory: String) {
        FileProviderDomainManager.signalChange(in: directory, profile: profile)
    }

    private func navigate(to path: String) {
        currentPath = path
        // Never show the previous folder's rows under the new path while the
        // listing loads; actions on them would be applied to the wrong folder.
        items = []
    }

    /// Returns the connected provider, creating it on first use or after a
    /// failed initial connection so pull-to-refresh can recover.
    private func connectedProvider() async throws -> any RemoteFileProvider {
        if let provider { return provider }
        let provider = try makeProvider(profile)
        try await provider.connect()
        if let existing = self.provider {
            // Another refresh finished connecting while this one was waiting.
            await provider.disconnect()
            return existing
        }
        self.provider = provider
        return provider
    }

    private func validatedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\0") else {
            return nil
        }
        return trimmed
    }

    private struct UploadBatch {
        var rememberedResolution: UploadConflictResolution?
        var failedFiles = 0
    }

    private func uploadRecursively(
        localURL: URL,
        remoteParent: String,
        provider: any RemoteFileProvider,
        transfers: TransferEngine,
        batch: inout UploadBatch
    ) async throws {
        let values = try localURL.resourceValues(forKeys: [.isDirectoryKey])
        var remotePath = RemotePath.join(remoteParent, localURL.lastPathComponent)
        if values.isDirectory == true {
            // Existing folders are merged; name conflicts are resolved per file.
            do {
                try await provider.createDirectory(path: remotePath)
            } catch {
                let existing = try? await provider.attributes(path: remotePath)
                guard existing?.isDirectory == true else { throw error }
            }
            let children = try FileManager.default.contentsOfDirectory(
                at: localURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
            for child in children {
                try Task.checkCancellation()
                try await uploadRecursively(
                    localURL: child,
                    remoteParent: remotePath,
                    provider: provider,
                    transfers: transfers,
                    batch: &batch
                )
            }
            return
        }

        var overwrite = false
        if let existing = try await existingItem(at: remotePath, provider: provider) {
            let resolution: UploadConflictResolution
            if let remembered = batch.rememberedResolution {
                resolution = remembered
            } else {
                let answer = await askForConflictResolution(
                    UploadConflict(name: localURL.lastPathComponent, existingIsFolder: existing.isDirectory)
                )
                resolution = answer.resolution
                if answer.applyToAll { batch.rememberedResolution = resolution }
            }
            switch resolution {
            case .stop:
                throw CancellationError()
            case .skip:
                return
            case .keepBoth:
                remotePath = try await RemoteFileOperations.availablePastePath(
                    for: RemoteItem(name: localURL.lastPathComponent, path: remotePath, kind: .file),
                    in: remoteParent,
                    provider: provider
                )
            case .replace:
                guard !existing.isDirectory else {
                    throw RemoteProviderError.conflict("A folder named \(existing.name) already exists and cannot be replaced by a file.")
                }
                overwrite = true
            }
        }

        do {
            try await transfers.uploadFile(
                localURL: localURL,
                to: provider,
                destinationPath: remotePath,
                overwrite: overwrite,
                retainForRetry: true
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Keep going with the rest of the batch; the failed file stays in
            // the transfer list with a Retry action.
            batch.failedFiles += 1
        }
    }

    private func existingItem(at path: String, provider: any RemoteFileProvider) async throws -> RemoteItem? {
        do {
            return try await provider.attributes(path: path)
        } catch {
            guard RemoteProviderError.isNotFound(error) else { throw error }
            return nil
        }
    }

    private func askForConflictResolution(
        _ conflict: UploadConflict
    ) async -> (resolution: UploadConflictResolution, applyToAll: Bool) {
        await withCheckedContinuation { continuation in
            conflictContinuation = continuation
            pendingUploadConflict = conflict
        }
    }

    private nonisolated static func stageImportedURL(_ sourceURL: URL, under stagingRoot: URL) throws -> URL {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if access { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let container = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let destination = container.appendingPathComponent(sourceURL.lastPathComponent)

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: sourceURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try FileManager.default.copyItem(at: coordinatedURL, to: destination)
            } catch {
                copyError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        return destination
    }
}
