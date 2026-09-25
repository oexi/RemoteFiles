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

    func testProfileSavedBeforeSMBSettingsDecodesWithDefaults() throws {
        let json = """
        {"id":"8E6C8D5A-0D0B-4D0E-9C39-6B1C2B4F5A10","name":"NAS","protocolType":"smb",
         "host":"nas.local","port":445,"username":"john","initialPath":"/","share":"Media",
         "domain":"","useTLS":false,"verifyTLS":true,"nfsExport":"/"}
        """
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8))

        XCTAssertEqual(profile.name, "NAS")
        XCTAssertEqual(profile.share, "Media")
        XCTAssertEqual(profile.smbTransport, .tcp)
        XCTAssertFalse(profile.smbRequireEncryption)
        XCTAssertFalse(profile.smbMultiChannel)
        XCTAssertFalse(profile.smbCompression)
    }

    func testSMBSettingsRoundTrip() throws {
        var profile = ConnectionProfile.empty(for: .smb)
        profile.host = "server.example"
        profile.share = "Data"
        profile.smbTransport = .quic
        profile.port = SMBTransport.quic.defaultPort
        profile.smbRequireEncryption = true
        profile.smbMultiChannel = true
        profile.smbCompression = true

        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self, from: data), profile)
    }

    func testSMBTransportDefaultPorts() {
        XCTAssertEqual(SMBTransport.tcp.defaultPort, 445)
        XCTAssertEqual(SMBTransport.quic.defaultPort, 443)
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

