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

    func testAvailablePastePathUsesDirectNameWhenStatConfirmsMissing() async throws {
        let provider = PastePathProvider()
        let item = RemoteItem(name: "report.txt", path: "/source/report.txt", kind: .file)

        let path = try await RemoteFileOperations.availablePastePath(
            for: item,
            in: "/destination",
            provider: provider
        )

        XCTAssertEqual(path, "/destination/report.txt")
    }

    func testAvailablePastePathUsesCopyNameWhenDirectNameExists() async throws {
        let provider = PastePathProvider(responses: [
            "/destination/report.txt": .item
        ])
        let item = RemoteItem(name: "report.txt", path: "/source/report.txt", kind: .file)

        let path = try await RemoteFileOperations.availablePastePath(
            for: item,
            in: "/destination",
            provider: provider
        )

        XCTAssertEqual(path, "/destination/report copy.txt")
    }

    func testAvailablePastePathPropagatesStatFailure() async {
        let provider = PastePathProvider(responses: [
            "/destination/report.txt": .failure
        ])
        let item = RemoteItem(name: "report.txt", path: "/source/report.txt", kind: .file)

        do {
            _ = try await RemoteFileOperations.availablePastePath(
                for: item,
                in: "/destination",
                provider: provider
            )
            XCTFail("Expected the stat failure to be propagated")
        } catch is PastePathError {
            // Expected: a transport/permission failure is not proof of absence.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNotFoundContractRecognizesNativeMissingPathErrorsOnly() {
        XCTAssertTrue(RemoteProviderError.isNotFound(POSIXError(.ENOENT)))
        XCTAssertFalse(RemoteProviderError.isNotFound(POSIXError(.EACCES)))
        XCTAssertTrue(RemoteProviderError.isNotFound(CocoaError(.fileNoSuchFile)))
        XCTAssertTrue(RemoteProviderError.isNotFound(URLError(.fileDoesNotExist)))
        XCTAssertFalse(RemoteProviderError.isNotFound(RemoteProviderError.invalidResponse("offline")))
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

private enum PastePathError: Error {
    case unavailable
}

private final class PastePathProvider: RemoteFileProvider, @unchecked Sendable {
    enum Response {
        case item
        case failure
    }

    let profile = ConnectionProfile.empty(for: .sftp)
    let capabilities = ProviderCapabilities.basicReadWrite
    private let responses: [String: Response]

    init(responses: [String: Response] = [:]) {
        self.responses = responses
    }

    func connect() async throws { }

    func list(path: String) async throws -> [RemoteItem] { [] }

    func attributes(path: String) async throws -> RemoteItem {
        switch responses[path] {
        case .item:
            return RemoteItem(
                name: (path as NSString).lastPathComponent,
                path: path,
                kind: .file
            )
        case .failure:
            throw PastePathError.unavailable
        case nil:
            throw RemoteProviderError.notFound("Missing \(path)")
        }
    }

    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }
    func createDirectory(path: String) async throws { }
}
