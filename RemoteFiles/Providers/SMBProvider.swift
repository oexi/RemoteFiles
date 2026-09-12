import Foundation
import SMBClient

final class SMBProvider: RemoteFileProvider, RemoteChunkReadableProvider, RemoteChunkWritableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .createDirectory, .delete, .move, .randomRead, .randomWrite, .resume, .accessControl])

    private let credential: Credential?
    private let client: SMBClient
    private var connected = false
    private var chunkFileIDs: [String: Data] = [:]

    init(profile: ConnectionProfile, credential: Credential?) {
        self.profile = profile
        self.credential = credential
        client = SMBClient(host: profile.host, port: profile.port)
    }

    func connect() async throws {
        guard !profile.share.isEmpty else {
            throw RemoteProviderError.invalidConfiguration("SMB requires a share name.")
        }
        _ = try await client.login(
            username: credential?.username ?? profile.username,
            password: credential?.password,
            domain: profile.domain.isEmpty ? nil : profile.domain
        )
        try await client.connectShare(profile.share)
        connected = true
    }

    func disconnect() async {
        guard connected else { return }
        for fileID in chunkFileIDs.values { _ = try? await client.session.close(fileId: fileID) }
        chunkFileIDs.removeAll()
        _ = try? await client.disconnectShare()
        _ = try? await client.logoff()
        connected = false
    }

    func list(path: String) async throws -> [RemoteItem] {
        try await ensureConnected()
        return try await client.listDirectory(path: smbPath(path)).compactMap { file in
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
        try await ensureConnected()
        let stat = try await client.fileStat(path: smbPath(path))
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
        try await ensureConnected()
        try await client.download(path: smbPath(path), localPath: localURL, overwrite: true)
    }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws {
        try await ensureConnected()
        let fileExists = try await client.existFile(path: smbPath(path))
        if !overwrite && fileExists {
            throw RemoteProviderError.conflict("A file already exists at \(path).")
        }
        try await client.upload(localPath: localURL, remotePath: smbPath(path))
    }

    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data {
        try await ensureConnected()
        let reader = client.fileReader(path: smbPath(path))
        do {
            let data = try await reader.read(offset: offset, length: UInt32(clamping: length))
            try await reader.close()
            return data
        } catch {
            try? await reader.close()
            throw error
        }
    }


    func prepareChunkedUpload(path: String, overwrite: Bool, resumeOffset: UInt64) async throws -> UInt64 {
        try await ensureConnected()
        let remotePath = smbPath(path)
        if let old = chunkFileIDs.removeValue(forKey: remotePath) { _ = try? await client.session.close(fileId: old) }

        let existingSize: UInt64? = if let stat = try? await client.fileStat(path: remotePath), !stat.isDirectory { stat.size } else { nil }
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
        chunkFileIDs[remotePath] = response.fileId
        return canResume ? resumeOffset : 0
    }

    func writeChunk(path: String, data: Data, offset: UInt64) async throws {
        try await ensureConnected()
        let remotePath = smbPath(path)
        guard let fileID = chunkFileIDs[remotePath] else {
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

    func finishChunkedUpload(path: String) async throws {
        let remotePath = smbPath(path)
        if let fileID = chunkFileIDs.removeValue(forKey: remotePath) {
            _ = try await client.session.close(fileId: fileID)
        }
    }

    func createDirectory(path: String) async throws {
        try await ensureConnected()
        try await client.createDirectory(path: smbPath(path))
    }

    func remove(path: String, isDirectory: Bool) async throws {
        try await ensureConnected()
        if isDirectory {
            try await client.deleteDirectory(path: smbPath(path))
        } else {
            try await client.deleteFile(path: smbPath(path))
        }
    }

    func move(from: String, to: String, overwrite: Bool) async throws {
        try await ensureConnected()
        let destinationHasFile = try await client.existFile(path: smbPath(to))
        let destinationHasDirectory = try await client.existDirectory(path: smbPath(to))
        if !overwrite && (destinationHasFile || destinationHasDirectory) {
            throw RemoteProviderError.conflict("An item already exists at \(to).")
        }
        try await client.move(from: smbPath(from), to: smbPath(to))
    }

    func accessControl(path: String) async throws -> RemoteAccessControlInfo {
        try await ensureConnected()
        let descriptor = try await client.session.querySecurityDescriptor(
            path: smbPath(path),
            securityInformation: [.owner, .group, .dacl]
        )
        return try WindowsSecurityDescriptorParser.parse(descriptor)
    }

    private func ensureConnected() async throws {
        if !connected { try await connect() }
    }

    private func smbPath(_ path: String) -> String {
        let normalized = RemotePath.normalize(path)
        return normalized == "/" ? "" : String(normalized.dropFirst())
    }
}

