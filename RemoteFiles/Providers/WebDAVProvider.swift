import Foundation

final class WebDAVProvider: RemoteFileProvider, RemoteChunkReadableProvider, RemoteChunkReadSupportProbing, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .createDirectory, .delete, .move, .copy, .fileRevisions])

    private let credential: Credential?
    private let injectedSession: URLSession?
    // `disconnect()` invalidates the owned session. A provider can still be
    // used afterwards (for example by a view that outlives a transfer), so a
    // fresh session is created lazily instead of reusing an invalid one.
    private let sessionLock = NSLock()
    private var ownedSession: URLSession?

    init(profile: ConnectionProfile, credential: Credential?, session: URLSession? = nil) {
        self.profile = profile
        self.credential = credential
        injectedSession = session
    }

    private var session: URLSession {
        if let injectedSession { return injectedSession }
        return sessionLock.withLock {
            if let ownedSession { return ownedSession }
            let configuration = URLSessionConfiguration.default
            // The request timeout covers idle gaps between packets. The
            // resource timeout caps a whole transfer, so it keeps the system
            // default (7 days): a 30-minute cap cut off large uploads and
            // downloads midway. Without a network, fail at once instead of
            // waiting for connectivity until that cap.
            configuration.timeoutIntervalForRequest = 60
            configuration.waitsForConnectivity = false
            let created = URLSession(
                configuration: configuration,
                delegate: WebDAVSessionDelegate(profile: profile, credential: credential),
                delegateQueue: nil
            )
            ownedSession = created
            return created
        }
    }

    // URLSession keeps itself alive until invalidated; release it with the provider.
    deinit {
        ownedSession?.finishTasksAndInvalidate()
    }

    func connect() async throws { _ = try await list(path: profile.initialPath) }

    func disconnect() async {
        if let injectedSession {
            injectedSession.finishTasksAndInvalidate()
            return
        }
        let session = sessionLock.withLock {
            let current = ownedSession
            ownedSession = nil
            return current
        }
        session?.finishTasksAndInvalidate()
    }

    func list(path: String) async throws -> [RemoteItem] {
        let requested = RemotePath.normalize(path)
        return try await propfind(path: path, depth: "1").compactMap { entry in
            let normalized = try relativeRemotePath(fromDAVHref: entry.path)
            guard normalized != requested else { return nil }
            return item(for: entry, at: normalized)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func attributes(path: String) async throws -> RemoteItem {
        // A Depth: 0 PROPFIND describes the item itself. Unlike listing the
        // parent this also works for the root and does not transfer an entire
        // directory listing to stat one file.
        let requested = RemotePath.normalize(path)
        let entries = try await propfind(path: path, depth: "0")
        for entry in entries {
            if try relativeRemotePath(fromDAVHref: entry.path) == requested {
                return item(for: entry, at: requested)
            }
        }
        throw RemoteProviderError.notFound("The remote item was not found at \(path).")
    }

    private func propfind(path: String, depth: String) async throws -> [WebDAVEntry] {
        var request = try makeRequest(path: path, method: "PROPFIND")
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)
        let (data, response) = try await session.data(for: request)
        try validate(response, allowed: [207])
        return try WebDAVXMLParser().parse(data)
    }

    /// The item name always comes from the href, never from `displayname`:
    /// paths for rename, copy and paste are built from `name`, and servers such
    /// as SharePoint report a display name that differs from the resource name.
    private func item(for entry: WebDAVEntry, at path: String) -> RemoteItem {
        let name = path == "/" ? "/" : (path as NSString).lastPathComponent
        return RemoteItem(
            name: name,
            path: path,
            kind: entry.isCollection ? .directory : .file,
            size: entry.isCollection ? nil : entry.size,
            modifiedAt: entry.modifiedAt,
            createdAt: entry.createdAt,
            isHidden: name.hasPrefix("."),
            contentType: entry.contentType,
            revision: .init(eTag: entry.eTag, modifiedAt: entry.modifiedAt, size: entry.size)
        )
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

    func supportsChunkedReads(path _: String) async throws -> Bool {
        // A native URLSession download is one streaming response. Replacing it
        // with one range request per engine chunk adds a full HTTP round trip for
        // every chunk and is substantially slower on high-latency WebDAV hosts.
        false
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
        // Preemptive Basic saves a round trip, but only over HTTPS: on plain
        // HTTP it would expose the password to servers that expect Digest.
        // Other schemes are answered by WebDAVSessionDelegate's challenge handler.
        if let credential, request.url?.scheme?.lowercased() == "https" {
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

    /// Host and port that TLS challenges for this server report, used to key
    /// the trust-on-first-use certificate pin.
    func trustEndpoint() throws -> (host: String, port: Int) {
        let parts = try baseComponents()
        let host = parts.host ?? ""
        let port = parts.port ?? (parts.scheme?.lowercased() == "https" ? 443 : 80)
        return (host, port)
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
            if http.statusCode == 401 { throw RemoteProviderError.authenticationRequired }
            if http.statusCode == 403 { throw RemoteProviderError.permissionDenied }
            if http.statusCode == 404 { throw RemoteProviderError.notFound("The remote item was not found.") }
            if http.statusCode == 409 || http.statusCode == 412 { throw RemoteProviderError.conflict("WebDAV conflict (HTTP \(http.statusCode)).") }
            throw RemoteProviderError.invalidResponse("WebDAV HTTP \(http.statusCode).")
        }
    }

    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8" ?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:creationdate/><d:getetag/><d:getcontenttype/></d:prop></d:propfind>
    """
}

/// Answers authentication challenges for WebDAV: HTTP Digest/NTLM/Basic with
/// the stored credential, and server trust according to the profile's
/// certificate-verification setting.
final class WebDAVSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let profile: ConnectionProfile
    private let credential: Credential?

    init(profile: ConnectionProfile, credential: Credential?) {
        self.profile = profile
        self.credential = credential
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard !profile.verifyTLS, let trust = space.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            if TLSCertificateTrust.evaluatePinned(trust, host: space.host, port: space.port) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodNTLM:
            // A second challenge means the server rejected these credentials;
            // let it fail with 401 instead of looping.
            guard let credential, challenge.previousFailureCount == 0 else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(user: credential.username, password: credential.password, persistence: .forSession)
            )
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
