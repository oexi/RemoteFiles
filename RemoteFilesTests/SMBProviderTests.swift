import XCTest
@testable import RemoteFiles

final class SMBProviderTests: XCTestCase {
    func testAbortChunkedUploadWithoutPreparedHandleDoesNotConnect() async {
        var profile = ConnectionProfile.empty(for: .smb)
        profile.host = "unreachable.example"
        profile.share = "share"
        let provider = SMBProvider(profile: profile, credential: nil)

        // Cleanup can run after a failed setup or after the provider has already
        // disconnected. It must be safe without reopening the SMB connection.
        await provider.abortChunkedUpload(path: "/folder/file.partial")

        XCTAssertTrue(provider.capabilities.contains(.write))
        XCTAssertTrue(provider.capabilities.contains(.resume))
    }

    func testAbortHookHasACompatibilityDefaultForLegacyWriters() async {
        let provider: any RemoteChunkWritableProvider = LegacyChunkWriter()

        // Providers that do not own a persistent remote handle still conform to
        // the protocol without implementing a provider-specific cleanup hook.
        await provider.abortChunkedUpload(path: "/file.partial")
    }
}

private struct LegacyChunkWriter: RemoteChunkWritableProvider, Sendable {
    let profile = ConnectionProfile.empty(for: .sftp)
    let capabilities = ProviderCapabilities([])

    func prepareChunkedUpload(path: String, overwrite: Bool, resumeOffset: UInt64) async throws -> UInt64 {
        resumeOffset
    }

    func writeChunk(path: String, data: Data, offset: UInt64) async throws { }
}

final class SMBConnectionFailureTests: XCTestCase {
    func testTransportErrorsRetireTheConnection() {
        XCTAssertTrue(SMBProvider.isConnectionFailure(POSIXError(.ECONNRESET)))
        XCTAssertTrue(SMBProvider.isConnectionFailure(POSIXError(.EPIPE)))
        XCTAssertTrue(SMBProvider.isConnectionFailure(POSIXError(.ETIMEDOUT)))
    }

    func testProtocolErrorsKeepTheConnection() {
        XCTAssertFalse(SMBProvider.isConnectionFailure(RemoteProviderError.notFound("missing")))
        XCTAssertFalse(SMBProvider.isConnectionFailure(RemoteProviderError.conflict("exists")))
        XCTAssertFalse(SMBProvider.isConnectionFailure(POSIXError(.ENOENT)))
    }
}
