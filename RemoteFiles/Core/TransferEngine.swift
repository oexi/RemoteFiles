import Foundation
import Combine

private struct TransferPausedError: Error, Sendable { }

@MainActor
final class TransferEngine: ObservableObject {
    @Published private(set) var records: [TransferRecord] = []
    private struct ActiveTask {
        let token: TransferExecutionToken
        let task: Task<Void, Never>
    }

    private struct ProgressSnapshot {
        let token: TransferExecutionToken
        let transferredBytes: UInt64
        let progress: Double
        let bytesPerSecond: Double?
        var lastPublishedAt: Date
        var lastPublishedBytes: UInt64
    }

    // A larger bounded buffer amortizes protocol round trips without retaining the
    // whole file in memory. Providers may still return a shorter buffer.
    private static let transferChunkSize = 4 * 1024 * 1024
    private static let progressUpdateInterval: TimeInterval = 0.2
    private static let progressUpdateBytes: UInt64 = 512 * 1024
    private static let progressByteUpdateInterval: TimeInterval = 0.05
    private static let progressPersistenceDelay: UInt64 = 750_000_000

    private var tasks: [UUID: ActiveTask] = [:]
    private var executionOwnership: [UUID: TransferExecutionOwnership] = [:]
    private var pendingRetries: [UUID: ConnectionStore] = [:]
    private var pauseRequests: Set<UUID> = []
    private var committing: Set<UUID> = []
    private var finalizedTransfers: Set<UUID> = []
    private var progressSnapshots: [UUID: ProgressSnapshot] = [:]
    private var pendingPersistenceTask: Task<Void, Never>?
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directory = base.appendingPathComponent("RemoteFiles", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("transfers.json")
        }
        let directory = self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func copyFile(
        item: RemoteItem,
        from source: any RemoteFileProvider,
        to destination: any RemoteFileProvider,
        destinationPath: String,
        overwrite: Bool = false
    ) {
        let record = TransferRecord(
            fileName: item.name,
            sourceProfileID: source.profile.id,
            sourcePath: item.path,
            destinationProfileID: destination.profile.id,
            destinationPath: destinationPath,
            overwrite: overwrite,
            source: "\(source.profile.name):\(item.path)",
            destination: "\(destination.profile.name):\(destinationPath)",
            totalBytes: item.size,
            sourceRevision: item.revision,
            isResumable: supportsResuming(item: item, source: source, destination: destination)
        )
        records.insert(record, at: 0)
        persistNow()
        start(record: record, item: item, source: source, destination: destination, disconnectSource: false)
    }

    func uploadFile(
        localURL: URL,
        to destination: any RemoteFileProvider,
        destinationPath: String,
        overwrite: Bool = false
    ) async throws {
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
        let totalBytes = values.fileSize.map(Int64.init)
        let record = TransferRecord(
            fileName: localURL.lastPathComponent,
            sourceProfileID: destination.profile.id,
            sourcePath: localURL.path,
            destinationProfileID: destination.profile.id,
            destinationPath: destinationPath,
            overwrite: overwrite,
            source: "On Device:\(localURL.lastPathComponent)",
            destination: "\(destination.profile.name):\(destinationPath)",
            totalBytes: totalBytes,
            kind: .upload,
            isResumable: totalBytes.map { $0 > 0 } == true
                && destination.capabilities.contains(.randomWrite)
                && destination is any RemoteChunkWritableProvider
        )
        records.insert(record, at: 0)
        persistNow()
        await startLocalTransfer(record: record) { [weak self] token in
            guard let self else { return }
            try await self.performUpload(
                recordID: record.id,
                localURL: localURL,
                destination: destination,
                destinationPath: destinationPath,
                overwrite: overwrite,
                token: token
            )
        }
        try throwIfFailed(recordID: record.id)
    }

    func downloadFile(
        item: RemoteItem,
        from source: any RemoteFileProvider,
        to localURL: URL,
        destinationLabel: String = "Offline"
    ) async throws {
        let record = TransferRecord(
            fileName: item.name,
            sourceProfileID: source.profile.id,
            sourcePath: item.path,
            destinationProfileID: source.profile.id,
            destinationPath: localURL.path,
            overwrite: true,
            source: "\(source.profile.name):\(item.path)",
            destination: "\(destinationLabel):\(item.name)",
            totalBytes: item.size,
            sourceRevision: item.revision,
            kind: .download,
            isResumable: item.size.map { $0 > 0 } == true
                && source.capabilities.contains(.randomRead)
                && source is any RemoteChunkReadableProvider
        )
        records.insert(record, at: 0)
        persistNow()
        await startLocalTransfer(record: record) { [weak self] token in
            guard let self else { return }
            try await self.performDownload(
                recordID: record.id,
                item: item,
                source: source,
                localURL: localURL,
                token: token
            )
        }
        try throwIfFailed(recordID: record.id)
    }

    func resumePending(using connections: ConnectionStore) {
        for record in records where record.state == .queued && record.operationKind == .serverToServer {
            startPersisted(record, using: connections)
        }
    }

    func retry(_ record: TransferRecord, using connections: ConnectionStore) {
        guard let current = records.first(where: { $0.id == record.id }),
              current.operationKind == .serverToServer,
              current.state == .failed || current.state == .cancelled else { return }
        restart(current, using: connections)
    }

    func pause(_ record: TransferRecord) {
        guard let current = records.first(where: { $0.id == record.id }),
              current.supportsResuming,
              current.state == .running || current.state == .queued,
              current.commitPending != true,
              !committing.contains(current.id) else { return }
        pauseRequests.insert(current.id)
        pendingRetries[current.id] = nil
        update(current.id) {
            $0.state = .paused
            $0.errorMessage = nil
            $0.bytesPerSecond = nil
        }
    }

    func resume(_ record: TransferRecord, using connections: ConnectionStore) {
        guard let current = records.first(where: { $0.id == record.id }),
              current.supportsResuming,
              current.state == .paused || current.state == .failed || current.state == .cancelled else { return }
        if current.state == .paused,
           let active = tasks[current.id],
           executionOwnership[current.id]?.owns(active.token) == true,
           pauseRequests.remove(current.id) != nil {
            update(current.id) {
                $0.state = .running
                $0.errorMessage = nil
            }
            return
        }
        guard current.operationKind == .serverToServer else { return }
        restart(current, using: connections)
    }

