import Foundation
import XCTest
@testable import RemoteFiles

final class ReplaceFileTests: XCTestCase {
    private func localFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replace-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReplacesViaStagedCopyAndKeepsPermissions() async throws {
        let provider = MemoryRemoteProvider()
        provider.storage.write("/script.sh", Data("old".utf8))
        provider.storage.setMode("/script.sh", 0o755)

        try await RemoteFileOperations.replaceFile(at: "/script.sh", with: try localFile("new"), provider: provider)

        XCTAssertEqual(provider.storage.data("/script.sh"), Data("new".utf8))
        XCTAssertEqual(provider.storage.mode("/script.sh"), 0o755)
        XCTAssertEqual(provider.storage.allFiles, ["/script.sh"])
        XCTAssertFalse(provider.storage.operations.contains("upload:/script.sh"))
    }

    func testFailedSwapRestoresTheOriginal() async throws {
        let provider = MemoryRemoteProvider()
        provider.storage.write("/a.txt", Data("old".utf8))
        provider.failure = { operation in
            operation.hasPrefix("move:") && operation.contains(".saving->")
                ? MemoryRemoteProvider.Failure.injected(operation)
                : nil
        }

        do {
            try await RemoteFileOperations.replaceFile(at: "/a.txt", with: try localFile("new"), provider: provider)
            XCTFail("Expected the injected rename failure")
        } catch { }

        XCTAssertEqual(provider.storage.data("/a.txt"), Data("old".utf8))
        XCTAssertEqual(provider.storage.allFiles, ["/a.txt"])
    }

    func testSymbolicLinkIsOverwrittenInPlace() async throws {
        let provider = MemoryRemoteProvider()
        provider.storage.write("/link", Data("old".utf8))
        provider.storage.markSymbolicLink("/link")

        try await RemoteFileOperations.replaceFile(at: "/link", with: try localFile("new"), provider: provider)

        XCTAssertEqual(provider.storage.data("/link"), Data("new".utf8))
        XCTAssertTrue(provider.storage.operations.contains("upload:/link"))
        XCTAssertFalse(provider.storage.operations.contains { $0.hasPrefix("move:") })
    }

    func testProviderWithoutRenameOverwritesInPlace() async throws {
        let provider = MemoryRemoteProvider(capabilities: ProviderCapabilities([.list, .read, .write, .createDirectory, .delete]))
        provider.storage.write("/a.txt", Data("old".utf8))

        try await RemoteFileOperations.replaceFile(at: "/a.txt", with: try localFile("new"), provider: provider)

        XCTAssertEqual(provider.storage.data("/a.txt"), Data("new".utf8))
        XCTAssertEqual(provider.storage.operations.filter { $0.hasPrefix("upload:") }, ["upload:/a.txt"])
    }

    func testCreatesMissingFile() async throws {
        let provider = MemoryRemoteProvider()

        try await RemoteFileOperations.replaceFile(at: "/new.txt", with: try localFile("hello"), provider: provider)

        XCTAssertEqual(provider.storage.data("/new.txt"), Data("hello".utf8))
        XCTAssertEqual(provider.storage.allFiles, ["/new.txt"])
    }
}
