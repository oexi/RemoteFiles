import XCTest
@testable import RemoteFiles

final class LANServiceBrowserTests: XCTestCase {
    func testServiceTypesMapToProtocols() {
        XCTAssertEqual(LANServiceBrowser.connectionKind(forServiceType: "_smb._tcp")?.protocolType, .smb)
        XCTAssertEqual(LANServiceBrowser.connectionKind(forServiceType: "_sftp-ssh._tcp.")?.protocolType, .sftp)
        XCTAssertEqual(LANServiceBrowser.connectionKind(forServiceType: "_ssh._tcp")?.protocolType, .sftp)
        XCTAssertEqual(LANServiceBrowser.connectionKind(forServiceType: "_ftp._tcp")?.protocolType, .ftp)
        XCTAssertEqual(LANServiceBrowser.connectionKind(forServiceType: "_nfs._tcp")?.protocolType, .nfs)

        let webdav = LANServiceBrowser.connectionKind(forServiceType: "_webdav._tcp")
        XCTAssertEqual(webdav?.protocolType, .webdav)
        XCTAssertEqual(webdav?.useTLS, false)
        XCTAssertEqual(LANServiceBrowser.connectionKind(forServiceType: "_webdavs._tcp")?.useTLS, true)

        XCTAssertNil(LANServiceBrowser.connectionKind(forServiceType: "_http._tcp"))
    }

    @MainActor
    func testEveryBrowsedTypeIsDeclaredInInfoPlist() throws {
        let declared = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String])
        for type in LANServiceBrowser.serviceTypes {
            XCTAssertTrue(declared.contains(type), "\(type) is missing from NSBonjourServices")
            XCTAssertNotNil(LANServiceBrowser.connectionKind(forServiceType: type), type)
        }
    }
}
