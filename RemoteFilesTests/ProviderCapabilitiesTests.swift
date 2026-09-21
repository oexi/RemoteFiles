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
        let erasedProvider: any RemoteFileProvider = provider

        XCTAssertTrue(provider.capabilities.contains(.randomRead))
        XCTAssertFalse(provider.capabilities.contains(.randomWrite))
        XCTAssertFalse(provider.capabilities.contains(.resume))
        XCTAssertTrue(erasedProvider is any RemoteChunkReadableProvider)
        XCTAssertFalse(erasedProvider is any RemoteChunkWritableProvider)
    }
}
