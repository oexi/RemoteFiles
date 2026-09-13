import Foundation
import XCTest
@testable import RemoteFiles

final class WebDAVProviderTests: XCTestCase {
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
