import XCTest
import SMBClient
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

final class SMBSecurityErrorTests: XCTestCase {
    func testEncryptionNotSupportedExplainsTheSetting() {
        let error = SMBProvider.userFacingError(MessageCipherError.encryptionNotSupported)
        guard case RemoteProviderError.invalidConfiguration = error else {
            return XCTFail("Expected invalidConfiguration, got \(error)")
        }
    }

    func testFailedSecurityChecksBecomeInvalidResponse() {
        let errors: [Error] = [
            SecurityError.signatureMismatch,
            SecurityError.unsignedResponse,
            SecurityError.unencryptedResponse,
            NegotiateError.validationFailed,
            MessageCipherError.authenticationFailed,
        ]
        for error in errors {
            guard case RemoteProviderError.invalidResponse = SMBProvider.userFacingError(error) else {
                return XCTFail("Expected invalidResponse for \(error)")
            }
            XCTAssertTrue(SMBProvider.isConnectionFailure(error), "\(error)")
        }
    }

    func testOtherErrorsPassThrough() {
        let error = SMBProvider.userFacingError(ConnectionError.disconnected)
        XCTAssertTrue(error is ConnectionError)
        XCTAssertTrue(SMBProvider.userFacingError(CancellationError()) is CancellationError)
    }

    func testDialectNames() {
        XCTAssertEqual(SMBProvider.dialectName(.smb210), "2.1")
        XCTAssertEqual(SMBProvider.dialectName(.smb302), "3.0.2")
        XCTAssertEqual(SMBProvider.dialectName(.smb311), "3.1.1")
        XCTAssertEqual(SMBProvider.dialectName(nil), "unknown")
    }

    func testSessionSummaryDetail() {
        let plain = SMBSessionSummary(dialect: "2.1", transport: .tcp, isEncrypted: false, channelCount: 1, isCompressionEnabled: false)
        XCTAssertEqual(plain.detail, "SMB 2.1 over TCP, not encrypted")

        let full = SMBSessionSummary(dialect: "3.1.1", transport: .quic, isEncrypted: true, channelCount: 2, isCompressionEnabled: true)
        XCTAssertEqual(full.detail, "SMB 3.1.1 over QUIC, encrypted, 2 channels, compression on")
    }
}
