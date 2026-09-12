import Foundation
import XCTest
@testable import RemoteFiles

final class RemoteFileOperationsTests: XCTestCase {
    func testRecursiveDeleteRemovesChildrenBeforeParents() async throws {
        let provider = FakeProvider()
        let root = RemoteItem(name: "root", path: "/root", kind: .directory)

        try await RemoteFileOperations.removeRecursively(root, provider: provider)

        XCTAssertEqual(provider.removedPaths, [
            "/root/a.txt",
            "/root/sub/b.txt",
            "/root/sub",
            "/root"
        ])
    }
}

private final class FakeProvider: RemoteFileProvider, @unchecked Sendable {
    let profile = ConnectionProfile.empty(for: .sftp)
    let capabilities = ProviderCapabilities.basicReadWrite
    var removedPaths: [String] = []

    func connect() async throws { }

    func list(path: String) async throws -> [RemoteItem] {
        switch path {
        case "/root":
            return [
                RemoteItem(name: "a.txt", path: "/root/a.txt", kind: .file),
                RemoteItem(name: "sub", path: "/root/sub", kind: .directory)
            ]
        case "/root/sub":
            return [RemoteItem(name: "b.txt", path: "/root/sub/b.txt", kind: .file)]
        default:
            return []
        }
    }

    func attributes(path: String) async throws -> RemoteItem {
        RemoteItem(
            name: (path as NSString).lastPathComponent,
            path: path,
            kind: path.hasSuffix("root") || path.hasSuffix("sub") ? .directory : .file
        )
    }

    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }
    func createDirectory(path: String) async throws { }

    func remove(path: String, isDirectory: Bool) async throws {
        removedPaths.append(path)
    }
}
