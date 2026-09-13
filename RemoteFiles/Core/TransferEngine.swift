import Foundation
import Combine

@MainActor
final class TransferEngine: ObservableObject {
    @Published private(set) var records: [TransferRecord] = []
    private struct ActiveTask {
        let token: TransferExecutionToken
        let task: Task<Void, Never>
    }

    private var tasks: [UUID: ActiveTask] = [:]
    private var executionOwnership: [UUID: TransferExecutionOwnership] = [:]
    private var pendingRetries: [UUID: ConnectionStore] = [:]
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
            sourceRevision: item.revision
        )
        records.insert(record, at: 0)
        persist()
        start(record: record, item: item, source: source, destination: destination, disconnectSource: false)
    }

    func resumePending(using connections: ConnectionStore) {
        for record in records where record.state == .queued {
            startPersisted(record, using: connections)
        }
    }

    func retry(_ record: TransferRecord, using connections: ConnectionStore) {
        guard let current = records.first(where: { $0.id == record.id }),
              current.state == .failed || current.state == .cancelled else { return }
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

    func cancel(_ record: TransferRecord) {
        guard let current = records.first(where: { $0.id == record.id }),
              current.state == .running || current.state == .queued else { return }
        if let active = tasks[current.id] {
            active.task.cancel()
            executionOwnership[current.id]?.invalidate()
        }
        pendingRetries[current.id] = nil
        update(current.id) {
            $0.state = .cancelled
            $0.errorMessage = nil
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
            let decision = TransferResumePolicy.decision(
                transferredBytes: currentRecord?.transferredBytes,
                persistedRevision: currentRecord?.sourceRevision,
                currentRevision: item.revision
            )
            var canReadChunks = source is any RemoteChunkReadableProvider
            if canReadChunks, let probing = source as? any RemoteChunkReadSupportProbing {
                canReadChunks = try await probing.supportsChunkedReads(path: item.path)
            }
            let canStream = canReadChunks
                && destination is any RemoteChunkWritableProvider
                && destination.capabilities.contains(.move)
                && (item.size.map { $0 >= 0 } ?? false)
            let partialPath = streamPartialPath(for: destinationPath, recordID: id)
            var requestedResumeOffset: UInt64 = 0
            var overwritePartial = false

            if canStream, case .resume = decision,
               let total = item.size, total >= 0,
               let partialItem = try? await destination.attributes(path: partialPath) {
                guard !partialItem.isDirectory else {
                    throw RemoteProviderError.conflict("The transfer partial path is occupied by a directory.")
                }
                if let partialSize = partialItem.size,
                   partialSize >= 0,
                   partialSize <= total,
                   let offset = UInt64(exactly: partialSize) {
                    requestedResumeOffset = offset
                    overwritePartial = offset == 0
                } else {
                    overwritePartial = true
                }
            } else if canStream, decision == .restart,
                      let partialItem = try? await destination.attributes(path: partialPath) {
                guard !partialItem.isDirectory else {
                    throw RemoteProviderError.conflict("The transfer partial path is occupied by a directory.")
                }
                overwritePartial = true
            }

            update(id, token: token) {
                $0.state = .running
                $0.progress = 0.05
                $0.totalBytes = item.size
                $0.sourceRevision = item.revision
                $0.transferredBytes = requestedResumeOffset
            }
            try checkExecution(token, for: id)
            let overwrite = records.first(where: { $0.id == id })?.overwrite ?? false
            if canStream,
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
                try checkExecution(token, for: id)
                try await destination.move(from: partialPath, to: destinationPath, overwrite: overwrite)
            } else {
                update(id, token: token) { $0.transferredBytes = 0; $0.progress = 0.05 }
                try checkExecution(token, for: id)
                let tempURL = try await CacheManager.shared.temporaryURL(fileName: item.name)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await source.download(path: item.path, to: tempURL)
                try checkExecution(token, for: id)
                update(id, token: token) { $0.progress = 0.55 }
                try await destination.upload(from: tempURL, to: destinationPath, overwrite: overwrite)
            }
            try checkExecution(token, for: id)
            if let expected = item.size,
               let destinationItem = try? await destination.attributes(path: destinationPath),
               let actual = destinationItem.size,
               expected != actual {
                throw RemoteProviderError.invalidResponse(
                    "Transfer verification failed: expected \(expected) bytes but destination reports \(actual) bytes."
                )
            }
            try checkExecution(token, for: id)
            update(id, token: token) {
                $0.state = .completed
                $0.progress = 1
                $0.errorMessage = nil
            }
        } catch is CancellationError {
            update(id, token: token) {
                $0.state = .cancelled
                $0.errorMessage = nil
            }
        } catch {
            update(id, token: token) {
                $0.state = .failed
                $0.errorMessage = error.localizedDescription
            }
        }
        await destination.disconnect()
        if disconnectSource { await source.disconnect() }
    }

    private func streamPartialPath(for destinationPath: String, recordID: UUID) -> String {
        let name = "." + "remotefiles-\(recordID.uuidString.lowercased()).partial"
        return RemotePath.join(RemotePath.parent(destinationPath), name)
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
        let chunkSize = 1024 * 1024
        let requestedOffset = min(requestedResumeOffset, totalBytes)
        try checkExecution(token, for: recordID)
        let openedWriteSession = try await writer.openWriteSession(
            path: destinationPath,
            overwrite: overwrite,
            resumeOffset: requestedOffset
        )
        try checkExecution(token, for: recordID)
        let writeSession = openedWriteSession?.session
        var offset: UInt64
        if let openedWriteSession {
            offset = openedWriteSession.offset
        } else {
            offset = try await writer.prepareChunkedUpload(
                path: destinationPath,
                overwrite: overwrite,
                resumeOffset: requestedOffset
            )
        }
        try checkExecution(token, for: recordID)
        update(recordID, token: token) {
            $0.transferredBytes = offset
            let fraction = totalBytes == 0 ? 1 : Double(offset) / Double(totalBytes)
            $0.progress = 0.05 + 0.9 * min(1, fraction)
        }

        let readSession = try await reader.openReadSession(path: item.path, offset: offset)
        try checkExecution(token, for: recordID)
        do {
            while offset < totalBytes {
                try checkExecution(token, for: recordID)
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
                if let writeSession {
                    try await writeSession.write(data, at: offset)
                } else {
                    try await writer.writeChunk(path: destinationPath, data: data, offset: offset)
                }
                try checkExecution(token, for: recordID)
                offset += UInt64(data.count)
                let fraction = totalBytes == 0 ? 1 : Double(offset) / Double(totalBytes)
                update(recordID, token: token) {
                    $0.transferredBytes = offset
                    $0.progress = 0.05 + 0.9 * min(1, fraction)
                }
            }
            try checkExecution(token, for: recordID)
            await readSession?.close()
            if let writeSession {
                try await writeSession.finish()
            } else {
                try await writer.finishChunkedUpload(path: destinationPath)
            }
        } catch {
            await readSession?.close()
            await writeSession?.abort()
            throw error
        }
    }

    func clearFinished() {
        let removedIDs = records
            .filter { $0.state == .completed || $0.state == .cancelled }
            .map(\.id)
        for id in removedIDs {
            pendingRetries[id] = nil
            if let active = tasks[id] {
                active.task.cancel()
                executionOwnership[id]?.invalidate()
            } else {
                executionOwnership[id] = nil
            }
        }
        records.removeAll { $0.state == .completed || $0.state == .cancelled }
        persist()
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
        records.removeAll { $0.id == current.id }
        persist()
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

    private func finishExecution(for id: UUID, token: TransferExecutionToken) {
        guard tasks[id]?.token == token else { return }
        // A retry coordinator owns cleanup while it waits for this task to exit.
        guard pendingRetries[id] == nil else { return }
        finishExecutionAfterExit(for: id, token: token)
    }

    private func finishExecutionAfterExit(for id: UUID, token: TransferExecutionToken) {
        guard tasks[id]?.token == token else { return }
        tasks[id] = nil
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
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutation(&records[index])
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              var decoded = try? JSONDecoder().decode([TransferRecord].self, from: data) else { return }
        for index in decoded.indices where decoded[index].state == .running {
            decoded[index].state = .queued
            decoded[index].errorMessage = nil
        }
        records = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
