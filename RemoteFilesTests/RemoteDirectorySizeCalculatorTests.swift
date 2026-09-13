import Foundation
import XCTest
@testable import RemoteFiles

final class RemoteDirectorySizeCalculatorTests: XCTestCase {
    func testSkipsUnreadableNestedDirectoryAndKeepsCounting() async throws {
        let profile = ConnectionProfile.empty(for: .sftp)
        let provider = DirectorySizeTestProvider(profile: profile)

        let result = try await RemoteDirectorySizeCalculator.calculate(
            path: "/root",
            provider: provider
        )

        XCTAssertEqual(result.bytes, 35)
        XCTAssertEqual(result.skippedItemCount, 1)
    }

    func testRootListingFailureStillFailsCalculation() async {
        let profile = ConnectionProfile.empty(for: .sftp)
        let provider = DirectorySizeTestProvider(profile: profile, failRoot: true)

        do {
            _ = try await RemoteDirectorySizeCalculator.calculate(
                path: "/root",
                provider: provider
            )
            XCTFail("Expected root listing failure")
        } catch {
            XCTAssertTrue(true)
        }
    }
}

private final class DirectorySizeTestProvider: RemoteFileProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities.readOnly
    private let failRoot: Bool

    init(profile: ConnectionProfile, failRoot: Bool = false) {
        self.profile = profile
        self.failRoot = failRoot
    }

    func connect() async throws { }

    func list(path: String) async throws -> [RemoteItem] {
        switch RemotePath.normalize(path) {
        case "/root":
            if failRoot {
                throw RemoteProviderError.invalidResponse("root unavailable")
            }
            return [
                RemoteItem(name: "a.bin", path: "/root/a.bin", kind: .file, size: 10),
                RemoteItem(name: "ok", path: "/root/ok", kind: .directory),
                RemoteItem(name: "blocked", path: "/root/blocked", kind: .directory)
            ]
        case "/root/ok":
            return [
                RemoteItem(name: "b.bin", path: "/root/ok/b.bin", kind: .file, size: 20),
                RemoteItem(name: "c.bin", path: "/root/ok/c.bin", kind: .file)
            ]
        case "/root/blocked":
            throw RemoteProviderError.invalidResponse("permission denied")
        default:
            return []
        }
    }

    func attributes(path: String) async throws -> RemoteItem {
        if RemotePath.normalize(path) == "/root/ok/c.bin" {
            return RemoteItem(name: "c.bin", path: path, kind: .file, size: 5)
        }
        throw RemoteProviderError.invalidResponse("missing")
    }

    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }
}
