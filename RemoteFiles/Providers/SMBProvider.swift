import Foundation
import SMBClient

final class SMBProvider: RemoteFileProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .createDirectory, .delete, .move, .randomRead, .randomWrite, .resume])

    private let credential: Credential?
    private let client: SMBClient
    private var connected = false

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
        try? await client.disconnectShare()
        try? await client.logoff()
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

    private func ensureConnected() async throws {
        if !connected { try await connect() }
    }

    private func smbPath(_ path: String) -> String {
        let normalized = RemotePath.normalize(path)
        return normalized == "/" ? "" : String(normalized.dropFirst())
    }
}

