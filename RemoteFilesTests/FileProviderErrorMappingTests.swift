import FileProvider
import Foundation
import XCTest
@testable import RemoteFiles

final class FileProviderErrorMappingTests: XCTestCase {
    func testMissingItemMapsToNoSuchItem() {
        XCTAssertEqual(code(RemoteProviderError.notFound("gone")), .noSuchItem)
        XCTAssertEqual(code(POSIXError(.ENOENT)), .noSuchItem)
    }

    func testAuthenticationMapsToNotAuthenticated() {
        XCTAssertEqual(code(RemoteProviderError.authenticationRequired), .notAuthenticated)
    }

    func testConflictMapsToFilenameCollision() {
        XCTAssertEqual(code(RemoteProviderError.conflict("exists")), .filenameCollision)
    }

    func testNetworkFailuresMapToServerUnreachable() {
        XCTAssertEqual(code(RemoteProviderError.notConnected), .serverUnreachable)
        XCTAssertEqual(code(URLError(.notConnectedToInternet)), .serverUnreachable)
        XCTAssertEqual(code(URLError(.timedOut)), .serverUnreachable)
        XCTAssertEqual(code(POSIXError(.ECONNREFUSED)), .serverUnreachable)
        XCTAssertEqual(code(POSIXError(.EHOSTUNREACH)), .serverUnreachable)
    }

    func testCancellationMapsToUserCancelled() {
        let mapped = FileProviderErrorMapping.map(CancellationError())
        XCTAssertEqual((mapped as? CocoaError)?.code, .userCancelled)
    }

    func testDescriptiveErrorsPassThroughUnchanged() {
        let mapped = FileProviderErrorMapping.map(RemoteProviderError.invalidResponse("WebDAV HTTP 500."))
        XCTAssertEqual(mapped.localizedDescription, "WebDAV HTTP 500.")
        XCTAssertNil(mapped as? NSFileProviderError)
    }

    func testFileProviderErrorsAreKept() {
        XCTAssertEqual(code(NSFileProviderError(.cannotSynchronize)), .cannotSynchronize)
    }

    private func code(_ error: Error) -> NSFileProviderError.Code? {
        (FileProviderErrorMapping.map(error) as? NSFileProviderError)?.code
    }
}
