import Citadel
import Crypto
import Foundation
import NIOCore

final class SFTPProvider: RemoteFileProvider, RemoteChunkReadableProvider, RemoteChunkWritableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .createDirectory, .delete, .move, .randomRead, .randomWrite, .resume, .permissions, .symbolicLinks])

    private let credential: Credential?
    private var ssh: SSHClient?
    private var sftp: SFTPClient?

    init(profile: ConnectionProfile, credential: Credential?) {
        self.profile = profile
        self.credential = credential
    }

    func connect() async throws {
        let username = credential?.username ?? profile.username
        guard !username.isEmpty else {
            throw RemoteProviderError.authenticationRequired
        }
        let authentication = try makeAuthentication(username: username)
        let validator = TOFUHostKeyValidator(host: profile.host, port: profile.port)
        let settings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { authentication },
            hostKeyValidator: .custom(validator)
        )
        let ssh = try await SSHClient.connect(to: settings)
        self.ssh = ssh
        self.sftp = try await ssh.openSFTP()
    }

    func disconnect() async {
        try? await sftp?.close()
        try? await ssh?.close()
        sftp = nil
        ssh = nil
    }

    func list(path: String) async throws -> [RemoteItem] {
        let sftp = try await client()
        let responses = try await sftp.listDirectory(atPath: RemotePath.normalize(path))
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
                revision: .init(modifiedAt: modified, size: size)
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func attributes(path: String) async throws -> RemoteItem {
        let attributes = try await client().getAttributes(at: RemotePath.normalize(path))
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
            revision: .init(modifiedAt: modified, size: size)
        )
    }

    func download(path: String, to localURL: URL) async throws {
        let sftp = try await client()
        try? FileManager.default.removeItem(at: localURL)
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: localURL)
        defer { try? output.close() }
        try await sftp.withFile(filePath: RemotePath.normalize(path), flags: .read) { file in
            var offset: UInt64 = 0
            while true {
                let buffer = try await file.read(from: offset, length: 1_048_576)
                let count = buffer.readableBytes
                if count == 0 { break }
                try output.write(contentsOf: Data(buffer.readableBytesView))
                offset += UInt64(count)
            }
        }
    }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws {
        let sftp = try await client()
        let flags: SFTPOpenFileFlags = overwrite ? [.write, .create, .truncate] : [.write, .create, .forceCreate]
        let input = try FileHandle(forReadingFrom: localURL)
        defer { try? input.close() }
        try await sftp.withFile(filePath: RemotePath.normalize(path), flags: flags) { file in
            var offset: UInt64 = 0
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await file.write(buffer, at: offset)
                offset += UInt64(data.count)
            }
        }
    }

    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data {
        let sftp = try await client()
        return try await sftp.withFile(filePath: RemotePath.normalize(path), flags: .read) { file in
            let buffer = try await file.read(from: offset, length: UInt32(clamping: length))
            return Data(buffer.readableBytesView)
        }
    }

    func prepareChunkedUpload(path: String, overwrite: Bool) async throws {
        let sftp = try await client()
        let flags: SFTPOpenFileFlags = overwrite ? [.write, .create, .truncate] : [.write, .create, .forceCreate]
        try await sftp.withFile(filePath: RemotePath.normalize(path), flags: flags) { _ in }
    }

    func writeChunk(path: String, data: Data, offset: UInt64) async throws {
        let sftp = try await client()
        try await sftp.withFile(filePath: RemotePath.normalize(path), flags: .write) { file in
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            try await file.write(buffer, at: offset)
        }
    }

    func createDirectory(path: String) async throws {
        try await client().createDirectory(atPath: RemotePath.normalize(path))
    }

    func remove(path: String, isDirectory: Bool) async throws {
        let sftp = try await client()
        if isDirectory { try await sftp.rmdir(at: RemotePath.normalize(path)) }
        else { try await sftp.remove(at: RemotePath.normalize(path)) }
    }

    func move(from: String, to: String, overwrite: Bool) async throws {
        if !overwrite, (try? await attributes(path: to)) != nil {
            throw RemoteProviderError.conflict("An item already exists at \(to).")
        }
        try await client().rename(at: RemotePath.normalize(from), to: RemotePath.normalize(to))
    }

    private func client() async throws -> SFTPClient {
        if let sftp { return sftp }
        try await connect()
        guard let sftp else { throw RemoteProviderError.notConnected }
        return sftp
    }

    private func makeAuthentication(username: String) throws -> SSHAuthenticationMethod {
        if let privateKey = credential?.privateKey, !privateKey.isEmpty {
            guard let keyString = String(data: privateKey, encoding: .utf8) else {
                throw RemoteProviderError.invalidConfiguration("The SFTP private key is not valid UTF-8 text.")
            }
            let passphrase = credential?.privateKeyPassphrase.flatMap { value in
                value.isEmpty ? nil : Data(value.utf8)
            }
            let keyType = try SSHKeyDetection.detectPrivateKeyType(from: keyString)
            if keyType == .ed25519 {
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: keyString, decryptionKey: passphrase)
                return .ed25519(username: username, privateKey: key)
            }
            if keyType == .rsa {
                let key = try Insecure.RSA.PrivateKey(sshRsa: keyString, decryptionKey: passphrase)
                return .rsa(username: username, privateKey: key)
            }
            throw RemoteProviderError.unsupported("This OpenSSH private-key type is not supported yet. Use Ed25519 or RSA.")
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
}

