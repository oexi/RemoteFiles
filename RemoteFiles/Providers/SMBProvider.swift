import Foundation
import Network
import SMBClient

final class SMBProvider: RemoteFileProvider, RemoteChunkReadableProvider, RemoteChunkWritableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .createDirectory, .delete, .move, .randomRead, .randomWrite, .resume, .accessControl])

    private enum ConnectionSlot {
        case ready(SMBClient)
        case pending(Task<ClientHandle, Error>)
    }

    // SMBClient is not marked Sendable; it is only handed between tasks
    // through this handle while `stateLock` serializes ownership changes.
    private struct ClientHandle: @unchecked Sendable {
        let client: SMBClient
    }

    private let credential: Credential?
    // SMBClient wraps a single NWConnection that cannot be restarted after it
    // fails or is cancelled, so a dropped connection is replaced by a new
    // client. All mutable connection state is guarded by `stateLock` because
    // browsing, thumbnails and transfers call into the provider concurrently.
    private let stateLock = NSLock()
    private var activeClient: SMBClient?
    private var connectTask: Task<ClientHandle, Error>?
    private var chunkFileIDs: [String: Data] = [:]

    init(profile: ConnectionProfile, credential: Credential?) {
        self.profile = profile
        self.credential = credential
    }

    deinit {
        connectTask?.cancel()
        activeClient?.session.disconnect()
    }

    func connect() async throws {
        _ = try await ensureConnected()
    }

    func disconnect() async {
        let state = stateLock.withLock {
            let state = (client: activeClient, fileIDs: Array(chunkFileIDs.values), task: connectTask)
            activeClient = nil
            connectTask = nil
            chunkFileIDs.removeAll()
            return state
        }
        state.task?.cancel()
        guard let client = state.client else { return }
        for fileID in state.fileIDs { _ = try? await client.session.close(fileId: fileID) }
        _ = try? await client.disconnectShare()
        _ = try? await client.logoff()
        client.session.disconnect()
    }

    func list(path: String) async throws -> [RemoteItem] {
        let files = try await withClient(retryOnDisconnect: true) { client in
            try await client.listDirectory(path: self.smbPath(path))
        }
        return files.compactMap { file in
            guard file.name != ".", file.name != ".." else { return nil }
            let remotePath = RemotePath.join(path, file.name)
            return RemoteItem(
                name: file.name,
                path: remotePath,
                kind: file.isDirectory ? .directory : .file,
                size: file.isDirectory ? nil : Int64(clamping: file.size),
                modifiedAt: file.lastWriteTime,
                createdAt: file.creationTime,
                isHidden: file.isHidden || file.name.hasPrefix("."),
                revision: .init(modifiedAt: file.lastWriteTime, size: Int64(clamping: file.size))
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func attributes(path: String) async throws -> RemoteItem {
        let stat: FileStat
        do {
            stat = try await withClient(retryOnDisconnect: true) { client in
                try await client.fileStat(path: self.smbPath(path))
            }
        } catch {
            throw Self.normalizedAttributeError(error, path: path)
        }
        let name = (path as NSString).lastPathComponent
        return RemoteItem(
            name: name,
            path: RemotePath.normalize(path),
            kind: stat.isDirectory ? .directory : .file,
            size: stat.isDirectory ? nil : Int64(clamping: stat.size),
            modifiedAt: stat.lastWriteTime,
            createdAt: stat.creationTime,
            isHidden: stat.isHidden || name.hasPrefix("."),
            revision: .init(modifiedAt: stat.lastWriteTime, size: Int64(clamping: stat.size))
        )
    }

    func download(path: String, to localURL: URL) async throws {
        try await withClient(retryOnDisconnect: true) { client in
            try await client.download(path: self.smbPath(path), localPath: localURL, overwrite: true)
        }
    }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws {
        try await withClient { client in
            let fileExists = try await client.existFile(path: self.smbPath(path))
            if !overwrite && fileExists {
                throw RemoteProviderError.conflict("A file already exists at \(path).")
            }
            try await client.upload(localPath: localURL, remotePath: self.smbPath(path))
        }
    }

    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data {
        try await withClient(retryOnDisconnect: true) { client in
            let reader = client.fileReader(path: self.smbPath(path))
            do {
                let data = try await reader.read(offset: offset, length: UInt32(clamping: length))
                try await reader.close()
                return data
            } catch {
                try? await reader.close()
                throw error
            }
        }
    }

    func openReadSession(path: String, offset: UInt64) async throws -> (any RemoteChunkReadSession)? {
        let client = try await ensureConnected()
        return SMBReadSession(
            reader: client.fileReader(path: smbPath(path)),
            offset: offset
        )
    }


    func prepareChunkedUpload(path: String, overwrite: Bool, resumeOffset: UInt64) async throws -> UInt64 {
        let remotePath = smbPath(path)
        return try await withClient { client in
            if let old = self.stateLock.withLock({ self.chunkFileIDs.removeValue(forKey: remotePath) }) {
                _ = try? await client.session.close(fileId: old)
            }

            let existingSize: UInt64?
            do {
                let stat = try await client.fileStat(path: remotePath)
                existingSize = stat.isDirectory ? nil : stat.size
            } catch {
                let normalizedError = Self.normalizedAttributeError(error, path: path)
                guard RemoteProviderError.isNotFound(normalizedError) else { throw error }
                existingSize = nil
            }
            let canResume = resumeOffset > 0 && existingSize == resumeOffset
            if !overwrite && !canResume && existingSize != nil {
                throw RemoteProviderError.conflict("A file already exists at \(path).")
            }

            let disposition: Create.CreateDisposition = canResume ? .open : (overwrite ? .overwriteIf : .create)
            let response = try await client.session.create(
                desiredAccess: [.readData, .writeData, .appendData, .readAttributes, .synchronize],
                fileAttributes: [.archive, .normal],
                shareAccess: [.read, .write, .delete],
                createDisposition: disposition,
                createOptions: [],
                name: remotePath
            )
            self.stateLock.withLock { self.chunkFileIDs[remotePath] = response.fileId }
            return canResume ? resumeOffset : 0
        }
    }

    func writeChunk(path: String, data: Data, offset: UInt64) async throws {
        let remotePath = smbPath(path)
        try await withClient { client in
            // Handles are invalidated together with the connection that opened
            // them, so a reconnect surfaces here instead of writing to a stale ID.
            guard let fileID = self.stateLock.withLock({ self.chunkFileIDs[remotePath] }) else {
                throw RemoteProviderError.invalidResponse("SMB chunked upload was not prepared.")
            }
            var written = 0
            while written < data.count {
                let maxSize = max(1, Int(client.session.maxWriteSize))
                let end = min(data.count, written + maxSize)
                let slice = Data(data[written..<end])
                _ = try await client.session.write(data: slice, fileId: fileID, offset: offset + UInt64(written))
                written = end
            }
        }
    }

    func finishChunkedUpload(path: String) async throws {
        let remotePath = smbPath(path)
        let state = stateLock.withLock {
            (client: activeClient, fileID: chunkFileIDs.removeValue(forKey: remotePath))
        }
        if let client = state.client, let fileID = state.fileID {
            _ = try await client.session.close(fileId: fileID)
        }
    }

    /// Releases the SMB CREATE handle left by the legacy chunk writer after a
    /// failed or cancelled transfer. The partial file is intentionally kept:
    /// its confirmed size is the resume checkpoint used by the next attempt.
    /// `disconnect()` also calls this cleanup path for any outstanding handles.
    func abortChunkedUpload(path: String) async {
        let remotePath = smbPath(path)
        let state = stateLock.withLock {
            (client: activeClient, fileID: chunkFileIDs.removeValue(forKey: remotePath))
        }
        guard let client = state.client, let fileID = state.fileID else { return }
        _ = try? await client.session.close(fileId: fileID)
    }

    func createDirectory(path: String) async throws {
        try await withClient { client in
            try await client.createDirectory(path: self.smbPath(path))
        }
    }

    func remove(path: String, isDirectory: Bool) async throws {
        try await withClient { client in
            if isDirectory {
                try await client.deleteDirectory(path: self.smbPath(path))
            } else {
                try await client.deleteFile(path: self.smbPath(path))
            }
        }
    }

    func move(from: String, to: String, overwrite: Bool) async throws {
        try await withClient { client in
            let destinationHasFile = try await client.existFile(path: self.smbPath(to))
            let destinationHasDirectory = try await client.existDirectory(path: self.smbPath(to))
            if !overwrite && (destinationHasFile || destinationHasDirectory) {
                throw RemoteProviderError.conflict("An item already exists at \(to).")
            }
            try await client.move(from: self.smbPath(from), to: self.smbPath(to))
        }
    }

    func accessControl(path: String) async throws -> RemoteAccessControlInfo {
        let descriptor = try await withClient(retryOnDisconnect: true) { client in
            try await client.session.querySecurityDescriptor(
                path: self.smbPath(path),
                securityInformation: [.owner, .group, .dacl]
            )
        }
        return try WindowsSecurityDescriptorParser.parse(descriptor)
    }

    /// Runs `body` on a connected client. A connection-level failure retires
    /// that client so the next call reconnects; idempotent operations may
    /// retry once immediately, which transparently recovers an idle session
    /// the server or network has already dropped.
    private func withClient<T>(
        retryOnDisconnect: Bool = false,
        _ body: (SMBClient) async throws -> T
    ) async throws -> T {
        let client = try await ensureConnected()
        do {
            return try await body(client)
        } catch let error where Self.isConnectionFailure(error) {
            invalidate(client)
            guard retryOnDisconnect else { throw error }
            try Task.checkCancellation()
            let reconnected = try await ensureConnected()
            return try await body(reconnected)
        }
    }

    private func ensureConnected() async throws -> SMBClient {
        let slot: ConnectionSlot = stateLock.withLock {
            if let activeClient { return .ready(activeClient) }
            if let connectTask { return .pending(connectTask) }
            let task = Task { () async throws -> ClientHandle in
                let client = try await self.establishClient()
                return ClientHandle(client: client)
            }
            connectTask = task
            return .pending(task)
        }
        switch slot {
        case .ready(let client):
            return client
        case .pending(let task):
            do {
                let client = try await task.value.client
                stateLock.withLock {
                    if connectTask == task {
                        connectTask = nil
                        activeClient = client
                    }
                }
                return client
            } catch {
                stateLock.withLock {
                    if connectTask == task { connectTask = nil }
                }
                throw error
            }
        }
    }

    private func establishClient() async throws -> SMBClient {
        guard !profile.share.isEmpty else {
            throw RemoteProviderError.invalidConfiguration("SMB requires a share name.")
        }
        let client = SMBClient(host: profile.host, port: profile.port)
        client.onDisconnected = { [weak self, weak client] _ in
            guard let self, let client else { return }
            self.invalidate(client)
        }
        do {
            _ = try await client.login(
                username: credential?.username ?? profile.username,
                password: credential?.password,
                domain: profile.domain.isEmpty ? nil : profile.domain
            )
            try await client.connectShare(profile.share)
        } catch {
            client.session.disconnect()
            throw error
        }
        return client
    }

    /// Logs in without a share and lists the disk shares a user can open, so the
    /// share name does not have to be known in advance.
    static func listShares(
        host: String,
        port: Int,
        username: String,
        password: String?,
        domain: String?
    ) async throws -> [SMBShareInfo] {
        let client = SMBClient(host: host, port: port)
        defer { client.session.disconnect() }
        _ = try await client.login(
            username: username,
            password: password,
            domain: domain?.isEmpty == false ? domain : nil
        )
        let shares = try await client.listShares().map {
            SMBShareInfo(
                name: $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
                comment: $0.comment.trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
                rawType: $0.type.rawValue
            )
        }
        return SMBShareInfo.browsable(shares)
    }

    private func invalidate(_ client: SMBClient) {
        let retired = stateLock.withLock {
            guard activeClient === client else { return false }
            activeClient = nil
            chunkFileIDs.removeAll()
            return true
        }
        if retired { client.session.disconnect() }
    }

    static func isConnectionFailure(_ error: Error) -> Bool {
        if error is ConnectionError || error is NWError { return true }
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain else { return false }
        let codes: Set<Int32> = [ECONNRESET, ECONNABORTED, ENOTCONN, EPIPE, ETIMEDOUT, ENETDOWN, ENETUNREACH, EHOSTUNREACH]
        return codes.contains(Int32(nsError.code))
    }

    private func smbPath(_ path: String) -> String {
        let normalized = RemotePath.normalize(path)
        return normalized == "/" ? "" : String(normalized.dropFirst())
    }

    private static func normalizedAttributeError(_ error: Error, path: String) -> Error {
        guard let response = error as? ErrorResponse else { return error }
        let status = NTStatus(response.header.status)
        guard status == .objectNameNotFound ||
                status == .objectPathNotFound ||
                status == .noSuchFile else {
            return error
        }
        return RemoteProviderError.notFound("The remote item was not found at \(path).")
    }
}

private final class SMBReadSession: RemoteChunkReadSession, @unchecked Sendable {
    private let reader: FileReader
    private var offset: UInt64
    private var isClosed = false

    init(reader: FileReader, offset: UInt64) {
        self.reader = reader
        self.offset = offset
    }

    func read(length: Int) async throws -> Data {
        guard length > 0, !isClosed else { return Data() }
        let data = try await reader.read(offset: offset, length: UInt32(clamping: length))
        offset += UInt64(data.count)
        return data
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        try? await reader.close()
    }
}

struct SMBShareInfo: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let comment: String
    /// The SHARE_INFO_1 `shi1_type` value.
    let rawType: UInt32

    /// The base type sits in the low bits (STYPE_DISKTREE = 0, printer = 1, device = 2,
    /// IPC = 3); higher bits are flags such as STYPE_CLUSTER_FS that a disk share may carry.
    var isDiskShare: Bool { rawType & 0xFF == 0 }
    /// STYPE_SPECIAL marks administrative shares such as C$ and ADMIN$.
    var isSpecial: Bool { rawType & 0x8000_0000 != 0 || name.hasSuffix("$") }

    static func browsable(_ shares: [SMBShareInfo]) -> [SMBShareInfo] {
        shares
            .filter { $0.isDiskShare && !$0.isSpecial }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
