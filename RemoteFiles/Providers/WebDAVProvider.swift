import Foundation

final class WebDAVProvider: RemoteFileProvider, RemoteChunkReadableProvider, RemoteChunkReadSupportProbing, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .createDirectory, .delete, .move, .copy, .fileRevisions])

    private let credential: Credential?
    private let session: URLSession

    init(profile: ConnectionProfile, credential: Credential?, session: URLSession? = nil) {
        self.profile = profile
        self.credential = credential
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 1800
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
    }

    func connect() async throws { _ = try await list(path: profile.initialPath) }
    func disconnect() async { session.invalidateAndCancel() }

    func list(path: String) async throws -> [RemoteItem] {
        var request = try makeRequest(path: path, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)
        let (data, response) = try await session.data(for: request)
        try validate(response, allowed: [207])

        let requested = RemotePath.normalize(path)
        return try WebDAVXMLParser().parse(data).compactMap { entry in
            let normalized = try relativeRemotePath(fromDAVHref: entry.path)
            guard normalized != requested else { return nil }
            let name = entry.displayName?.isEmpty == false ? entry.displayName! : (normalized as NSString).lastPathComponent
            return RemoteItem(
                name: name,
                path: normalized,
                kind: entry.isCollection ? .directory : .file,
                size: entry.size,
                modifiedAt: entry.modifiedAt,
                createdAt: entry.createdAt,
                isHidden: name.hasPrefix("."),
                contentType: entry.contentType,
                revision: .init(eTag: entry.eTag, modifiedAt: entry.modifiedAt, size: entry.size)
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func attributes(path: String) async throws -> RemoteItem {
        let parent = RemotePath.parent(path)
        guard let item = try await list(path: parent).first(where: { $0.path == RemotePath.normalize(path) }) else {
            throw RemoteProviderError.invalidResponse("WebDAV item was not found in its parent collection.")
        }
        return item
    }

    func download(path: String, to localURL: URL) async throws {
        let request = try makeRequest(path: path, method: "GET")
        let (temporaryURL, response) = try await session.download(for: request)
        try validate(response, allowed: Array(200..<300))
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: temporaryURL, to: localURL)
    }

    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        var request = try makeRequest(path: path, method: "GET")
        request.setValue("bytes=\(offset)-\(offset + UInt64(length) - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteProviderError.invalidResponse("Non-HTTP response.")
        }
        if http.statusCode == 206 { return data }
        throw RemoteProviderError.unsupported("This WebDAV server does not support byte-range reads.")
    }

    func supportsChunkedReads(path: String) async throws -> Bool {
        let request = try makeRequest(path: path, method: "HEAD")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteProviderError.invalidResponse("Non-HTTP response.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw RemoteProviderError.authenticationRequired
        }
        guard (200..<300).contains(http.statusCode) else { return false }
        return http.value(forHTTPHeaderField: "Accept-Ranges")?
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("bytes") == true
    }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws {
        var request = try makeRequest(path: path, method: "PUT")
        if !overwrite { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        let (_, response) = try await session.upload(for: request, fromFile: localURL)
        try validate(response, allowed: Array(200..<300))
    }

    func createDirectory(path: String) async throws {
        let request = try makeRequest(path: path, method: "MKCOL")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteProviderError.invalidResponse("Non-HTTP response.")
        }
        if http.statusCode == 405 {
            let existing = try await attributes(path: path)
            guard existing.isDirectory else {
                throw RemoteProviderError.conflict("A non-directory item already exists at \(path).")
            }
            return
        }
        try validate(response, allowed: [201, 204])
    }

    func remove(path: String, isDirectory: Bool) async throws {
        let request = try makeRequest(path: path, method: "DELETE")
        let (_, response) = try await session.data(for: request)
        try validate(response, allowed: Array(200..<300))
    }

    func move(from: String, to: String, overwrite: Bool) async throws {
        var request = try makeRequest(path: from, method: "MOVE")
        request.setValue(try url(for: to).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue(overwrite ? "T" : "F", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await session.data(for: request)
        try validate(response, allowed: [201, 204])
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        request.setValue(AppVersion.userAgent, forHTTPHeaderField: "User-Agent")
        if let credential {
            let token = Data("\(credential.username):\(credential.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func url(for path: String) throws -> URL {
        var parts = try baseComponents()
        let root = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        parts.path = root + RemotePath.normalize(path)
        guard let result = parts.url else { throw RemoteProviderError.invalidConfiguration("Invalid WebDAV path.") }
        return result
    }

    private func baseComponents() throws -> URLComponents {
        let input = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBase: String
        if input.contains("://") {
            rawBase = input
        } else {
            let scheme = profile.useTLS ? "https" : "http"
            let defaultPort = profile.useTLS ? 443 : 80
            rawBase = "\(scheme)://\(input)" + (profile.port == defaultPort ? "" : ":\(profile.port)")
        }
        guard let parts = URLComponents(string: rawBase) else {
            throw RemoteProviderError.invalidConfiguration("Invalid WebDAV server URL.")
        }
        guard let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw RemoteProviderError.invalidConfiguration("WebDAV server URL must use http or https.")
        }
        guard parts.host?.isEmpty == false else {
            throw RemoteProviderError.invalidConfiguration("WebDAV server URL is missing a host.")
        }
        guard parts.user == nil, parts.password == nil else {
            throw RemoteProviderError.invalidConfiguration("Store WebDAV credentials separately instead of embedding them in the server URL.")
        }
        guard parts.query == nil, parts.fragment == nil else {
            throw RemoteProviderError.invalidConfiguration("WebDAV server URL must not contain a query or fragment.")
        }
        return parts
    }

    func relativeRemotePath(fromDAVHref href: String) throws -> String {
        let encodedPath = URLComponents(string: href)?.percentEncodedPath ?? href
        let hrefPath = encodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { component in
                let value = String(component)
                return value.removingPercentEncoding ?? value
            }
            .joined(separator: "/")
        let normalizedHrefPath = "/" + hrefPath
        let basePath = try baseComponents().path
        let root = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        if normalizedHrefPath == root || normalizedHrefPath == root + "/" { return "/" }
        if !root.isEmpty, normalizedHrefPath.hasPrefix(root + "/") {
            return RemotePath.normalize(String(normalizedHrefPath.dropFirst(root.count)))
        }
        return RemotePath.normalize(normalizedHrefPath)
    }

    private func validate(_ response: URLResponse, allowed: [Int]) throws {
        guard let http = response as? HTTPURLResponse else { throw RemoteProviderError.invalidResponse("Non-HTTP response.") }
        guard allowed.contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw RemoteProviderError.authenticationRequired }
            if http.statusCode == 409 || http.statusCode == 412 { throw RemoteProviderError.conflict("WebDAV conflict (HTTP \(http.statusCode)).") }
            throw RemoteProviderError.invalidResponse("WebDAV HTTP \(http.statusCode).")
        }
    }

    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8" ?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:creationdate/><d:getetag/><d:getcontenttype/></d:prop></d:propfind>
    """
}
