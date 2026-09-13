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
        if let remoteAttributes = try? await sftp.getAttributes(at: normalized) {
            expectedSize = remoteAttributes.size
        } else {
            expectedSize = nil
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
            var offset: UInt64 = 0
            if let expectedSize {
                while offset < expectedSize {
                    let remaining = expectedSize - offset
                    let requestLength = UInt32(min(UInt64(1_048_576), remaining))
                    let buffer = try await file.read(from: offset, length: requestLength)
                    let count = buffer.readableBytes
                    guard count > 0 else {
                        throw RemoteProviderError.invalidResponse("The SFTP server ended the file before the advertised size was reached.")
                    }
                    try output.write(contentsOf: Data(buffer.readableBytesView))
                    offset += UInt64(count)
                }
            } else {
                while true {
                    let buffer = try await file.read(from: offset, length: 1_048_576)
                    let count = buffer.readableBytes
                    if count == 0 { break }
                    try output.write(contentsOf: Data(buffer.readableBytesView))
                    offset += UInt64(count)
                }
            }

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
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await file.write(buffer, at: offset)
                offset += UInt64(data.count)
            }

            do {
                try await file.close()
            } catch {
                if let localSize,
                   let remote = try? await attributes(path: normalized),
                   remote.size == localSize {
                    return
                }
                throw error
            }
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
            let buffer = try await file.read(from: offset, length: UInt32(clamping: length))
            try? await file.close()
            return Data(buffer.readableBytesView)
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

        if resumeOffset > 0, let existing = try? await attributes(path: normalized),
           UInt64(max(0, existing.size ?? 0)) == resumeOffset {
            return resumeOffset
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
        if resumeOffset > 0,
           let existing = try? await attributes(path: normalized),
           UInt64(max(0, existing.size ?? 0)) == resumeOffset {
            safeResumeOffset = resumeOffset
            flags = [.write]
        } else {
            safeResumeOffset = 0
            flags = overwrite ? [.write, .create, .truncate] : [.write, .create, .forceCreate]
        }

        do {
            let file = try await sftp.openFile(filePath: normalized, flags: flags)
            return (
                session: SFTPWriteSession(file: file, path: normalized),
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
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            try await file.write(buffer, at: offset)
            do {
                try await file.close()
            } catch let status as SFTPMessage.Status where status.errorCode == .eof {
                // Some SFTP servers report EOF while closing a successfully-written handle.
                // The transfer engine verifies the final destination size afterwards.
            }
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
        if !overwrite, (try? await attributes(path: to)) != nil {
            throw RemoteProviderError.conflict("An item already exists at \(to).")
        }
        let source = RemotePath.normalize(from)
        let destination = RemotePath.normalize(to)
        do {
            try await client().rename(at: source, to: destination)
        } catch {
            throw Self.normalizedSFTPError(error, operation: "rename \(source) to \(destination)")
        }
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

    private static func normalizedSFTPError(_ error: Error, operation: String) -> Error {
        guard let status = error as? SFTPMessage.Status else { return error }
        let serverMessage = status.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = serverMessage.isEmpty ? "" : " Server message: \(serverMessage)"

        switch status.errorCode {
        case .eof:
            return RemoteProviderError.invalidResponse("The SFTP server reported an unexpected end of file while trying to \(operation).\(suffix)")
        case .noSuchFile:
            return RemoteProviderError.invalidResponse("The remote file no longer exists while trying to \(operation).\(suffix)")
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
                let buffer = try await file.read(
                    from: offset,
                    length: UInt32(clamping: length)
                )
                let data = Data(buffer.readableBytesView)
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
        private let path: String
        private var closed = false

        init(file: SFTPFile, path: String) {
            self.file = file
            self.path = path
        }

        func write(_ data: Data, at offset: UInt64) async throws {
            guard !closed else {
                throw RemoteProviderError.invalidResponse("The SFTP write session for \(path) is already closed.")
            }
            do {
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await file.write(buffer, at: offset)
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
        }
    }
}

