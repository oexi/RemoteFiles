import XCTest
@testable import RemoteFiles

final class ConnectionProfileTests: XCTestCase {
    func testProfileRoundTrip() throws {
        var profile = ConnectionProfile.empty(for: .smb)
        profile.name = "NAS"
        profile.host = "nas.local"
        profile.share = "Media"
        profile.username = "john"

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testDefaultPorts() {
        XCTAssertEqual(RemoteProtocol.ftp.defaultPort, 21)
        XCTAssertEqual(RemoteProtocol.ftps.defaultPort, 990)
        XCTAssertEqual(RemoteProtocol.sftp.defaultPort, 22)
        XCTAssertEqual(RemoteProtocol.smb.defaultPort, 445)
        XCTAssertEqual(RemoteProtocol.webdav.defaultPort, 443)
        XCTAssertEqual(RemoteProtocol.nfs.defaultPort, 2049)
    }
}

