import FileProvider
import Foundation
import XCTest
@testable import RemoteFiles

private final class WebDAVDepthZeroURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var depths: [String] = []

    static func recordedDepths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return depths
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.depths.append(request.value(forHTTPHeaderField: "Depth") ?? "")
        Self.lock.unlock()

        let path = request.url?.path ?? ""
        let body: String
        if path == "/dav" || path == "/dav/" {
            body = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>/dav/</d:href>
                <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
              </d:response>
            </d:multistatus>
            """
        } else {
            body = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>/dav/Shared%20Documents/report.docx</d:href>
                <d:propstat><d:prop>
                  <d:displayname>Quarterly Report</d:displayname>
                  <d:getcontentlength>42</d:getcontentlength>
                </d:prop></d:propstat>
              </d:response>
            </d:multistatus>
            """
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 207, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

final class WebDAVAttributesTests: XCTestCase {
    private func provider() -> WebDAVProvider {
        var profile = ConnectionProfile.empty(for: .webdav)
        profile.host = "https://example.com/dav"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDAVDepthZeroURLProtocol.self]
        return WebDAVProvider(profile: profile, credential: nil, session: URLSession(configuration: configuration))
    }

    func testRootAttributesAreAvailable() async throws {
        let root = try await provider().attributes(path: "/")
        XCTAssertEqual(root.path, "/")
        XCTAssertTrue(root.isDirectory)
        XCTAssertEqual(WebDAVDepthZeroURLProtocol.recordedDepths().last, "0")
    }

    func testItemNameComesFromHrefNotDisplayName() async throws {
        let item = try await provider().attributes(path: "/Shared Documents/report.docx")
        XCTAssertEqual(item.name, "report.docx")
        XCTAssertEqual(item.path, "/Shared Documents/report.docx")
        XCTAssertEqual(item.size, 42)
    }

    func testTrustEndpointUsesDefaultHTTPSPort() throws {
        var profile = ConnectionProfile.empty(for: .webdav)
        profile.host = "https://nas.local/dav"
        let endpoint = try WebDAVProvider(profile: profile, credential: nil).trustEndpoint()
        XCTAssertEqual(endpoint.host, "nas.local")
        XCTAssertEqual(endpoint.port, 443)
    }
}

final class TLSCertificatePinDecisionTests: XCTestCase {
    func testFirstCertificateIsPinned() {
        XCTAssertEqual(TLSCertificateTrust.decision(presented: "aa", pinned: nil), .pinnedFirstUse("aa"))
    }

    func testMatchingCertificateIsTrusted() {
        XCTAssertEqual(TLSCertificateTrust.decision(presented: "aa", pinned: "aa"), .trusted)
    }

    func testChangedCertificateIsRejected() {
        XCTAssertEqual(TLSCertificateTrust.decision(presented: "bb", pinned: "aa"), .rejected)
        XCTAssertEqual(TLSCertificateTrust.decision(presented: nil, pinned: nil), .rejected)
    }
}

final class FileProviderKnownIdentifierTests: XCTestCase {
    func testKnownIdentifierDoesNotWriteIdentityState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnownIdentifier-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let store = FileProviderIdentityStore(profileID: profileID, directory: directory)
        let codec = FileProviderPathCodec(rootPath: "/root")

        XCTAssertEqual(store.knownIdentifier(for: "/root", codec: codec), .rootContainer)
        XCTAssertEqual(store.knownIdentifier(for: "/root/folder", codec: codec), codec.identifier(for: "/root/folder"))
        XCTAssertNil(store.knownIdentifier(for: "/elsewhere", codec: codec))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(profileID.uuidString).appendingPathExtension("json").path
        ))
    }
}
