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
}

