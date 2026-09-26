import Foundation
import Combine

enum UploadConflictResolution: Equatable, Sendable {
    /// Overwrites an existing file, or merges an uploaded folder into an
    /// existing folder of the same name.
    case replace
    case keepBoth
    case skip
    case stop
}

struct UploadConflict: Identifiable, Equatable {
    let id = UUID()
    let name: String
    /// Whether the item being uploaded is a folder.
    let isFolder: Bool
    let existingIsFolder: Bool
    /// Whether more items of the same kind are still to be uploaded in this
    /// batch, so an "… All" answer means something.
    let canApplyToAll: Bool

    /// Replace (or merge, for two folders) only makes sense between items of
    /// the same kind; a file never replaces a folder or the other way round.
    var canReplace: Bool { isFolder == existingIsFolder }
}

@MainActor
final class BrowserViewModel: ObservableObject {
    let profile: ConnectionProfile
    @Published private(set) var items: [RemoteItem] = []
    @Published private(set) var currentPath: String
    @Published private(set) var loading = false
    @Published private var activeUploads = 0
    @Published var errorMessage: String?
    @Published private(set) var pendingUploadConflict: UploadConflict?

    private(set) var provider: (any RemoteFileProvider)?
    /// Incremented for every directory load so a slow, superseded listing can
    /// never replace the contents of the folder the user navigated to later.
    private var listGeneration = 0
    private let makeProvider: (ConnectionProfile) throws -> any RemoteFileProvider
    private var conflictContinuation: CheckedContinuation<(resolution: UploadConflictResolution, applyToAll: Bool), Never>?
    /// Uploads started while another one is asking about a conflict wait here
    /// for their turn, so no prompt (and no waiting upload) is ever dropped.
    private var conflictPromptBusy = false
    private var conflictPromptWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastConflictAnsweredAt: ContinuousClock.Instant?

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
    var uploading: Bool { activeUploads > 0 }
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
        activeUploads += 1
        defer { activeUploads -= 1 }

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesImports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let targetDirectory = currentPath
        var batch = UploadBatch()
        transfers.beginBatch()
        defer { transfers.endBatch() }

        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stagingRoot) }

            let staged = try await Task.detached(priority: .userInitiated) {
                try localURLs.map { try Self.stageImportedURL($0, under: stagingRoot) }
            }.value
            let counts = try await Task.detached(priority: .userInitiated) {
                try Self.entryCounts(staged)
            }.value
            batch.pendingFiles = counts.files
            batch.pendingFolders = counts.folders

            // Every question is asked and every folder created first, so the
            // files can then be sent several at a time without prompts
            // interrupting the transfers.
            var contents: RemoteFolderContents? = try await folderContents(at: targetDirectory, provider: provider)
            for url in staged {
                try Task.checkCancellation()
                try await planUpload(
                    localURL: url,
                    remoteParent: targetDirectory,
                    parentContents: &contents,
                    provider: provider,
                    batch: &batch
                )
            }
            batch.failedFiles = try await performUploads(batch.uploads, provider: provider, transfers: transfers)
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
        lastConflictAnsweredAt = ContinuousClock.now
        continuation.resume(returning: (resolution, applyToAll))
    }

    /// Called when the prompt for `id` was dismissed without a button (for
    /// example by tapping outside it). A dismissal that arrives after the
    /// prompt was answered, or after the next prompt replaced it, is ignored.
    func dismissUploadConflict(id: UploadConflict.ID) {
        guard pendingUploadConflict?.id == id else { return }
        resolveUploadConflict(.stop, applyToAll: false)
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
        var fileResolution: UploadConflictResolution?
        var folderResolution: UploadConflictResolution?
        /// Files and folders not handled yet that could still meet a name
        /// conflict. Items inside a folder this upload creates cannot.
        var pendingFiles = 0
        var pendingFolders = 0
        var uploads: [PlannedUpload] = []
        var failedFiles = 0

        mutating func discount(_ counts: (files: Int, folders: Int)) {
            pendingFiles = max(0, pendingFiles - counts.files)
            pendingFolders = max(0, pendingFolders - counts.folders)
        }
    }

    /// The items of a destination folder, listed once per folder instead of
    /// one stat per uploaded item. `nil` stands for a folder this upload just
    /// created, where nothing can conflict.
    private struct RemoteFolderContents {
        private var items: [String: RemoteItem] = [:]
        private var lowercasedNames: Set<String> = []

        init(_ listed: [RemoteItem]) {
            for item in listed { insert(item) }
        }

        func item(named name: String) -> RemoteItem? { items[name] }

        func mayContain(caseInsensitive name: String) -> Bool {
            lowercasedNames.contains(name.lowercased())
        }

        mutating func insert(_ item: RemoteItem) {
            items[item.name] = item
            lowercasedNames.insert(item.name.lowercased())
        }
    }

    private struct PlannedUpload: Sendable {
        let localURL: URL
        let remotePath: String
        let overwrite: Bool
    }

    /// Resolves the name conflicts for `localURL` and creates its folders;
    /// files are only queued in `batch.uploads`.
    private func planUpload(
        localURL: URL,
        remoteParent: String,
        parentContents: inout RemoteFolderContents?,
        provider: any RemoteFileProvider,
        batch: inout UploadBatch
    ) async throws {
        let isFolder = try localURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let name = localURL.lastPathComponent
        var remotePath = RemotePath.join(remoteParent, name)
        if isFolder {
            batch.pendingFolders = max(0, batch.pendingFolders - 1)
        } else {
            batch.pendingFiles = max(0, batch.pendingFiles - 1)
        }

        var overwrite = false
        var merge = false
        if let existing = try await existingItem(
            named: name,
            in: parentContents,
            parent: remoteParent,
            provider: provider
        ) {
            switch await conflictResolution(for: name, isFolder: isFolder, existing: existing, batch: &batch) {
            case .stop:
                throw CancellationError()
            case .skip:
                if isFolder {
                    let skipped = try await Self.descendantCounts(of: localURL)
                    batch.discount(skipped)
                }
                return
            case .keepBoth:
                remotePath = try await RemoteFileOperations.availablePastePath(
                    for: RemoteItem(name: name, path: remotePath, kind: isFolder ? .directory : .file),
                    in: remoteParent,
                    provider: provider
                )
            case .replace:
                if isFolder { merge = true } else { overwrite = true }
            }
        }

        guard isFolder else {
            batch.uploads.append(PlannedUpload(localURL: localURL, remotePath: remotePath, overwrite: overwrite))
            // A second picked item with the same name now meets this one.
            parentContents?.insert(RemoteItem(name: (remotePath as NSString).lastPathComponent, path: remotePath, kind: .file))
            return
        }

        var contents: RemoteFolderContents?
        if merge {
            contents = try await folderContents(at: remotePath, provider: provider)
        } else {
            var created = false
            do {
                try await provider.createDirectory(path: remotePath)
                created = true
            } catch {
                // The folder appeared since the listing (or the listing missed
                // it): merge into it, asking about files that already exist.
                let existing = try? await provider.attributes(path: remotePath)
                guard existing?.isDirectory == true else { throw error }
                contents = try await folderContents(at: remotePath, provider: provider)
            }
            if created {
                // Nothing inside a new folder can conflict.
                let unconflicted = try await Self.descendantCounts(of: localURL)
                batch.discount(unconflicted)
            }
            parentContents?.insert(RemoteItem(name: (remotePath as NSString).lastPathComponent, path: remotePath, kind: .directory))
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: localURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        for child in children {
            try Task.checkCancellation()
            try await planUpload(
                localURL: child,
                remoteParent: remotePath,
                parentContents: &contents,
                provider: provider,
                batch: &batch
            )
        }
    }

    /// Sends the planned files, a few at a time on protocols whose provider
    /// handles concurrent requests on one connection. Returns how many
    /// failed; those stay in the transfer list with a Retry action.
    private func performUploads(
        _ uploads: [PlannedUpload],
        provider: any RemoteFileProvider,
        transfers: TransferEngine
    ) async throws -> Int {
        enum Outcome: Sendable { case uploaded, failed, cancelled }
        let limit = Self.uploadConcurrency(for: profile.protocolType)
        var failed = 0
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            var next = 0
            var running = 0
            while true {
                while next < uploads.count, running < limit {
                    let upload = uploads[next]
                    next += 1
                    running += 1
                    group.addTask {
                        do {
                            try await transfers.uploadFile(
                                localURL: upload.localURL,
                                to: provider,
                                destinationPath: upload.remotePath,
                                overwrite: upload.overwrite,
                                retainForRetry: true
                            )
                            return .uploaded
                        } catch is CancellationError {
                            return .cancelled
                        } catch {
                            return .failed
                        }
                    }
                }
                guard let outcome = try await group.next() else { break }
                running -= 1
                switch outcome {
                case .uploaded: break
                case .failed: failed += 1
                case .cancelled: throw CancellationError()
                }
            }
        }
        return failed
    }

    static func uploadConcurrency(for protocolType: RemoteProtocol) -> Int {
        switch protocolType {
        case .sftp, .webdav:
            // These providers multiplex concurrent requests over one session.
            return 3
        case .smb:
            // SMBClient hands out message IDs and credits without locking or
            // tracking the server's credit grant; parallel 8 MB writes made
            // the server drop the connection and fail every file in flight.
            return 1
        case .ftp, .ftps, .nfs:
            return 1
        }
    }

    private func folderContents(at path: String, provider: any RemoteFileProvider) async throws -> RemoteFolderContents {
        RemoteFolderContents(try await provider.list(path: path))
    }

    private func existingItem(
        named name: String,
        in contents: RemoteFolderContents?,
        parent: String,
        provider: any RemoteFileProvider
    ) async throws -> RemoteItem? {
        guard let contents else { return nil }
        if let item = contents.item(named: name) { return item }
        // Case-insensitive servers (SMB, most NAS shares) treat "A.txt" and
        // "a.txt" as one name; only the server can tell whether they clash.
        guard contents.mayContain(caseInsensitive: name) else { return nil }
        return try await existingItem(at: RemotePath.join(parent, name), provider: provider)
    }

    private func existingItem(at path: String, provider: any RemoteFileProvider) async throws -> RemoteItem? {
        do {
            return try await provider.attributes(path: path)
        } catch {
            guard RemoteProviderError.isNotFound(error) else { throw error }
            return nil
        }
    }

    private func conflictResolution(
        for name: String,
        isFolder: Bool,
        existing: RemoteItem,
        batch: inout UploadBatch
    ) async -> UploadConflictResolution {
        let conflict = UploadConflict(
            name: name,
            isFolder: isFolder,
            existingIsFolder: existing.isDirectory,
            canApplyToAll: isFolder ? batch.pendingFolders > 0 : batch.pendingFiles > 0
        )
        // An "… All" answer is reused only where it applies: "Replace All"
        // for files does not decide a file that meets a folder.
        let remembered = isFolder ? batch.folderResolution : batch.fileResolution
        if let remembered, remembered != .replace || conflict.canReplace {
            return remembered
        }
        let answer = await askForConflictResolution(conflict)
        if answer.applyToAll {
            if isFolder { batch.folderResolution = answer.resolution } else { batch.fileResolution = answer.resolution }
        }
        return answer.resolution
    }

    private func askForConflictResolution(
        _ conflict: UploadConflict
    ) async -> (resolution: UploadConflictResolution, applyToAll: Bool) {
        if conflictPromptBusy {
            await withCheckedContinuation { conflictPromptWaiters.append($0) }
        } else {
            conflictPromptBusy = true
        }
        defer {
            if conflictPromptWaiters.isEmpty {
                conflictPromptBusy = false
            } else {
                conflictPromptWaiters.removeFirst().resume()
            }
        }
        // SwiftUI drops a dialog that is presented while the previous one is
        // still animating away, which left the upload waiting for an answer
        // to a prompt nobody could see. Give the last one time to go.
        if let lastConflictAnsweredAt {
            let settle = Duration.milliseconds(500) - (ContinuousClock.now - lastConflictAnsweredAt)
            if settle > .zero { try? await Task.sleep(for: settle) }
        }
        return await withCheckedContinuation { continuation in
            conflictContinuation = continuation
            pendingUploadConflict = conflict
        }
    }

    private nonisolated static func entryCounts(_ urls: [URL]) throws -> (files: Int, folders: Int) {
        var files = 0
        var folders = 0
        for url in urls {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                let below = try descendantCountsSync(of: url)
                files += below.files
                folders += below.folders + 1
            } else {
                files += 1
            }
        }
        return (files, folders)
    }

    private nonisolated static func descendantCounts(of folder: URL) async throws -> (files: Int, folders: Int) {
        try await Task.detached(priority: .userInitiated) {
            try descendantCountsSync(of: folder)
        }.value
    }

    private nonisolated static func descendantCountsSync(of folder: URL) throws -> (files: Int, folders: Int) {
        var files = 0
        var folders = 0
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return (0, 0) }
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                folders += 1
            } else {
                files += 1
            }
        }
        return (files, folders)
    }

    private nonisolated static func isAppTemporaryFile(_ url: URL) -> Bool {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(temporary.hasSuffix("/") ? temporary : temporary + "/")
    }

    private nonisolated static func stageImportedURL(_ sourceURL: URL, under stagingRoot: URL) throws -> URL {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if access { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let container = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let destination = container.appendingPathComponent(sourceURL.lastPathComponent)

        // "Upload Files" opens the picker in copy mode, which already put a
        // private copy in the app's temporary folder. Take that copy over
        // instead of duplicating a possibly large file before uploading.
        if isAppTemporaryFile(sourceURL) {
            try FileManager.default.moveItem(at: sourceURL, to: destination)
            return destination
        }

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
