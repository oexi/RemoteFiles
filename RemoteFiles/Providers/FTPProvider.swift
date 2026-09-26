import FilesProvider
import Foundation

final class FTPProvider: RemoteFileProvider, RemoteChunkReadableProvider, RemoteChunkReadSupportProbing, @unchecked Sendable {
    let profile: ConnectionProfile
    var capabilities: ProviderCapabilities {
        var values: Set<ProviderCapability> = [.list, .read, .write, .createDirectory, .delete, .move, .copy, .resume]
        if chmodSupported { values.insert(.permissions) }
        return ProviderCapabilities(values)
    }

    private let provider: FTPFileProvider
    private var chmodSupported = false

    init(profile: ConnectionProfile, credential: Credential?) throws {
        self.profile = profile
        let scheme: String
        switch profile.protocolType {
        case .ftp:
            scheme = "ftp"
        case .ftps:
            scheme = profile.port == 990 ? "ftps" : "ftpes"
        default:
            throw RemoteProviderError.invalidConfiguration("FTPProvider requires an FTP or FTPS profile.")
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = profile.host
        components.port = profile.port
        components.path = "/"
        guard let baseURL = components.url else {
            throw RemoteProviderError.invalidConfiguration("Invalid FTP host or port.")
        }
        let user = credential?.username ?? profile.username
        let urlCredential = user.isEmpty && credential?.password.isEmpty != false
            ? nil
            : URLCredential(user: user, password: credential?.password ?? "", persistence: .none)
        guard let provider = FTPFileProvider(baseURL: baseURL, mode: .passive, credential: urlCredential) else {
            throw RemoteProviderError.invalidConfiguration("Unable to initialize the FTP client.")
        }
        // FilesProvider's serial STOR path is its fastest and most reliable
        // upload mode. REST mode reconnects for every optimized chunk, which
        // is especially costly on high-latency FTP/FTPS servers.
        provider.uploadByREST = false
        if profile.protocolType == .ftps && !profile.verifyTLS {
            // FilesProvider cannot pin a certificate for FTPS; with
            // verification turned off by the user it accepts any certificate.
            provider.serverTrustPolicy = .disableEvaluation
        }
        self.provider = provider
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.isReachable { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: RemoteProviderError.notConnected) }
            }
        }
        chmodSupported = await detectCHMODSupport()
    }

    func list(path: String) async throws -> [RemoteItem] {
        let objects: [FileObject] = try await withCheckedThrowingContinuation { continuation in
            provider.contentsOfDirectory(path: ftpPath(path)) { objects, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: objects) }
            }
        }
        return objects.map { object in
            RemoteItem(
                name: object.name,
                path: RemotePath.join(path, object.name),
                kind: object.isDirectory ? .directory : (object.isSymLink ? .symbolicLink : .file),
                size: object.isDirectory || object.size < 0 ? nil : object.size,
                modifiedAt: object.modifiedDate,
                createdAt: object.creationDate,
                isHidden: object.isHidden || object.name.hasPrefix("."),
                revision: .init(modifiedAt: object.modifiedDate, size: object.size >= 0 ? object.size : nil)
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func attributes(path: String) async throws -> RemoteItem {
        let normalized = RemotePath.normalize(path)
        guard normalized != "/" else {
            return try await rootAttributes(path: normalized)
        }

        // FilesProvider's MLST/LIST response uses a generic bad-server-response
        // error for a missing item. Listing the parent gives us an affirmative
        // existence check without guessing whether that error means "missing"
        // or a permission/transport failure. Any parent-list error propagates.
        let parentItems = try await list(path: RemotePath.parent(normalized))
        guard let item = Self.findItem(at: normalized, in: parentItems) else {
            throw RemoteProviderError.notFound("The remote item was not found at \(normalized).")
        }
        let permissions = chmodSupported
            ? (try? await unixPermissions(path: normalized))
            : item.permissions
        return RemoteItem(
            name: item.name,
            path: item.path,
            kind: item.kind,
            size: item.size,
            modifiedAt: item.modifiedAt,
            createdAt: item.createdAt,
            isHidden: item.isHidden,
            contentType: item.contentType,
            permissions: permissions ?? item.permissions,
            revision: item.revision
        )
    }

    private func rootAttributes(path: String) async throws -> RemoteItem {
        let object: FileObject
        do {
            object = try await withCheckedThrowingContinuation { continuation in
                provider.attributesOfItem(path: ftpPath(path)) { object, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let object { continuation.resume(returning: object) }
                    else { continuation.resume(throwing: RemoteProviderError.invalidResponse("FTP returned no attributes.")) }
                }
            }
        } catch {
            throw Self.normalizedAttributeError(error, path: path)
        }
        let name = object.name.isEmpty ? (path as NSString).lastPathComponent : object.name
        let permissions = chmodSupported ? (try? await unixPermissions(path: path)) : nil
        return RemoteItem(
            name: name,
            path: RemotePath.normalize(path),
            kind: object.isDirectory ? .directory : (object.isSymLink ? .symbolicLink : .file),
            size: object.isDirectory || object.size < 0 ? nil : object.size,
            modifiedAt: object.modifiedDate,
            createdAt: object.creationDate,
            isHidden: object.isHidden || name.hasPrefix("."),
            permissions: permissions,
            revision: .init(modifiedAt: object.modifiedDate, size: object.size >= 0 ? object.size : nil)
        )
    }

    static func findItem(at path: String, in items: [RemoteItem]) -> RemoteItem? {
        let normalized = RemotePath.normalize(path)
        return items.first { RemotePath.normalize($0.path) == normalized }
    }

    func setPermissions(path: String, permissions: UInt32) async throws {
        guard chmodSupported else {
            throw RemoteProviderError.unsupported("This FTP server does not advertise SITE CHMOD support.")
        }
        guard !path.contains("\r"), !path.contains("\n") else {
            throw RemoteProviderError.invalidConfiguration("The FTP path contains an unsupported line break.")
        }
        let mode = String(format: "%04o", permissions & 0o7777)
        let response = try await controlCommand("SITE CHMOD \(mode) \(ftpPath(path))")
        guard Self.replyCode(response).map({ (200..<300).contains($0) }) == true else {
            throw RemoteProviderError.invalidResponse("The FTP server rejected SITE CHMOD. Server response: \(response)")
        }
    }

    func download(path: String, to localURL: URL) async throws {
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: localURL)
        let _: Void = try await withProviderCancellation { complete, _ in
            self.provider.copyItem(path: self.ftpPath(path), toLocalURL: localURL) { error in
                if let error {
                    complete(.failure(error))
                } else {
                    complete(.success(()))
                }
            }
        }
    }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws {
        // FilesProvider ignores `overwrite` and STOR always replaces, so refuse an existing
        // item here. This is check-then-write; FTP has no exclusive-create command to close
        // the race with another client.
        if !overwrite, try await existingItem(at: path) != nil {
            throw RemoteProviderError.conflict("An item already exists at \(RemotePath.normalize(path)).")
        }
        let _: Void = try await withProviderCancellation { complete, _ in
            self.provider.copyItem(localFile: localURL, to: self.ftpPath(path), overwrite: overwrite) { error in
                if let error {
                    complete(.failure(error))
                } else {
                    complete(.success(()))
                }
            }
        }
    }

    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data {
        try await withProviderCancellation { complete, _ in
            self.provider.contents(path: self.ftpPath(path), offset: Int64(clamping: offset), length: length) { data, error in
                if let error {
                    complete(.failure(error))
                } else {
                    complete(.success(data ?? Data()))
                }
            }
        }
    }

    func supportsChunkedReads(path: String) async throws -> Bool {
        // FTPFileProvider.contents(path:offset:length:) creates a new control
        // and passive data connection for every range. Returning false makes
        // TransferEngine use the provider's one-connection download path,
        // avoiding a login/data-channel handshake for every engine range.
        false
    }

    func createDirectory(path: String) async throws {
        let normalized = RemotePath.normalize(path)
        let name = (normalized as NSString).lastPathComponent
        let parent = RemotePath.parent(normalized)
        try await bridge { completion in
            _ = provider.create(folder: name, at: ftpPath(parent), completionHandler: completion)
        }
    }

    func remove(path: String, isDirectory: Bool) async throws {
        try await bridge { completion in
            _ = provider.removeItem(path: ftpPath(path), completionHandler: completion)
        }
    }

    func move(from: String, to: String, overwrite: Bool) async throws {
        let source = RemotePath.normalize(from)
        let destination = RemotePath.normalize(to)
        let existing = try await existingItem(at: destination)
        if existing != nil, !overwrite {
            throw RemoteProviderError.conflict("An item already exists at \(destination).")
        }
        // FilesProvider ignores `overwrite`, and whether RNTO replaces an existing file is up
        // to the server: most Unix servers do, while IIS, FileZilla Server and ProFTPD without
        // AllowOverwrite refuse. Moving the old file aside first works on all of them. A
        // case-only rename on a case-insensitive server stays a plain rename.
        if let existing, !existing.isDirectory, source.lowercased() != destination.lowercased() {
            try await RemoteFileOperations.renameReplacingFile(
                from: source,
                to: destination,
                rename: { try await self.rename($0, to: $1) },
                remove: { try await self.remove(path: $0, isDirectory: false) }
            )
        } else {
            try await rename(source, to: destination)
        }
    }

    private func rename(_ source: String, to destination: String) async throws {
        try await bridge { completion in
            _ = provider.moveItem(path: ftpPath(source), to: ftpPath(destination), overwrite: false, completionHandler: completion)
        }
    }

    private func existingItem(at path: String) async throws -> RemoteItem? {
        do {
            return try await attributes(path: path)
        } catch {
            guard RemoteProviderError.isNotFound(error) else { throw error }
            return nil
        }
    }

    private func bridge(_ operation: (@escaping (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func ftpPath(_ path: String) -> String {
        let normalized = RemotePath.normalize(path)
        return normalized == "/" ? "/" : normalized
    }

    private static func normalizedAttributeError(_ error: Error, path: String) -> Error {
        if let urlError = error as? URLError, urlError.code == .fileDoesNotExist {
            return RemoteProviderError.notFound("The remote item was not found at \(path).")
        }
        if let cocoaError = error as? CocoaError, cocoaError.code == .fileNoSuchFile {
            return RemoteProviderError.notFound("The remote item was not found at \(path).")
        }
        return error
    }

    private func detectCHMODSupport() async -> Bool {
        if let response = try? await controlCommand("SITE HELP CHMOD"),
           let code = Self.replyCode(response),
           (200..<300).contains(code) {
            return true
        }
        if let response = try? await controlCommand("FEAT"),
           let code = Self.replyCode(response),
           (200..<300).contains(code),
           response.uppercased().contains("CHMOD") {
            return true
        }
        return false
    }

    private func unixPermissions(path: String) async throws -> UInt32 {
        guard !path.contains("\r"), !path.contains("\n") else {
            throw RemoteProviderError.invalidConfiguration("The FTP path contains an unsupported line break.")
        }
        let response = try await controlCommand("STAT \(ftpPath(path))")
        guard Self.replyCode(response).map({ (200..<300).contains($0) }) == true else {
            throw RemoteProviderError.invalidResponse("The FTP server did not return file status information.")
        }
        for rawLine in response.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count >= 10 else { continue }
            let chars = Array(line.prefix(10))
            guard chars[0] == "-" || chars[0] == "d" || chars[0] == "l" else { continue }
            if let mode = Self.parseUnixMode(String(chars[1...9])) { return mode }
        }
        throw RemoteProviderError.invalidResponse("The FTP server returned no Unix permission bits for this item.")
    }

    private func controlCommand(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.executeControlCommand(command) { response, error in
                if let error { continuation.resume(throwing: error) }
                else if let response { continuation.resume(returning: response) }
                else { continuation.resume(throwing: RemoteProviderError.invalidResponse("FTP returned no control response.")) }
            }
        }
    }

    static func replyCode(_ response: String) -> Int? {
        for line in response.components(separatedBy: .newlines).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3 else { continue }
            let prefix = String(trimmed.prefix(3))
            if let value = Int(prefix) { return value }
        }
        return nil
    }

    static func parseUnixMode(_ text: String) -> UInt32? {
        let chars = Array(text)
        guard chars.count == 9 else { return nil }
        var mode: UInt32 = 0
        let basic: [(Int, Character, UInt32)] = [
            (0, "r", 0o400), (1, "w", 0o200), (2, "x", 0o100),
            (3, "r", 0o040), (4, "w", 0o020), (5, "x", 0o010),
            (6, "r", 0o004), (7, "w", 0o002), (8, "x", 0o001)
        ]
        for (index, expected, bit) in basic where chars[index] == expected { mode |= bit }
        if chars[2] == "s" || chars[2] == "S" { mode |= 0o4000; if chars[2] == "s" { mode |= 0o100 } }
        if chars[5] == "s" || chars[5] == "S" { mode |= 0o2000; if chars[5] == "s" { mode |= 0o010 } }
        if chars[8] == "t" || chars[8] == "T" { mode |= 0o1000; if chars[8] == "t" { mode |= 0o001 } }
        let allowed: Set<Character> = ["r", "w", "x", "-", "s", "S", "t", "T"]
        guard chars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return mode
    }
}
