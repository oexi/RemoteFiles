import Foundation
import XCTest
@testable import RemoteFiles

private final class WebDAVTestURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recordedRequests: [URLRequest] = []

    static func reset() {
        lock.lock()
        recordedRequests.removeAll()
        lock.unlock()
    }

    static func requestsSnapshot() -> [URLRequest] {
        lock.lock()
        let snapshot = recordedRequests
        lock.unlock()
        return snapshot
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(request)
        Self.lock.unlock()

        let isInitialPathRequest = request.url?.path == "/dav/visible"
        let statusCode = isInitialPathRequest ? 207 : 403
        let body = isInitialPathRequest ? Self.initialPathResponse : Data()

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/xml"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }

    private static let initialPathResponse = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/visible/</d:href>
            <d:propstat><d:prop>
              <d:displayname>visible</d:displayname>
              <d:resourcetype><d:collection/></d:resourcetype>
            </d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8)
}

final class WebDAVProviderTests: XCTestCase {
    func testConnectUsesInitialPathUnderBaseURLSubpath() async throws {
        WebDAVTestURLProtocol.reset()
        defer { WebDAVTestURLProtocol.reset() }

        var profile = ConnectionProfile.empty(for: .webdav)
        profile.host = "https://example.com/dav"
        profile.initialPath = "/visible"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDAVTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let provider = WebDAVProvider(profile: profile, credential: nil, session: session)

        try await provider.connect()

        let requests = WebDAVTestURLProtocol.requestsSnapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "PROPFIND")
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://example.com/dav/visible")

        await provider.disconnect()
    }

    func testDAVHrefDecodesReservedCharactersOnlyAsPathData() throws {
        var profile = ConnectionProfile.empty(for: .webdav)
        profile.host = "https://example.com/dav"
        let provider = WebDAVProvider(profile: profile, credential: nil)

        XCTAssertEqual(try provider.relativeRemotePath(fromDAVHref: "/dav/a%23b.txt"), "/a#b.txt")
        XCTAssertEqual(try provider.relativeRemotePath(fromDAVHref: "/dav/a%3Fb.txt"), "/a?b.txt")
        XCTAssertEqual(
            try provider.relativeRemotePath(fromDAVHref: "https://example.com/dav/folder/a%23b.txt"),
            "/folder/a#b.txt"
        )
    }

    func testXMLParserPreservesEncodedHref() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/a%23b.txt</d:href>
            <d:propstat><d:prop><d:displayname>a#b.txt</d:displayname></d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """

        let entries = try WebDAVXMLParser().parse(Data(xml.utf8))

        XCTAssertEqual(entries.first?.path, "/dav/a%23b.txt")
    }

    func testEmbeddedCredentialsAreRejected() {
        var profile = ConnectionProfile.empty(for: .webdav)
        profile.host = "https://user:password@example.com/dav"
        let provider = WebDAVProvider(profile: profile, credential: nil)

        XCTAssertThrowsError(try provider.relativeRemotePath(fromDAVHref: "/dav/file.txt"))

        profile.host = "user:password@example.com"
        let schemelessProvider = WebDAVProvider(profile: profile, credential: nil)
        XCTAssertThrowsError(try schemelessProvider.relativeRemotePath(fromDAVHref: "/file.txt"))
    }
}
