import XCTest
@testable import RemoteFiles

final class ProviderCapabilitiesTests: XCTestCase {
    func testBasicReadWriteCapabilities() {
        let capabilities = ProviderCapabilities.basicReadWrite
        XCTAssertTrue(capabilities.contains(.list))
        XCTAssertTrue(capabilities.contains(.read))
        XCTAssertTrue(capabilities.contains(.write))
        XCTAssertFalse(capabilities.contains(.permissions))
    }

    func testNFSCapabilitiesMatchImplementedChunkProtocols() throws {
        var profile = ConnectionProfile.empty(for: .nfs)
        profile.host = "nfs.example"
        let provider = try NFSProvider(profile: profile)

        XCTAssertTrue(provider.capabilities.contains(.randomRead))
        XCTAssertFalse(provider.capabilities.contains(.randomWrite))
        XCTAssertFalse(provider.capabilities.contains(.resume))
        XCTAssertTrue(provider is any RemoteChunkReadableProvider)
        XCTAssertFalse(provider is any RemoteChunkWritableProvider)
    }
}
