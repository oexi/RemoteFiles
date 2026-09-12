import Foundation
import Combine

@MainActor
final class TransferEngine: ObservableObject {
    @Published private(set) var records: [TransferRecord] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("RemoteFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("transfers.json")
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
            totalBytes: item.size
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
        guard record.state == .failed || record.state == .cancelled else { return }
        update(record.id) {
            $0.state = .queued
            $0.errorMessage = nil
        }
        startPersisted(recordWithID: record.id, using: connections)
    }

    func cancel(_ record: TransferRecord) {
        tasks[record.id]?.cancel()
        tasks[record.id] = nil
        update(record.id) {
            $0.state = .cancelled
            $0.errorMessage = nil
        }
    }

    private func startPersisted(_ original: TransferRecord, using connections: ConnectionStore) {
        startPersisted(recordWithID: original.id, using: connections)
    }

    private func startPersisted(recordWithID id: UUID, using connections: ConnectionStore) {
        guard tasks[id] == nil,
              let record = records.first(where: { $0.id == id }),
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

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try ProviderFactory.make(for: sourceProfile)
                let destination = try ProviderFactory.make(for: destinationProfile)
                try await source.connect()
                let item = try await source.attributes(path: record.sourcePath)
                self.update(id) { $0.totalBytes = item.size }
                await self.perform(
                    recordID: id,
                    item: item,
                    source: source,
                    destination: destination,
                    destinationPath: record.destinationPath,
                    disconnectSource: true
                )
            } catch is CancellationError {
                self.update(id) { $0.state = .cancelled }
            } catch {
                self.update(id) { $0.state = .failed; $0.errorMessage = error.localizedDescription }
            }
            self.tasks[id] = nil
        }
        tasks[id] = task
    }

    private func start(
        record: TransferRecord,
        item: RemoteItem,
        source: any RemoteFileProvider,
        destination: any RemoteFileProvider,
        disconnectSource: Bool
    ) {
        let id = record.id
        let task = Task { [weak self] in
            guard let self else { return }
            await self.perform(
                recordID: id,
                item: item,
                source: source,
                destination: destination,
                destinationPath: record.destinationPath,
                disconnectSource: disconnectSource
            )
            self.tasks[id] = nil
        }
        tasks[id] = task
    }

    private func perform(
        recordID id: UUID,
        item: RemoteItem,
        source: any RemoteFileProvider,
        destination: any RemoteFileProvider,
        destinationPath: String,
        disconnectSource: Bool
    ) async {
        do {
            update(id) { $0.state = .running; $0.progress = 0.05 }
            try Task.checkCancellation()
            let overwrite = records.first(where: { $0.id == id })?.overwrite ?? false
            if let reader = source as? any RemoteChunkReadableProvider,
               let writer = destination as? any RemoteChunkWritableProvider,
               let total = item.size, total >= 0 {
                try await streamCopy(
                    item: item,
                    totalBytes: UInt64(total),
                    reader: reader,
                    writer: writer,
                    destinationPath: destinationPath,
                    overwrite: overwrite,
                    recordID: id,
                    requestedResumeOffset: records.first(where: { $0.id == id })?.transferredBytes ?? 0
                )
            } else {
                update(id) { $0.transferredBytes = 0; $0.progress = 0.05 }
                let tempURL = try await CacheManager.shared.temporaryURL(fileName: item.name)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await source.download(path: item.path, to: tempURL)
                try Task.checkCancellation()
                update(id) { $0.progress = 0.55 }
                try await destination.upload(from: tempURL, to: destinationPath, overwrite: overwrite)
            }
            try Task.checkCancellation()
            if let expected = item.size,
               let destinationItem = try? await destination.attributes(path: destinationPath),
               let actual = destinationItem.size,
               expected != actual {
                throw RemoteProviderError.invalidResponse(
                    "Transfer verification failed: expected \(expected) bytes but destination reports \(actual) bytes."
                )
            }
            update(id) { $0.state = .completed; $0.progress = 1; $0.errorMessage = nil }
        } catch is CancellationError {
            update(id) { $0.state = .cancelled; $0.errorMessage = nil }
        } catch {
            update(id) { $0.state = .failed; $0.errorMessage = error.localizedDescription }
        }
        await destination.disconnect()
        if disconnectSource { await source.disconnect() }
    }

    private func streamCopy(
        item: RemoteItem,
        totalBytes: UInt64,
        reader: any RemoteChunkReadableProvider,
        writer: any RemoteChunkWritableProvider,
        destinationPath: String,
        overwrite: Bool,
        recordID: UUID,
        requestedResumeOffset: UInt64
    ) async throws {
        let chunkSize = 1024 * 1024
        let requestedOffset = min(requestedResumeOffset, totalBytes)
        let openedWriteSession = try await writer.openWriteSession(
            path: destinationPath,
            overwrite: overwrite,
            resumeOffset: requestedOffset
        )
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
        update(recordID) {
            $0.transferredBytes = offset
            let fraction = totalBytes == 0 ? 1 : Double(offset) / Double(totalBytes)
            $0.progress = 0.05 + 0.9 * min(1, fraction)
        }

        let readSession = try await reader.openReadSession(path: item.path, offset: offset)
        do {
            while offset < totalBytes {
                try Task.checkCancellation()
                let remaining = totalBytes - offset
                let length = Int(min(UInt64(chunkSize), remaining))
                let data: Data
                if let readSession {
                    data = try await readSession.read(length: length)
                } else {
                    data = try await reader.readChunk(path: item.path, offset: offset, length: length)
                }
                guard !data.isEmpty else {
                    throw RemoteProviderError.invalidResponse("The source ended before the expected file size was reached.")
                }
                if let writeSession {
                    try await writeSession.write(data, at: offset)
                } else {
                    try await writer.writeChunk(path: destinationPath, data: data, offset: offset)
                }
                offset += UInt64(data.count)
                let fraction = totalBytes == 0 ? 1 : Double(offset) / Double(totalBytes)
                update(recordID) {
                    $0.transferredBytes = offset
                    $0.progress = 0.05 + 0.9 * min(1, fraction)
                }
            }
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
        records.removeAll { $0.state == .completed || $0.state == .cancelled }
        persist()
    }

    func remove(_ record: TransferRecord) {
        guard record.state != .running, record.state != .queued else { return }
        tasks[record.id]?.cancel()
        tasks[record.id] = nil
        records.removeAll { $0.id == record.id }
        persist()
    }

    private func update(_ id: UUID, _ mutation: (inout TransferRecord) -> Void) {
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

