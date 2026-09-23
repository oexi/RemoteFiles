import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

final class SFTPProvider: RemoteFileProvider, RemoteChunkReadableProvider, RemoteChunkWritableProvider, RemoteSymbolicLinkInspecting, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .createDirectory, .delete, .move, .randomRead, .randomWrite, .resume, .permissions, .symbolicLinks])

    // Citadel's SFTPFile.write() currently splits writes into 32,000-byte
    // requests and waits for each response before sending the next one. Keep
    // requests at that boundary and pipeline a bounded number of them so a
    // high-latency connection can keep its SSH/SFTP window full. The same
    // request size is used for reads because SFTP servers commonly cap a READ
    // response to roughly the same payload size.
    static let sftpRequestSize = 32_000
    static let maxInFlightRequests = 16
    private static let transferBufferSize = 1_048_576

    // Citadel's SSHClient is not marked Sendable; access is serialized by
    // `stateLock` and the client itself is internally event-loop confined.
    private struct Connection: @unchecked Sendable {
        let ssh: SSHClient
        let sftp: SFTPClient
        let keepAlive: Task<Void, Never>

        func close() async {
            keepAlive.cancel()
            try? await sftp.close()
            try? await ssh.close()
        }
    }

    private static let keepAliveInterval: UInt64 = 30_000_000_000

    private enum ConnectionSlot {
        case ready(SFTPClient)
        case pending(Task<Connection, Error>)
    }

    private let credential: Credential?
    // Browsing, thumbnails and transfers share one provider concurrently.
    // Connection state is guarded by `stateLock`, and concurrent callers share
    // one in-flight connection attempt instead of each opening an SSH session.
    private let stateLock = NSLock()
    private var connection: Connection?
    private var connectTask: Task<Connection, Error>?

    init(profile: ConnectionProfile, credential: Credential?) {
        self.profile = profile
        self.credential = credential
    }

    // Anything still using the provider (a browser, an open editor, an
    // offline pin) keeps it alive, so the SSH session is closed exactly when
    // the last user lets go instead of lingering for the life of the app.
    deinit {
        connectTask?.cancel()
        if let connection {
            Task { await connection.close() }
        }
    }

    func connect() async throws {
        _ = try await client()
    }

    func disconnect() async {
        let state = stateLock.withLock {
            let state = (connection: connection, task: connectTask)
            connection = nil
            connectTask = nil
            return state
        }
        state.task?.cancel()
        await state.connection?.close()
    }

    func list(path: String) async throws -> [RemoteItem] {
        let sftp = try await client()
        let normalized = RemotePath.normalize(path)
        do {
            let responses = try await sftp.listDirectory(atPath: normalized)
            return responses.flatMap(\.components).compactMap { component in
                guard component.filename != ".", component.filename != ".." else { return nil }
                let kind = Self.kind(from: component.attributes.permissions)
                let size = component.attributes.size.map { Int64(clamping: $0) }
                let modified = component.attributes.accessModificationTime?.modificationTime
                return RemoteItem(
                    name: component.filename,
                    path: RemotePath.join(path, component.filename),
                    kind: kind,
                    size: kind == .directory ? nil : size,
                    modifiedAt: modified,
                    isHidden: component.filename.hasPrefix("."),
                    permissions: component.attributes.permissions.map { $0 & 0o7777 },
                    revision: .init(modifiedAt: modified, size: size)
                )
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } catch {
            throw Self.normalizedSFTPError(error, operation: "list \(normalized)")
        }
    }

    func attributes(path: String) async throws -> RemoteItem {
        let normalized = RemotePath.normalize(path)
        let attributes: SFTPFileAttributes
        do {
            attributes = try await client().getAttributes(at: normalized)
        } catch {
            throw Self.normalizedSFTPError(error, operation: "read attributes for \(normalized)")
        }
        let name = (path as NSString).lastPathComponent
        let kind = Self.kind(from: attributes.permissions)
        let size = attributes.size.map { Int64(clamping: $0) }
        let modified = attributes.accessModificationTime?.modificationTime
        return RemoteItem(
            name: name,
            path: RemotePath.normalize(path),
            kind: kind,
            size: kind == .directory ? nil : size,
            modifiedAt: modified,
            isHidden: name.hasPrefix("."),
            permissions: attributes.permissions.map { $0 & 0o7777 },
            revision: .init(modifiedAt: modified, size: size)
        )
    }

    func isSymbolicLink(path: String) async throws -> Bool {
        // Citadel only exposes STAT, which follows links. READDIR reports the
        // link itself, so look the entry up in its parent listing.
        let normalized = RemotePath.normalize(path)
        guard normalized != "/" else { return false }
        let siblings = try await list(path: RemotePath.parent(normalized))
        return siblings.first { $0.path == normalized }?.kind == .symbolicLink
    }

    func setPermissions(path: String, permissions: UInt32) async throws {
        let normalized = RemotePath.normalize(path)
        do {
            var attributes = SFTPFileAttributes()
            attributes.permissions = permissions & 0o7777
            try await client().setAttributes(at: normalized, to: attributes)
        } catch {
            throw Self.normalizedSFTPError(error, operation: "change permissions on \(normalized)")
        }
    }

    func download(path: String, to localURL: URL) async throws {
        let sftp = try await client()
        let normalized = RemotePath.normalize(path)
        let expectedSize: UInt64?
        do {
            let remoteAttributes = try await sftp.getAttributes(at: normalized)
            expectedSize = remoteAttributes.size
        } catch {
            let normalizedError = Self.normalizedSFTPError(
                error,
                operation: "read attributes for \(normalized)"
            )
            if RemoteProviderError.isNotFound(normalizedError) {
                expectedSize = nil
            } else {
                throw normalizedError
            }
        }
        try? FileManager.default.removeItem(at: localURL)
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: localURL)
        defer { try? output.close() }

        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: normalized, flags: .read)
        } catch {
            throw Self.normalizedSFTPError(error, operation: "open \(normalized) for reading")
        }
        do {
            try await Self.copyPipelined(
                file: file,
                expectedSize: expectedSize,
                to: output,
                path: normalized
            )

            // Embedded SFTP servers can return a non-OK status for CLOSE even when every
            // requested byte was transferred successfully. A completed download should not
            // be discarded solely because CLOSE is quirky.
            try? await file.close()
        } catch {
            try? await file.close()
            throw Self.normalizedSFTPError(error, operation: "download \(normalized)")
        }
    }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws {
        let sftp = try await client()
        let normalized = RemotePath.normalize(path)
        let flags: SFTPOpenFileFlags = overwrite ? [.write, .create, .truncate] : [.write, .create, .forceCreate]
        let input = try FileHandle(forReadingFrom: localURL)
        defer { try? input.close() }
        let localSize: Int64?
        if let values = try? localURL.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            localSize = Int64(size)
        } else {
            localSize = nil
        }
        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: normalized, flags: flags)
        } catch {
            throw Self.normalizedSFTPError(error, operation: "open \(normalized) for writing")
        }

        do {
            var offset: UInt64 = 0
            while let data = try input.read(upToCount: Self.transferBufferSize), !data.isEmpty {
                try await Self.writePipelined(
                    file: file,
                    client: sftp,
                    path: normalized,
                    data: data,
                    at: offset
                )
                offset += UInt64(data.count)
            }

            do {
                try await file.close()
            } catch {
                if let localSize {
                    let remote = try await attributes(path: normalized)
                    if remote.size == localSize { return }
                }
                throw error
            }
        } catch let recovery as SFTPWriteRecoveryError {
            try? await file.close()
            try? await sftp.remove(at: normalized)
            throw recovery
        } catch {
            try? await file.close()
            throw Self.normalizedSFTPError(error, operation: "upload \(normalized)")
        }
    }

    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data {
        let sftp = try await client()
        let normalized = RemotePath.normalize(path)
        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: normalized, flags: .read)
        } catch {
            throw Self.normalizedSFTPError(error, operation: "open \(normalized) for reading")
        }
        do {
            let requestedLength = max(0, length)
            let buffer = try await Self.readPipelined(
                file: file,
                offset: offset,
                length: requestedLength,
                path: normalized
            )
            try? await file.close()
            return buffer
        } catch {
            try? await file.close()
            throw Self.normalizedSFTPError(error, operation: "read \(normalized)")
        }
    }

    func openReadSession(path: String, offset: UInt64) async throws -> (any RemoteChunkReadSession)? {
        let sftp = try await client()
        let normalized = RemotePath.normalize(path)
        do {
            let file = try await sftp.openFile(filePath: normalized, flags: .read)
            return SFTPReadSession(file: file, path: normalized, offset: offset)
        } catch {
            throw Self.normalizedSFTPError(error, operation: "open \(normalized) for streaming read")
        }
    }

    func prepareChunkedUpload(path: String, overwrite: Bool, resumeOffset: UInt64) async throws -> UInt64 {
        let normalized = RemotePath.normalize(path)
        let sftp = try await client()

        if resumeOffset > 0 {
            do {
                let existing = try await attributes(path: normalized)
                if UInt64(max(0, existing.size ?? 0)) == resumeOffset {
                    return resumeOffset
                }
            } catch {
                guard RemoteProviderError.isNotFound(error) else { throw error }
            }
        }

        let flags: SFTPOpenFileFlags = overwrite ? [.write, .create, .truncate] : [.write, .create, .forceCreate]
        try await sftp.withFile(filePath: normalized, flags: flags) { _ in }
        return 0
    }

    func openWriteSession(
        path: String,
        overwrite: Bool,
        resumeOffset: UInt64
    ) async throws -> (session: any RemoteChunkWriteSession, offset: UInt64)? {
        let normalized = RemotePath.normalize(path)
        let sftp = try await client()

        let safeResumeOffset: UInt64
        let flags: SFTPOpenFileFlags
        if resumeOffset > 0 {
            do {
                let existing = try await attributes(path: normalized)
                if UInt64(max(0, existing.size ?? 0)) == resumeOffset {
                    safeResumeOffset = resumeOffset
                    flags = [.write]
                } else {
                    safeResumeOffset = 0
                    flags = overwrite ? [.write, .create, .truncate] : [.write, .create, .forceCreate]
                }
            } catch {
                guard RemoteProviderError.isNotFound(error) else { throw error }
                safeResumeOffset = 0
                flags = overwrite ? [.write, .create, .truncate] : [.write, .create, .forceCreate]
            }
        } else {
            safeResumeOffset = 0
            flags = overwrite ? [.write, .create, .truncate] : [.write, .create, .forceCreate]
        }

        do {
            let file = try await sftp.openFile(filePath: normalized, flags: flags)
            return (
                session: SFTPWriteSession(file: file, client: sftp, path: normalized),
                offset: safeResumeOffset
            )
        } catch {
            throw Self.normalizedSFTPError(error, operation: "open \(normalized) for streaming write")
        }
    }

    func writeChunk(path: String, data: Data, offset: UInt64) async throws {
        let sftp = try await client()
        let normalized = RemotePath.normalize(path)
        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: normalized, flags: .write)
        } catch {
            throw Self.normalizedSFTPError(error, operation: "open \(normalized) for chunk write")
        }
        do {
            try await Self.writePipelined(
                file: file,
                client: sftp,
                path: normalized,
                data: data,
                at: offset
            )
            do {
                try await file.close()
            } catch let status as SFTPMessage.Status where status.errorCode == .eof {
                // Some SFTP servers report EOF while closing a successfully-written handle.
                // The transfer engine verifies the final destination size afterwards.
            }
        } catch let recovery as SFTPWriteRecoveryError {
            try? await file.close()
            try? await sftp.remove(at: normalized)
            throw recovery
        } catch {
            try? await file.close()
            throw Self.normalizedSFTPError(error, operation: "write \(normalized)")
        }
    }

    func createDirectory(path: String) async throws {
        let normalized = RemotePath.normalize(path)
        do {
            try await client().createDirectory(atPath: normalized)
        } catch {
            throw Self.normalizedSFTPError(error, operation: "create directory \(normalized)")
        }
    }

    func remove(path: String, isDirectory: Bool) async throws {
        let sftp = try await client()
        let normalized = RemotePath.normalize(path)
        do {
            if isDirectory { try await sftp.rmdir(at: normalized) }
            else { try await sftp.remove(at: normalized) }
        } catch {
            throw Self.normalizedSFTPError(error, operation: "remove \(normalized)")
        }
    }

    func move(from: String, to: String, overwrite: Bool) async throws {
        if !overwrite {
            do {
                _ = try await attributes(path: to)
                throw RemoteProviderError.conflict("An item already exists at \(to).")
            } catch {
                guard RemoteProviderError.isNotFound(error) else { throw error }
            }
        }
        let source = RemotePath.normalize(from)
        let destination = RemotePath.normalize(to)
        do {
            try await client().rename(at: source, to: destination)
        } catch {
            throw Self.normalizedSFTPError(error, operation: "rename \(source) to \(destination)")
        }
    }

    /// Returns a live SFTP client, reconnecting when the previous SSH session
    /// was closed by the server, an idle timeout or the app being suspended.
    private func client() async throws -> SFTPClient {
        let (stale, slot) = stateLock.withLock { () -> (Connection?, ConnectionSlot) in
            if let connection, connection.ssh.isConnected, connection.sftp.isActive {
                return (nil, .ready(connection.sftp))
            }
            let previous = connection
            connection = nil
            if let connectTask { return (previous, .pending(connectTask)) }
            let task = Task { try await self.establishConnection() }
            connectTask = task
            return (previous, .pending(task))
        }
        if let stale {
            await stale.close()
        }
        switch slot {
        case .ready(let sftp):
            return sftp
        case .pending(let task):
            do {
                let established = try await task.value
                stateLock.withLock {
                    if connectTask == task {
                        connectTask = nil
                        connection = established
                    }
                }
                return established.sftp
            } catch {
                stateLock.withLock {
                    if connectTask == task { connectTask = nil }
                }
                throw error
            }
        }
    }

    private func establishConnection() async throws -> Connection {
        let username = credential?.username ?? profile.username
        guard !username.isEmpty else {
            throw RemoteProviderError.authenticationRequired
        }
        let authentication = try makeAuthentication(username: username)
        let validator = TOFUHostKeyValidator(host: profile.host, port: profile.port)
        var settings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { authentication },
            hostKeyValidator: .custom(validator)
        )
        // NIOSSH on its own only offers AES-GCM ciphers, ECDH key exchange
        // and Ed25519/ECDSA host keys. Dropbear (OpenWrt, many NAS and
        // embedded boxes) supports none of those ciphers, so the handshake
        // fails with keyExchangeNegotiationFailure. Citadel's extended set
        // adds aes128-ctr, diffie-hellman-group14 and ssh-rsa.
        settings.algorithms = .all
        let ssh: SSHClient
        do {
            ssh = try await SSHClient.connect(to: settings)
        } catch {
            throw Self.normalizedSSHError(error)
        }
        let sftp: SFTPClient
        do {
            sftp = try await ssh.openSFTP()
        } catch {
            try? await ssh.close()
            throw error
        }
        // NAT gateways and servers drop idle SSH sessions; a cheap request
        // every 30 s keeps the session open while the app is in use. The loop
        // holds the client weakly and stops once the session is gone.
        let keepAlive = Task { [weak sftp] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.keepAliveInterval)
                guard !Task.isCancelled, let sftp, sftp.isActive else { return }
                do {
                    _ = try await sftp.getRealPath(atPath: ".")
                } catch {
                    return
                }
            }
        }
        return Connection(ssh: ssh, sftp: sftp, keepAlive: keepAlive)
    }

    private func makeAuthentication(username: String) throws -> SSHAuthenticationMethod {
        if let privateKey = credential?.privateKey, !privateKey.isEmpty {
            guard let keyString = String(data: privateKey, encoding: .utf8) else {
                throw RemoteProviderError.invalidConfiguration("The SFTP private key is not valid UTF-8 text.")
            }
            let passphrase = credential?.privateKeyPassphrase.flatMap { value in
                value.isEmpty ? nil : Data(value.utf8)
            }
            return try SSHPrivateKeyLoader.authenticationMethod(
                username: username,
                key: keyString,
                passphrase: passphrase
            )
        }

        guard let password = credential?.password, !password.isEmpty else {
            throw RemoteProviderError.authenticationRequired
        }
        return .passwordBased(username: username, password: password)
    }

    private static func kind(from permissions: UInt32?) -> RemoteItemKind {
        guard let permissions else { return .file }
        switch permissions & 0o170000 {
        case 0o040000: return .directory
        case 0o120000: return .symbolicLink
        default: return .file
        }
    }

    private struct SFTPReadResult: Sendable {
        let index: Int
        let requestedLength: Int
        let data: Data
    }

    enum ReadBatchDisposition: Equatable {
        case continueBatch
        case restartBatch
        case endOfFile
        case finished
    }

    static func consumeReadResponse(
        data: Data,
        requestedLength: Int,
        into result: inout Data,
        currentOffset: inout UInt64,
        remaining: inout Int
    ) throws -> ReadBatchDisposition {
        guard data.count <= requestedLength else {
            throw RemoteProviderError.invalidResponse("The SFTP server returned more data than requested.")
        }
        guard data.isEmpty == false else { return .endOfFile }
        guard data.count <= remaining else {
            throw RemoteProviderError.invalidResponse("The SFTP read response exceeded the requested range.")
        }
        result.append(data)
        currentOffset += UInt64(data.count)
        remaining -= data.count
        if remaining == 0 { return .finished }
        return data.count < requestedLength ? .restartBatch : .continueBatch
    }

    // SFTPFile is not marked Sendable by Citadel, but its operations are
    // request/response based and SFTPClient deliberately supports multiple
    // request IDs in flight on the same channel. The provider owns the file
    // handle for the duration of each bounded task group and never closes it
    // until all children have completed.
    private final class ConcurrentFile: @unchecked Sendable {
        let file: SFTPFile

        init(file: SFTPFile) {
            self.file = file
        }
    }

    private static func copyPipelined(
        file: SFTPFile,
        expectedSize: UInt64?,
        to output: FileHandle,
        path: String
    ) async throws {
        var offset: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let requestLength: Int
            if let expectedSize {
                guard offset < expectedSize else { return }
                requestLength = Int(min(UInt64(transferBufferSize), expectedSize - offset))
            } else {
                requestLength = transferBufferSize
            }

            let data = try await readPipelined(
                file: file,
                offset: offset,
                length: requestLength,
                path: path
            )
            if data.isEmpty {
                if expectedSize != nil {
                    throw RemoteProviderError.invalidResponse(
                        "The SFTP server ended the file before the advertised size was reached."
                    )
                }
                return
            }
            try output.write(contentsOf: data)
            offset += UInt64(data.count)

            if let expectedSize, offset > expectedSize {
                throw RemoteProviderError.invalidResponse(
                    "The SFTP server returned more data than the advertised file size."
                )
            }
        }
    }

    private static func readPipelined(
        file: SFTPFile,
        offset: UInt64,
        length: Int,
        path: String
    ) async throws -> Data {
        guard length >= 0 else {
            throw RemoteProviderError.invalidConfiguration("The SFTP read length cannot be negative.")
        }
        guard length > 0 else { return Data() }
        guard UInt64(length) <= UInt64.max - offset else {
            throw RemoteProviderError.invalidConfiguration("The SFTP read offset overflows the file range.")
        }

        let concurrentFile = ConcurrentFile(file: file)
        var result = Data()
        result.reserveCapacity(length)
        var currentOffset = offset
        var remaining = length

        while remaining > 0 {
            try Task.checkCancellation()
            let requestCount = min(
                maxInFlightRequests,
                ((remaining - 1) / sftpRequestSize) + 1
            )
            var requestLengths: [Int] = []
            requestLengths.reserveCapacity(requestCount)
            var batchRemaining = remaining
            for _ in 0..<requestCount {
                let requestLength = min(sftpRequestSize, batchRemaining)
                requestLengths.append(requestLength)
                batchRemaining -= requestLength
            }

            let batch = try await readBatch(
                file: concurrentFile,
                offset: currentOffset,
                requestLengths: requestLengths,
                path: path
            )
            var restartBatch = false
            for response in batch {
                switch try consumeReadResponse(
                    data: response.data,
                    requestedLength: response.requestedLength,
                    into: &result,
                    currentOffset: &currentOffset,
                    remaining: &remaining
                ) {
                case .endOfFile:
                    return result
                case .restartBatch:
                    // A short response is legal at EOF and is also permitted
                    // by SFTP implementations that cap READ payloads. Discard
                    // later speculative responses and retry from the exact
                    // byte reached so no gap can enter the output.
                    restartBatch = true
                case .finished:
                    break
                case .continueBatch:
                    continue
                }
                break
            }
            if restartBatch { continue }
            if batch.count != requestLengths.count {
                return result
            }
        }
        return result
    }

    private static func readBatch(
        file: ConcurrentFile,
        offset: UInt64,
        requestLengths: [Int],
        path: String
    ) async throws -> [SFTPReadResult] {
        let groupResult = try await withThrowingTaskGroup(of: SFTPReadResult.self) { group in
            for (index, requestLength) in requestLengths.enumerated() {
                let requestOffset = offset + UInt64(index * sftpRequestSize)
                group.addTask {
                    try Task.checkCancellation()
                    let buffer = try await file.file.read(
                        from: requestOffset,
                        length: UInt32(requestLength)
                    )
                    return SFTPReadResult(
                        index: index,
                        requestedLength: requestLength,
                        data: Data(buffer.readableBytesView)
                    )
                }
            }

            var results = Array<SFTPReadResult?>(repeating: nil, count: requestLengths.count)
            do {
                while let result = try await group.next() {
                    results[result.index] = result
                }
            } catch {
                group.cancelAll()
                throw error
            }
            return results.compactMap { $0 }
        }
        guard groupResult.count == requestLengths.count else {
            throw RemoteProviderError.invalidResponse(
                "The SFTP read pipeline returned an incomplete batch for \(path)."
            )
        }
        return groupResult.sorted { $0.index < $1.index }
    }

    private struct SFTPWriteRecoveryError: LocalizedError {
        let path: String
        let original: Error
        let rollback: Error
        let cleanup: Error

        var errorDescription: String? {
            "SFTP write failed and the partial file could not be made safe for resume at \(path). Original error: \(original.localizedDescription). Rollback error: \(rollback.localizedDescription). Cleanup error: \(cleanup.localizedDescription)."
        }
    }

    private static func truncate(
        file: SFTPFile,
        to offset: UInt64
    ) async throws {
        var attributes = SFTPFileAttributes()
        attributes.size = offset
        try await file.setAttributes(to: attributes)
    }

    static func writeBatchOffset(baseOffset: UInt64, batchStart: Int) -> UInt64? {
        guard batchStart >= 0 else { return nil }
        let relativeOffset = UInt64(batchStart)
        guard relativeOffset <= UInt64.max - baseOffset else { return nil }
        return baseOffset + relativeOffset
    }

    private static func writePipelined(
        file: SFTPFile,
        client: SFTPClient,
        path: String,
        data: Data,
        at offset: UInt64
    ) async throws {
        guard data.isEmpty == false else { return }
        guard UInt64(data.count) <= UInt64.max - offset else {
            throw RemoteProviderError.invalidConfiguration("The SFTP write offset overflows the file range.")
        }

        let concurrentFile = ConcurrentFile(file: file)
        var batchStart = 0
        let batchSize = sftpRequestSize * maxInFlightRequests
        while batchStart < data.count {
            try Task.checkCancellation()
            let batchEnd = min(data.count, batchStart + batchSize)
            guard let batchOffset = Self.writeBatchOffset(
                baseOffset: offset,
                batchStart: batchStart
            ) else {
                throw RemoteProviderError.invalidConfiguration("The SFTP write batch offset overflows the file range.")
            }
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var chunkStart = batchStart
                    while chunkStart < batchEnd {
                        let chunkEnd = min(data.count, chunkStart + sftpRequestSize)
                        let chunk = data.subdata(in: chunkStart..<chunkEnd)
                        let chunkOffset = offset + UInt64(chunkStart)
                        group.addTask {
                            try Task.checkCancellation()
                            var buffer = ByteBufferAllocator().buffer(capacity: chunk.count)
                            buffer.writeBytes(chunk)
                            try await concurrentFile.file.write(buffer, at: chunkOffset)
                        }
                        chunkStart = chunkEnd
                    }

                    do {
                        while let _ = try await group.next() { }
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                }
            } catch {
                do {
                    // All children have completed by the time the task group
                    // throws. Roll back any later successful writes in this
                    // batch so the visible length remains a continuous prefix.
                    try await truncate(file: file, to: batchOffset)
                } catch let rollbackError {
                    // A failed fsetstat leaves the remote length ambiguous.
                    // Close the handle and remove the partial path so a retry
                    // cannot mistake a sparse/extended file for a safe resume.
                    try? await file.close()
                    do {
                        try await client.remove(at: path)
                    } catch let cleanupError {
                        throw SFTPWriteRecoveryError(
                            path: path,
                            original: error,
                            rollback: rollbackError,
                            cleanup: cleanupError
                        )
                    }
                }
                throw error
            }
            batchStart = batchEnd
        }
    }

    // NIOSSHError is a struct, so its bridged NSError text is only
    // "NIOSSH.NIOSSHError error 1". Turn the common handshake failures into
    // something a user can act on.
    static func normalizedSSHError(_ error: Error) -> Error {
        guard let sshError = error as? NIOSSHError else { return error }
        switch sshError.type {
        case .keyExchangeNegotiationFailure:
            return RemoteProviderError.unsupported("The SSH server does not offer a cipher, key exchange or host key algorithm RemoteFiles supports. (\(sshError))")
        case .unsupportedVersion:
            return RemoteProviderError.unsupported("The server does not speak SSH protocol version 2. (\(sshError))")
        case .invalidHostKeyForKeyExchange, .invalidExchangeHashSignature, .unknownPublicKey, .unknownSignature:
            return RemoteProviderError.unsupported("The SSH server's host key could not be verified. (\(sshError))")
        case .tcpShutdown:
            return RemoteProviderError.invalidResponse("The SSH server closed the connection during the handshake. (\(sshError))")
        default:
            return RemoteProviderError.invalidResponse("SSH handshake failed: \(sshError)")
        }
    }

    private static func normalizedSFTPError(_ error: Error, operation: String) -> Error {
        guard let status = error as? SFTPMessage.Status else { return error }
        let serverMessage = status.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = serverMessage.isEmpty ? "" : " Server message: \(serverMessage)"

        switch status.errorCode {
        case .eof:
            return RemoteProviderError.invalidResponse("The SFTP server reported an unexpected end of file while trying to \(operation).\(suffix)")
        case .noSuchFile:
            return RemoteProviderError.notFound("The remote item was not found while trying to \(operation).\(suffix)")
        case .permissionDenied:
            return RemoteProviderError.invalidResponse("The SFTP server denied permission to \(operation).\(suffix)")
        case .unsupportedOperation:
            return RemoteProviderError.unsupported("The SFTP server does not support the operation required to \(operation).\(suffix)")
        default:
            return RemoteProviderError.invalidResponse("The SFTP server returned status \(status.errorCode.rawValue) while trying to \(operation).\(suffix)")
        }
    }

    private final class SFTPReadSession: RemoteChunkReadSession, @unchecked Sendable {
        private let file: SFTPFile
        private let path: String
        private var offset: UInt64
        private var closed = false

        init(file: SFTPFile, path: String, offset: UInt64) {
            self.file = file
            self.path = path
            self.offset = offset
        }

        func read(length: Int) async throws -> Data {
            guard !closed else { return Data() }
            do {
                let data = try await SFTPProvider.readPipelined(
                    file: file,
                    offset: offset,
                    length: length,
                    path: path
                )
                offset += UInt64(data.count)
                return data
            } catch let status as SFTPMessage.Status where status.errorCode == .eof {
                // Some embedded SFTP servers report EOF as an error instead of a normal
                // empty READ response. Treat it as end-of-stream here.
                return Data()
            } catch {
                throw SFTPProvider.normalizedSFTPError(error, operation: "stream \(path)")
            }
        }

        func close() async {
            guard !closed else { return }
            closed = true
            try? await file.close()
        }
    }

    private final class SFTPWriteSession: RemoteChunkWriteSession, @unchecked Sendable {
        private let file: SFTPFile
        private let client: SFTPClient
        private let path: String
        private var closed = false
        private var cleanupRequired = false

        init(file: SFTPFile, client: SFTPClient, path: String) {
            self.file = file
            self.client = client
            self.path = path
        }

        func write(_ data: Data, at offset: UInt64) async throws {
            guard !closed else {
                throw RemoteProviderError.invalidResponse("The SFTP write session for \(path) is already closed.")
            }
            do {
                try await SFTPProvider.writePipelined(
                    file: file,
                    client: client,
                    path: path,
                    data: data,
                    at: offset
                )
            } catch let recovery as SFTPProvider.SFTPWriteRecoveryError {
                cleanupRequired = true
                throw recovery
            } catch {
                throw SFTPProvider.normalizedSFTPError(error, operation: "stream write \(path)")
            }
        }

        func finish() async throws {
            guard !closed else { return }
            closed = true
            do {
                try await file.close()
            } catch let status as SFTPMessage.Status where status.errorCode == .eof {
                // Treat EOF-on-close as a successful close. TransferEngine immediately
                // verifies the destination size, so an incomplete write is still detected.
            } catch {
                throw SFTPProvider.normalizedSFTPError(error, operation: "close \(path) after streaming write")
            }
        }

        func abort() async {
            guard !closed else { return }
            closed = true
            try? await file.close()
            if cleanupRequired {
                try? await client.remove(at: path)
            }
        }
    }
}