    private func restart(_ current: TransferRecord, using connections: ConnectionStore) {
        pauseRequests.remove(current.id)
        update(current.id) {
            $0.state = .queued
            $0.errorMessage = nil
        }
        if let active = tasks[current.id] {
            active.task.cancel()
            executionOwnership[current.id]?.invalidate()
            // Cancellation is cooperative. Keep the old task occupying the slot until
            // its underlying provider calls and task body have actually returned.
            pendingRetries[current.id] = connections
            let previousTask = active.task
            let previousToken = active.token
            Task { [weak self] in
                await previousTask.value
                self?.finishExecutionAfterExit(for: current.id, token: previousToken)
            }
        } else {
            pendingRetries[current.id] = nil
            startPersisted(recordWithID: current.id, using: connections)
        }
    }

    private func supportsResuming(
        item: RemoteItem,
        source: any RemoteFileProvider,
        destination: any RemoteFileProvider
    ) -> Bool {
        guard let size = item.size, size >= 0,
              source.capabilities.contains(.randomRead),
              destination.capabilities.contains(.randomWrite),
              destination.capabilities.contains(.move),
              source is any RemoteChunkReadableProvider,
              destination is any RemoteChunkWritableProvider else {
            return false
        }
        return TransferResumePolicy.decision(
            transferredBytes: 0,
            persistedRevision: item.revision,
            currentRevision: item.revision
        ) != .restart
    }

    func cancel(_ record: TransferRecord) {
        guard let current = records.first(where: { $0.id == record.id }),
              current.state == .running || current.state == .queued,
              current.commitPending != true,
              !committing.contains(current.id) else { return }
        if let active = tasks[current.id] {
            active.task.cancel()
            executionOwnership[current.id]?.invalidate()
        }
        pauseRequests.remove(current.id)
        pendingRetries[current.id] = nil
        update(current.id) {
            $0.state = .cancelled
            $0.errorMessage = nil
            if current.operationKind != .serverToServer {
                $0.isResumable = false
            }
        }
    }

    private func startPersisted(_ original: TransferRecord, using connections: ConnectionStore) {
        startPersisted(recordWithID: original.id, using: connections)
    }

    private func startPersisted(recordWithID id: UUID, using connections: ConnectionStore) {
        guard tasks[id] == nil else { return }
        guard let record = records.first(where: { $0.id == id }),
              let sourceProfile = connections.profiles.first(where: { $0.id == record.sourceProfileID }),
              let destinationProfile = connections.profiles.first(where: { $0.id == record.destinationProfileID }) else {
            if records.contains(where: { $0.id == id }) {
                update(id) {
                    $0.state = .failed
                    $0.errorMessage = "The source or destination connection no longer exists."
                }
            }
            return
        }

        let token = beginExecution(for: id)
        let task = Task { [weak self] in
            guard let self else { return }
            var sourceForCleanup: (any RemoteFileProvider)?
            var destinationForCleanup: (any RemoteFileProvider)?
            do {
                let source = try ProviderFactory.make(for: sourceProfile)
                let destination = try ProviderFactory.make(for: destinationProfile)
                sourceForCleanup = source
                destinationForCleanup = destination
                try await source.connect()
                try await destination.connect()
                let item = try await source.attributes(path: record.sourcePath)
                try self.checkExecution(token, for: id)
                self.update(id, token: token) { $0.totalBytes = item.size }
                await self.perform(
                    recordID: id,
                    item: item,
                    source: source,
                    destination: destination,
                    destinationPath: record.destinationPath,
                    disconnectSource: true,
                    token: token
                )
                sourceForCleanup = nil
                destinationForCleanup = nil
            } catch is CancellationError {
                self.update(id, token: token) { $0.state = .cancelled }
            } catch {
                self.update(id, token: token) {
                    $0.state = .failed
                    $0.errorMessage = error.localizedDescription
                }
            }
            await destinationForCleanup?.disconnect()
            await sourceForCleanup?.disconnect()
            self.finishExecution(for: id, token: token)
        }
        tasks[id] = ActiveTask(token: token, task: task)
    }

    private func start(
        record: TransferRecord,
        item: RemoteItem,
        source: any RemoteFileProvider,
        destination: any RemoteFileProvider,
        disconnectSource: Bool
    ) {
        let id = record.id
        guard tasks[id] == nil else { return }
        let token = beginExecution(for: id)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.checkExecution(token, for: id)
                let currentItem = try await source.attributes(path: item.path)
                try self.checkExecution(token, for: id)
                self.update(id, token: token) { $0.totalBytes = currentItem.size }
                await self.perform(
                    recordID: id,
                    item: currentItem,
                    source: source,
                    destination: destination,
                    destinationPath: record.destinationPath,
                    disconnectSource: disconnectSource,
                    token: token
                )
            } catch is CancellationError {
                self.update(id, token: token) { $0.state = .cancelled }
            } catch {
                self.update(id, token: token) {
                    $0.state = .failed
                    $0.errorMessage = error.localizedDescription
                }
            }
            self.finishExecution(for: id, token: token)
        }
        tasks[id] = ActiveTask(token: token, task: task)
    }

    private func perform(
        recordID id: UUID,
        item: RemoteItem,
        source: any RemoteFileProvider,
        destination: any RemoteFileProvider,
        destinationPath: String,
        disconnectSource: Bool,
        token: TransferExecutionToken
    ) async {
        do {
            try checkExecution(token, for: id)
            let currentRecord = records.first(where: { $0.id == id })
            let policyDecision = TransferResumePolicy.decision(
                transferredBytes: currentRecord?.transferredBytes,
                persistedRevision: currentRecord?.sourceRevision,
                currentRevision: item.revision
            )
            // A task that was not advertised as resumable must restart from a
            // clean partial even if its provider happens to expose chunk APIs.
            // This keeps the UI capability contract and the actual retry path in
            // agreement.
            let decision: TransferResumeDecision = currentRecord?.supportsResuming == true
                ? policyDecision
                : .restart
            let partialPath = streamPartialPath(for: destinationPath, recordID: id)
            var alreadyCommitted = false
            var expectedBytesForVerification = item.size
            if currentRecord?.commitPending == true,
               let total = item.size, total >= 0,
               case .resume = decision {
                alreadyCommitted = try await reconcilePendingFinalization(
                    for: id,
                    token: token,
                    destination: destination,
                    destinationPath: destinationPath,
                    partialPath: partialPath,
                    expectedBytes: UInt64(total)
                )
            } else if currentRecord?.commitPending == true {
                update(id, token: token) {
                    $0.commitPending = false
                    $0.commitDestinationExisted = nil
                }
            }
            var canReadChunks = false
            if !alreadyCommitted {
                canReadChunks = source is any RemoteChunkReadableProvider
                if canReadChunks, let probing = source as? any RemoteChunkReadSupportProbing {
                    canReadChunks = try await probing.supportsChunkedReads(path: item.path)
                }
            }
            let canStream = canReadChunks
                && destination is any RemoteChunkWritableProvider
                && destination.capabilities.contains(.move)
                && (item.size.map { $0 >= 0 } ?? false)
            var requestedResumeOffset: UInt64 = 0
            var overwritePartial = false

            if !alreadyCommitted, canStream, case .resume = decision,
               let total = item.size, total >= 0,
               let partialItem = try await destinationItemIfPresent(
                   path: partialPath,
                   on: destination
               ) {
                guard !partialItem.isDirectory else {
                    throw RemoteProviderError.conflict("The transfer partial path is occupied by a directory.")
                }
                if let partialSize = partialItem.size,
                   partialSize >= 0,
                   partialSize <= total,
                   let partialOffset = UInt64(exactly: partialSize) {
                    requestedResumeOffset = min(decision.offset, min(partialOffset, UInt64(total)))
                    // Bytes beyond the confirmed checkpoint belong to an interrupted
                    // write and must not be appended to or treated as a valid prefix.
                    overwritePartial = requestedResumeOffset == 0 || partialOffset > requestedResumeOffset
                } else {
                    overwritePartial = true
                }
            } else if !alreadyCommitted, canStream, decision == .restart,
                      let partialItem = try await destinationItemIfPresent(
                          path: partialPath,
                          on: destination
                      ) {
                guard !partialItem.isDirectory else {
                    throw RemoteProviderError.conflict("The transfer partial path is occupied by a directory.")
                }
                overwritePartial = true
            }

            if !alreadyCommitted {
                try checkPause(for: id, token: token)
                progressSnapshots[id] = nil
                update(id, token: token) {
                    $0.state = .running
                    $0.progress = 0.05
                    $0.totalBytes = item.size
                    $0.sourceRevision = item.revision
                    $0.transferredBytes = requestedResumeOffset
                    $0.startedAt = Date()
                    $0.bytesPerSecond = nil
                }
                try checkExecution(token, for: id)
            }
            let overwrite = records.first(where: { $0.id == id })?.overwrite ?? false
            if alreadyCommitted {
                // The previous attempt durably committed the final rename. Keep
                // the commit lock until the terminal record update below.
            } else if canStream,
               let reader = source as? any RemoteChunkReadableProvider,
               let writer = destination as? any RemoteChunkWritableProvider,
               let total = item.size, total >= 0 {
                try await streamCopy(
                    item: item,
                    totalBytes: UInt64(total),
                    reader: reader,
                    writer: writer,
                    destinationPath: partialPath,
                    overwrite: overwritePartial,
                    recordID: id,
                    requestedResumeOffset: requestedResumeOffset,
                    token: token
                )
                try await beginFinalization(
                    for: id,
                    token: token,
                    destination: destination,
                    destinationPath: destinationPath,
                    overwrite: overwrite
                )
                try await destination.move(from: partialPath, to: destinationPath, overwrite: overwrite)
            } else {
                // A record can outlive a provider capability change (or a runtime
                // range-read probe can reject chunking). Do not leave the list
                // advertising pause/resume once we know this attempt has to use
                // the all-or-nothing temporary-file path.
                disableResuming(for: id, token: token)
                update(id, token: token) { $0.transferredBytes = 0; $0.progress = 0.05 }
                try checkExecution(token, for: id)
                let startedAt = Date()
                let tempURL = try await CacheManager.shared.temporaryURL(fileName: item.name)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await source.download(path: item.path, to: tempURL)
                try checkExecution(token, for: id)
                let downloadedSize = try tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                if let sourceSize = item.size, sourceSize >= 0,
                   downloadedSize.map(Int64.init) != sourceSize {
                    throw RemoteProviderError.invalidResponse(
                        "The source download size did not match the advertised size."
                    )
                }
                if expectedBytesForVerification == nil {
                    expectedBytesForVerification = downloadedSize.map(Int64.init)
                }
                update(id, token: token) { $0.progress = 0.55 }
                try await destination.upload(from: tempURL, to: destinationPath, overwrite: overwrite)
                if let total = expectedBytesForVerification, total >= 0 {
                    update(id, token: token) {
                        $0.transferredBytes = UInt64(total)
                        $0.totalBytes = total
                        let elapsed = Date().timeIntervalSince(startedAt)
                        if elapsed >= 0.2 {
                            $0.bytesPerSecond = Double(total) / elapsed
                        }
                    }
                }
            }
            try checkExecution(token, for: id)
            try checkPause(for: id, token: token)
            try await verifyCompletedDestination(
                expectedBytes: expectedBytesForVerification,
                destination: destination,
                destinationPath: destinationPath
            )
            try checkExecution(token, for: id)
            update(id, token: token) {
                $0.state = .completed
                $0.progress = 1
                $0.errorMessage = nil
                $0.commitPending = false
                $0.commitDestinationExisted = nil
            }
        } catch is TransferPausedError {
            pauseRequests.remove(id)
            update(id, token: token) {
                $0.state = .paused
                $0.errorMessage = nil
                $0.bytesPerSecond = nil
            }
        } catch is CancellationError {
            pauseRequests.remove(id)
            update(id, token: token) {
                $0.state = .cancelled
                $0.errorMessage = nil
            }
        } catch {
            pauseRequests.remove(id)
            update(id, token: token) {
                $0.state = .failed
                $0.errorMessage = error.localizedDescription
            }
        }
        committing.remove(id)
        await destination.disconnect()
        if disconnectSource { await source.disconnect() }
    }

    private func verifyCompletedDestination(
        expectedBytes: Int64?,
        destination: any RemoteFileProvider,
        destinationPath: String
    ) async throws {
        guard let expectedBytes, expectedBytes >= 0 else {
            throw RemoteProviderError.invalidResponse(
                "Transfer verification failed because the expected transfer size is unavailable."
            )
        }

        // Do not turn a failed final stat into a successful transfer. In
        // particular, a stream copy may already have set commitPending before
        // the rename; propagating this error preserves that marker so a retry
        // can reconcile the commit window instead of starting from an
        // unverified completed state.
        let destinationItem = try await destination.attributes(path: destinationPath)
        guard !destinationItem.isDirectory else {
            throw RemoteProviderError.invalidResponse(
                "Transfer verification failed because the destination is a directory."
            )
        }
        guard let destinationSize = destinationItem.size, destinationSize >= 0 else {
            throw RemoteProviderError.invalidResponse(
                "Transfer verification failed because the destination size is unavailable."
            )
        }
        guard expectedBytes == destinationSize else {
            throw RemoteProviderError.invalidResponse(
                "Transfer verification failed: expected \(expectedBytes) bytes but destination reports \(destinationSize) bytes."
            )
        }
    }

    private func streamPartialPath(for destinationPath: String, recordID: UUID) -> String {
        let name = "." + "remotefiles-\(recordID.uuidString.lowercased()).partial"
        return RemotePath.join(RemotePath.parent(destinationPath), name)
    }

    private func destinationItemIfPresent(
        path: String,
        on destination: any RemoteFileProvider
    ) async throws -> RemoteItem? {
        let normalized = RemotePath.normalize(path)
        let entries = try await destination.list(path: RemotePath.parent(normalized))
        return entries.first(where: { RemotePath.normalize($0.path) == normalized })
    }

    private func streamCopy(
        item: RemoteItem,
        totalBytes: UInt64,
        reader: any RemoteChunkReadableProvider,
        writer: any RemoteChunkWritableProvider,
        destinationPath: String,
        overwrite: Bool,
        recordID: UUID,
        requestedResumeOffset: UInt64,
        token: TransferExecutionToken
    ) async throws {
        let chunkSize = Self.transferChunkSize
        let requestedOffset = min(requestedResumeOffset, totalBytes)
        try checkExecution(token, for: recordID)
        let openedWriteSession = try await writer.openWriteSession(
            path: destinationPath,
            overwrite: overwrite,
            resumeOffset: requestedOffset
        )
        let writeSession = openedWriteSession?.session
        var preparedLegacyUpload = false
        var readSession: (any RemoteChunkReadSession)?
        do {
            try checkExecution(token, for: recordID)
            var offset: UInt64
            if let openedWriteSession {
                offset = openedWriteSession.offset
            } else {
                preparedLegacyUpload = true
                offset = try await writer.prepareChunkedUpload(
                    path: destinationPath,
                    overwrite: overwrite,
                    resumeOffset: requestedOffset
                )
            }
            guard offset <= totalBytes else {
                throw RemoteProviderError.invalidResponse(
                    "The destination reported a resume offset beyond the source size."
                )
            }
            try checkExecution(token, for: recordID)
            update(recordID, token: token) {
                $0.transferredBytes = offset
                let fraction = totalBytes == 0 ? 1 : Double(offset) / Double(totalBytes)
                $0.progress = 0.05 + 0.9 * min(1, fraction)
            }

            let speedBaseline = offset
            let speedStartedAt = Date()

            readSession = try await reader.openReadSession(path: item.path, offset: offset)
            try checkExecution(token, for: recordID)
            while offset < totalBytes {
                try checkExecution(token, for: recordID)
                try checkPause(for: recordID, token: token)
                let remaining = totalBytes - offset
                let length = Int(min(UInt64(chunkSize), remaining))
                let data: Data
                if let readSession {
                    data = try await readSession.read(length: length)
                } else {
                    data = try await reader.readChunk(path: item.path, offset: offset, length: length)
                }
                try checkExecution(token, for: recordID)
                guard !data.isEmpty else {
                    throw RemoteProviderError.invalidResponse("The source ended before the expected file size was reached.")
                }
                guard data.count <= length else {
                    throw RemoteProviderError.invalidResponse("The source returned more bytes than requested.")
                }
                if let writeSession {
                    try await writeSession.write(data, at: offset)
                } else {
                    try await writer.writeChunk(path: destinationPath, data: data, offset: offset)
                }
                try checkExecution(token, for: recordID)
                offset += UInt64(data.count)
                let fraction = totalBytes == 0 ? 1 : Double(offset) / Double(totalBytes)
                updateProgress(
                    id: recordID,
                    token: token,
                    transferredBytes: offset,
                    progress: 0.05 + 0.9 * min(1, fraction),
                    baselineBytes: speedBaseline,
                    startedAt: speedStartedAt
                )
                try checkPause(for: recordID, token: token)
            }
            try checkExecution(token, for: recordID)
            try checkPause(for: recordID, token: token)
            await readSession?.close()
            if let writeSession {
                try await writeSession.finish()
            } else {
                try await writer.finishChunkedUpload(path: destinationPath)
            }
        } catch {
            await readSession?.close()
            await writeSession?.abort()
            if writeSession == nil, preparedLegacyUpload {
                await writer.abortChunkedUpload(path: destinationPath)
            }
            throw error
        }
    }

    func clearFinished() {
        let removedIDs = records
            .filter { $0.state == .completed || $0.state == .cancelled }
            .map(\.id)
        for id in removedIDs {
            progressSnapshots[id] = nil
            pendingRetries[id] = nil
            pauseRequests.remove(id)
            committing.remove(id)
            finalizedTransfers.remove(id)
            if let active = tasks[id] {
                active.task.cancel()
                executionOwnership[id]?.invalidate()
            } else {
                executionOwnership[id] = nil
            }
        }
        records.removeAll { $0.state == .completed || $0.state == .cancelled }
        persistNow()
    }

    func remove(_ record: TransferRecord) {
        guard let current = records.first(where: { $0.id == record.id }),
              current.state != .running, current.state != .queued else { return }
        if let active = tasks[current.id] {
            active.task.cancel()
            executionOwnership[current.id]?.invalidate()
        } else {
            executionOwnership[current.id] = nil
        }
        pendingRetries[current.id] = nil
        pauseRequests.remove(current.id)
        committing.remove(current.id)
        finalizedTransfers.remove(current.id)
        progressSnapshots[current.id] = nil
        records.removeAll { $0.id == current.id }
        persistNow()
    }

    private func beginExecution(for id: UUID) -> TransferExecutionToken {
        var ownership = executionOwnership[id] ?? TransferExecutionOwnership()
        let token = ownership.begin()
        executionOwnership[id] = ownership
        return token
    }

    private func checkExecution(_ token: TransferExecutionToken, for id: UUID) throws {
        try Task.checkCancellation()
        guard executionOwnership[id]?.owns(token) == true else {
            throw CancellationError()
        }
    }

    private func checkPause(for id: UUID, token: TransferExecutionToken) throws {
        guard executionOwnership[id]?.owns(token) == true else {
            throw CancellationError()
        }
        if pauseRequests.contains(id) {
            throw TransferPausedError()
        }
    }

    private func disableResuming(for id: UUID, token: TransferExecutionToken) {
        // A pause request can race with the asynchronous capability probe. Once
        // the provider has forced an all-or-nothing path there is no safe local
        // checkpoint to wait on, so consume that stale request and keep the
        // transfer running instead of leaving an unresumable record stuck at
        // `paused`.
        pauseRequests.remove(id)
        update(id, token: token) {
            $0.isResumable = false
            if $0.state == .paused {
                $0.state = .running
                $0.errorMessage = nil
            }
        }
    }

    private func beginFinalization(
        for id: UUID,
        token: TransferExecutionToken,
        destination: any RemoteFileProvider,
        destinationPath: String,
        overwrite: Bool
    ) async throws {
        try checkExecution(token, for: id)
        try checkPause(for: id, token: token)

        // Record the commit phase before the rename. The private partial path is
        // the durable payload, while this marker tells a later engine launch that
        // a missing partial plus a complete final may represent a completed
        // rename rather than a fresh unrelated destination.
        let destinationItem = try await destinationItemIfPresent(
            path: destinationPath,
            on: destination
        )
        if destinationItem != nil, !overwrite {
            throw RemoteProviderError.conflict("An item already exists at \(destinationPath).")
        }
        let destinationExisted = destinationItem != nil
        try checkExecution(token, for: id)
        try checkPause(for: id, token: token)
        committing.insert(id)
        update(id, token: token) {
            $0.commitPending = true
            $0.commitDestinationExisted = destinationExisted
        }
    }

    private func enterFinalizationLock(
        for id: UUID,
        token: TransferExecutionToken,
        allowLatePause: Bool = false
    ) throws {
        try checkExecution(token, for: id)
        if allowLatePause {
            // The final payload write has already returned. Treat a pause that
            // arrives in this tiny close/rename window as a late UI action and
            // finish the committed file instead of creating a paused record with
            // no remaining work.
            pauseRequests.remove(id)
        } else {
            try checkPause(for: id, token: token)
        }
        committing.insert(id)
        update(id, token: token) {
            $0.commitPending = true
            $0.commitDestinationExisted = nil
        }
    }

    private func reconcilePendingFinalization(
        for id: UUID,
        token: TransferExecutionToken,
        destination: any RemoteFileProvider,
        destinationPath: String,
        partialPath: String,
        expectedBytes: UInt64
    ) async throws -> Bool {
        guard let record = records.first(where: { $0.id == id }),
              record.commitPending == true else {
            return false
        }

        // Block pause/cancel while we determine whether the previous rename
        // committed. A late UI action must not turn a committed final file back
        // into a paused/cancelled record.
        pauseRequests.remove(id)
        committing.insert(id)
        var keepCommitLock = false
        defer {
            if !keepCommitLock {
                committing.remove(id)
            }
        }
        try checkExecution(token, for: id)
        let finalItem = try await destinationItemIfPresent(path: destinationPath, on: destination)
        try checkExecution(token, for: id)
        let partialItem = try await destinationItemIfPresent(path: partialPath, on: destination)
        try checkExecution(token, for: id)

        switch TransferCommitPolicy.decision(
            finalItem: finalItem,
            partialItem: partialItem,
            expectedBytes: expectedBytes,
            destinationExistedBeforeCommit: record.commitDestinationExisted
        ) {
        case .completed:
            update(id, token: token) {
                $0.state = .running
                $0.transferredBytes = expectedBytes
                $0.progress = 0.95
            }
            keepCommitLock = true
            return true
        case .uncertain:
            update(id, token: token) {
                $0.commitPending = false
                $0.commitDestinationExisted = nil
            }
            throw RemoteProviderError.conflict(
                "The transfer finalization status is uncertain; manually verify the destination before retrying."
            )
        case .resume:
            // The rename did not leave a complete final. Keep any durable
            // partial prefix and let the normal resume path reconcile it against
            // the confirmed checkpoint.
            update(id, token: token) {
                $0.commitPending = false
                $0.commitDestinationExisted = nil
            }
            return false
        }
    }

    private func waitWhilePaused(for id: UUID, token: TransferExecutionToken) async throws {
        while pauseRequests.contains(id) {
            try checkExecution(token, for: id)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try checkExecution(token, for: id)
    }

    private func finishExecution(for id: UUID, token: TransferExecutionToken) {
        guard tasks[id]?.token == token else { return }
        // A retry coordinator owns cleanup while it waits for this task to exit.
        guard pendingRetries[id] == nil else { return }
        finishExecutionAfterExit(for: id, token: token)
    }

    private func finishExecutionAfterExit(for id: UUID, token: TransferExecutionToken) {
        guard tasks[id]?.token == token else { return }
        tasks[id] = nil
        progressSnapshots[id] = nil
        pauseRequests.remove(id)
        committing.remove(id)
        finalizedTransfers.remove(id)
        _ = executionOwnership[id]?.finish(token)

        guard records.contains(where: { $0.id == id }) else {
            pendingRetries[id] = nil
            executionOwnership[id] = nil
            return
        }

        if let connections = pendingRetries.removeValue(forKey: id),
           let state = records.first(where: { $0.id == id })?.state,
           state == .failed || state == .cancelled || state == .queued {
            update(id) {
                $0.state = .queued
                $0.errorMessage = nil
            }
            startPersisted(recordWithID: id, using: connections)
        } else if executionOwnership[id]?.activeToken == nil {
            executionOwnership[id] = nil
        }
    }

    private func update(
        _ id: UUID,
        token: TransferExecutionToken? = nil,
        _ mutation: (inout TransferRecord) -> Void
    ) {
        if let token, executionOwnership[id]?.owns(token) != true { return }
        flushProgress(for: id, token: token)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutation(&records[index])
        persistNow()
    }

    private func startLocalTransfer(
        record: TransferRecord,
        operation: @escaping (TransferExecutionToken) async throws -> Void
    ) async {
        let id = record.id
        guard tasks[id] == nil else { return }
        let token = beginExecution(for: id)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.checkExecution(token, for: id)
                try await operation(token)
                // Once the last write/rename has returned, a caller cancellation
                // arriving in the tiny terminal window must not turn a committed
                // file into a cancelled transfer.
                let finalized = self.finalizedTransfers.contains(id)
                if !finalized {
                    try self.checkExecution(token, for: id)
                }
                if !self.completeFinalizedLocalTransfer(id: id, token: token) {
                    self.update(id, token: token) {
                        $0.state = .completed
                        $0.progress = 1
                        $0.errorMessage = nil
                        $0.commitPending = false
                        $0.commitDestinationExisted = nil
                    }
                }
            } catch is TransferPausedError {
                // A pause is a resumable state, not a failed local transfer. The
                // normal local path waits at the chunk boundary, but this catch
                // also covers a pause that races with setup/finalization.
                self.update(id, token: token) {
                    $0.state = .paused
                    $0.errorMessage = nil
                    $0.bytesPerSecond = nil
                    $0.commitPending = false
                    $0.commitDestinationExisted = nil
                }
            } catch is CancellationError {
                self.update(id, token: token) {
                    $0.state = .cancelled
                    $0.errorMessage = nil
                    $0.isResumable = false
                    $0.commitPending = false
                    $0.commitDestinationExisted = nil
                }
            } catch {
                self.update(id, token: token) {
                    $0.state = .failed
                    $0.errorMessage = error.localizedDescription
                    $0.isResumable = false
                    $0.commitPending = false
                    $0.commitDestinationExisted = nil
                }
            }
            self.finishExecution(for: id, token: token)
        }
        tasks[id] = ActiveTask(token: token, task: task)
        // The local operation is kept as a separately-owned task so pause/cancel
        // actions from the transfer list can address it. Tie its lifetime to the
        // caller as well: uploadFile/downloadFile are async APIs and callers
        // commonly cancel the task that is awaiting this method (for example when
        // a view disappears). Without this handler that cancellation would leave
        // a paused I/O task and its file/session open indefinitely.
        await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    private func completeFinalizedLocalTransfer(
        id: UUID,
        token: TransferExecutionToken
    ) -> Bool {
        guard finalizedTransfers.contains(id),
              tasks[id]?.token == token,
              let index = records.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let ownsToken = executionOwnership[id]?.owns(token) == true
        // A UI cancel invalidates ownership before the provider can return. It is
        // safe to override that early terminal state only while this exact task
        // still occupies the slot and the record has not been retried/removed.
        guard ownsToken || records[index].state == .cancelled else { return false }
        records[index].state = .completed
        records[index].progress = 1
        records[index].errorMessage = nil
        records[index].commitPending = false
        records[index].commitDestinationExisted = nil
        persistNow()
        return true
    }

    private func performUpload(
        recordID id: UUID,
        localURL: URL,
        destination: any RemoteFileProvider,
        destinationPath: String,
        overwrite: Bool,
        token: TransferExecutionToken
    ) async throws {
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
        let totalBytes = UInt64(max(0, values.fileSize ?? 0))
        try await waitWhilePaused(for: id, token: token)
        let startedAt = Date()
        progressSnapshots[id] = nil
        update(id, token: token) {
            $0.state = .running
            $0.progress = totalBytes == 0 ? 0.5 : 0
            $0.totalBytes = Int64(clamping: totalBytes)
            $0.transferredBytes = 0
            $0.startedAt = startedAt
            $0.bytesPerSecond = nil
        }
        try checkExecution(token, for: id)

        if let writer = destination as? any RemoteChunkWritableProvider {
            let usePartial = destination.capabilities.contains(.move)
            let targetPath = usePartial ? streamPartialPath(for: destinationPath, recordID: id) : destinationPath
            let opened = try await writer.openWriteSession(path: targetPath, overwrite: usePartial ? true : overwrite, resumeOffset: 0)
            let session = opened?.session
            var preparedLegacyUpload = false
            let preparedOffset: UInt64
            if let opened {
                preparedOffset = opened.offset
            } else {
                preparedLegacyUpload = true
                preparedOffset = try await writer.prepareChunkedUpload(
                    path: targetPath,
                    overwrite: usePartial ? true : overwrite,
                    resumeOffset: 0
                )
            }
            guard preparedOffset == 0 else {
                await session?.abort()
                if session == nil, preparedLegacyUpload {
                    await writer.abortChunkedUpload(path: targetPath)
                }
                if usePartial {
                    try? await destination.remove(path: targetPath, isDirectory: false)
                }
                throw RemoteProviderError.invalidResponse("The upload destination did not start at byte 0.")
            }

            var localReader: TransferFileReader?
            do {
                localReader = try TransferFileReader(url: localURL)
                guard let localReader else {
                    throw RemoteProviderError.invalidResponse("The local upload reader could not be opened.")
                }
                var offset: UInt64 = 0
                while offset < totalBytes {
                    try checkExecution(token, for: id)
                    try await waitWhilePaused(for: id, token: token)
                    let length = Int(min(UInt64(Self.transferChunkSize), totalBytes - offset))
                    guard let data = try await localReader.read(upToCount: length), !data.isEmpty else {
                        throw RemoteProviderError.invalidResponse("The local file ended before the expected size was reached.")
                    }
                    if let session {
                        try await session.write(data, at: offset)
                    } else {
                        try await writer.writeChunk(path: targetPath, data: data, offset: offset)
                    }
                    offset += UInt64(data.count)
                    let fraction = totalBytes == 0 ? 1 : Double(offset) / Double(totalBytes)
                    updateProgress(
                        id: id,
                        token: token,
                        transferredBytes: offset,
                        progress: min(1, fraction),
                        baselineBytes: 0,
                        startedAt: startedAt
                    )
                    try await waitWhilePaused(for: id, token: token)
                }
                // The payload is complete. Hold the commit lock across close,
                // preflight, and the optional rename so a late pause/cancel
                // cannot leave a local upload in a terminal-but-resumable limbo.
                try enterFinalizationLock(for: id, token: token, allowLatePause: true)
                if let session {
                    try await session.finish()
                } else {
                    try await writer.finishChunkedUpload(path: targetPath)
                }
                if usePartial {
                    let destinationExisted = try await destinationItemIfPresent(
                        path: destinationPath,
                        on: destination
                    ) != nil
                    update(id, token: token) {
                        $0.commitDestinationExisted = destinationExisted
                    }
                    try await destination.move(from: targetPath, to: destinationPath, overwrite: overwrite)
                }
                finalizedTransfers.insert(id)
                await localReader.close()
            } catch {
                await localReader?.close()
                await session?.abort()
                if session == nil, preparedLegacyUpload {
                    await writer.abortChunkedUpload(path: targetPath)
                }
                if usePartial {
                    try? await destination.remove(path: targetPath, isDirectory: false)
                }
                throw error
            }
        } else {
            // Providers without chunked writes can still expose an atomic move.
            // Keep the native upload out of the user-visible destination until
            // it has returned successfully. This prevents a cancellation or a
            // provider failure from leaving a partial file at the final path.
            let usePartial = destination.capabilities.contains(.move)
            let targetPath = usePartial
                ? streamPartialPath(for: destinationPath, recordID: id)
                : destinationPath
            do {
                try await destination.upload(
                    from: localURL,
                    to: targetPath,
                    overwrite: usePartial ? true : overwrite
                )
                if usePartial {
                    // The native upload has returned, but ownership can still
                    // have been invalidated while the provider was finishing.
                    // Do this check before taking the commit lock so cancellation
                    // cleans only our private partial path.
                    try checkExecution(token, for: id)
                    try enterFinalizationLock(for: id, token: token, allowLatePause: true)

                    let destinationExisted = try await destinationItemIfPresent(
                        path: destinationPath,
                        on: destination
                    ) != nil
                    if destinationExisted && !overwrite {
                        throw RemoteProviderError.conflict("An item already exists at \(destinationPath).")
                    }
                    update(id, token: token) {
                        $0.commitDestinationExisted = destinationExisted
                    }
                    try await destination.move(
                        from: targetPath,
                        to: destinationPath,
                        overwrite: overwrite
                    )
                }
                // Keep the late-cancellation behavior used by the direct native
                // path: once the final move/upload has returned, this task owns a
                // completed payload and the terminal state may win the race.
                finalizedTransfers.insert(id)
            } catch {
                // A staged native upload owns only targetPath. Never remove the
                // final destination here: it may predate this transfer or the
                // move may already have committed before a later error surfaced.
                if usePartial {
                    try? await destination.remove(path: targetPath, isDirectory: false)
                }
                throw error
            }
            update(id, token: token) {
                $0.transferredBytes = totalBytes
                let elapsed = Date().timeIntervalSince(startedAt)
                if elapsed >= 0.2 {
                    $0.bytesPerSecond = Double(totalBytes) / elapsed
                }
            }
        }
    }

    private func performDownload(
        recordID id: UUID,
        item: RemoteItem,
        source: any RemoteFileProvider,
        localURL: URL,
        token: TransferExecutionToken
    ) async throws {
        try await waitWhilePaused(for: id, token: token)
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: localURL)
        let startedAt = Date()
        progressSnapshots[id] = nil
        update(id, token: token) {
            $0.state = .running
            $0.progress = 0
            $0.transferredBytes = 0
            $0.totalBytes = item.size
            $0.startedAt = startedAt
            $0.bytesPerSecond = nil
        }
        do {
            var canReadChunks = source is any RemoteChunkReadableProvider
            if canReadChunks, let probing = source as? any RemoteChunkReadSupportProbing {
                canReadChunks = try await probing.supportsChunkedReads(path: item.path)
            }
            if canReadChunks,
               let reader = source as? any RemoteChunkReadableProvider,
               let size = item.size, size >= 0 {
                FileManager.default.createFile(atPath: localURL.path, contents: nil)
                let localWriter = try TransferFileWriter(url: localURL)
                let totalBytes = UInt64(size)
                var offset: UInt64 = 0
                var session: (any RemoteChunkReadSession)?
                do {
                    session = try await reader.openReadSession(path: item.path, offset: 0)
                    while offset < totalBytes {
                        try checkExecution(token, for: id)
                        try await waitWhilePaused(for: id, token: token)
                        let length = Int(min(UInt64(Self.transferChunkSize), totalBytes - offset))
                        let data: Data
                        if let session {
                            data = try await session.read(length: length)
                        } else {
                            data = try await reader.readChunk(path: item.path, offset: offset, length: length)
                        }
                        guard !data.isEmpty else {
                            throw RemoteProviderError.invalidResponse("The source ended before the expected file size was reached.")
                        }
                        guard data.count <= length else {
                            throw RemoteProviderError.invalidResponse("The source returned more bytes than requested.")
                        }
                        try await localWriter.write(data)
                        offset += UInt64(data.count)
                        let fraction = totalBytes == 0 ? 1 : Double(offset) / Double(totalBytes)
                        updateProgress(
                            id: id,
                            token: token,
                            transferredBytes: offset,
                            progress: min(1, fraction),
                            baselineBytes: 0,
                            startedAt: startedAt
                        )
                        try await waitWhilePaused(for: id, token: token)
                    }
                    try enterFinalizationLock(for: id, token: token, allowLatePause: true)
                    await session?.close()
                    await localWriter.close()
                    finalizedTransfers.insert(id)
                } catch {
                    await session?.close()
                    await localWriter.close()
                    throw error
                }
            } else {
                // A persisted record may have been created when chunked reads
                // were available but the provider can reject them at runtime.
                // Such a transfer is not safely resumable and must not remain
                // advertised as one in the list.
                disableResuming(for: id, token: token)
                try await source.download(path: item.path, to: localURL)
                finalizedTransfers.insert(id)
                let actual = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0
                update(id, token: token) {
                    $0.transferredBytes = actual
                    let elapsed = Date().timeIntervalSince(startedAt)
                    if elapsed >= 0.2 {
                        $0.bytesPerSecond = Double(actual) / elapsed
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }
    }

    private func updateProgress(
        id: UUID,
        token: TransferExecutionToken,
        transferredBytes: UInt64,
        progress: Double,
        baselineBytes: UInt64,
        startedAt: Date
    ) {
        guard executionOwnership[id]?.owns(token) == true,
              let index = records.firstIndex(where: { $0.id == id }) else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)
        let speed: Double? = if elapsed >= 0.2, transferredBytes >= baselineBytes {
            Double(transferredBytes - baselineBytes) / elapsed
        } else {
            nil
        }
        let normalizedProgress = min(1, max(0, progress))
        let previous = progressSnapshots[id]
        let sameAttempt = previous?.token == token
        let lastPublishedAt = sameAttempt ? previous!.lastPublishedAt : .distantPast
        let lastPublishedBytes = sameAttempt ? previous!.lastPublishedBytes : 0
        let hasReachedByteThreshold = transferredBytes >= lastPublishedBytes
            && transferredBytes - lastPublishedBytes >= Self.progressUpdateBytes
        let shouldPublish = !sameAttempt
            || normalizedProgress >= 1
            || now.timeIntervalSince(lastPublishedAt) >= Self.progressUpdateInterval
            || (hasReachedByteThreshold
                && now.timeIntervalSince(lastPublishedAt) >= Self.progressByteUpdateInterval)
        let latestSpeed = speed ?? previous?.bytesPerSecond ?? records[index].bytesPerSecond
        progressSnapshots[id] = ProgressSnapshot(
            token: token,
            transferredBytes: transferredBytes,
            progress: normalizedProgress,
            bytesPerSecond: latestSpeed,
            lastPublishedAt: shouldPublish ? now : lastPublishedAt,
            lastPublishedBytes: shouldPublish ? transferredBytes : lastPublishedBytes
        )
        guard shouldPublish else { return }

        records[index].transferredBytes = transferredBytes
        records[index].progress = normalizedProgress
        records[index].bytesPerSecond = latestSpeed
        schedulePersistence()
    }

    private func flushProgress(for id: UUID, token: TransferExecutionToken?) {
        guard let snapshot = progressSnapshots[id],
              let index = records.firstIndex(where: { $0.id == id }) else { return }
        if let token {
            guard snapshot.token == token, executionOwnership[id]?.owns(token) == true else { return }
        }

        records[index].transferredBytes = snapshot.transferredBytes
        records[index].progress = snapshot.progress
        records[index].bytesPerSecond = snapshot.bytesPerSecond
        var flushed = snapshot
        flushed.lastPublishedAt = Date()
        flushed.lastPublishedBytes = snapshot.transferredBytes
        progressSnapshots[id] = flushed
    }

    private func throwIfFailed(recordID id: UUID) throws {
        guard let record = records.first(where: { $0.id == id }) else { return }
        if record.state == .failed {
            throw RemoteProviderError.invalidResponse(record.errorMessage ?? "Transfer failed.")
        }
        if record.state == .cancelled {
            throw CancellationError()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              var decoded = try? JSONDecoder().decode([TransferRecord].self, from: data) else { return }
        var changed = false
        for index in decoded.indices {
            let state = decoded[index].state
            let wasInterrupted = state == .running || state == .queued || state == .paused
            guard wasInterrupted else { continue }
            if decoded[index].operationKind == .serverToServer {
                if state == .paused {
                    // A paused server transfer must have a durable continuation
                    // contract. Do not restore an invalid/legacy paused record as
                    // an action that the list cannot actually resume.
                    guard decoded[index].supportsResuming else {
                        decoded[index].state = .failed
                        decoded[index].errorMessage = "This transfer cannot be resumed automatically."
                        changed = true
                        continue
                    }
                    if decoded[index].commitPending == true {
                        // A commit marker represents an in-flight finalization,
                        // not a user pause. Let the normal pending-resume path
                        // reconcile it after the next launch.
                        decoded[index].state = .queued
                        decoded[index].errorMessage = nil
                        changed = true
                    }
                } else {
                    decoded[index].state = .queued
                    decoded[index].errorMessage = nil
                    changed = true
                }
            } else {
                decoded[index].state = .failed
                decoded[index].errorMessage = "This local transfer was interrupted and cannot be resumed automatically."
                decoded[index].isResumable = false
                decoded[index].commitPending = false
                decoded[index].commitDestinationExisted = nil
                changed = true
            }
        }
        records = decoded
        if changed {
            persistNow()
        }
    }

    private func schedulePersistence() {
        guard pendingPersistenceTask == nil else { return }
        pendingPersistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: TransferEngine.progressPersistenceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow() {
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        for id in Array(progressSnapshots.keys) {
            flushProgress(for: id, token: nil)
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private actor TransferFileReader {
    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    func read(upToCount count: Int) throws -> Data? {
        try handle.read(upToCount: count)
    }

    func close() {
        try? handle.close()
    }
}

private actor TransferFileWriter {
    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    func close() {
        try? handle.close()
    }
}
