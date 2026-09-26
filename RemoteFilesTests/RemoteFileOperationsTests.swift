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

    func testRenameReplacingFileSwapsInTheNewFile() async throws {
        let store = NoReplaceRenameStore(["/dir/new.partial": "new", "/dir/a.txt": "old"])

        try await RemoteFileOperations.renameReplacingFile(
            from: "/dir/new.partial",
            to: "/dir/a.txt",
            rename: { try store.rename($0, $1) },
            remove: { store.remove($0) }
        )

        XCTAssertEqual(store.files, ["/dir/a.txt": "new"])
    }

    func testRenameReplacingFileRestoresTheOldFileWhenTheFinalRenameFails() async {
        let store = NoReplaceRenameStore(["/dir/new.partial": "new", "/dir/a.txt": "old"])
        store.failingSource = "/dir/new.partial"

        do {
            try await RemoteFileOperations.renameReplacingFile(
                from: "/dir/new.partial",
                to: "/dir/a.txt",
                rename: { try store.rename($0, $1) },
                remove: { store.remove($0) }
            )
            XCTFail("Expected the final rename to fail")
        } catch {
            XCTAssertEqual(store.files, ["/dir/new.partial": "new", "/dir/a.txt": "old"])
        }
    }

    func testChunkedDownloadReportsBytesAsTheyArrive() async throws {
        let provider = ChunkedMemoryProvider()
        let payload = Data((0..<2_500_000).map { UInt8($0 % 251) })
        provider.base.storage.write("/big.bin", payload)
        let item = RemoteItem(name: "big.bin", path: "/big.bin", kind: .file, size: 1)
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesChunkedDownload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: localURL) }

        var reports: [UInt64] = []
        try await RemoteFileOperations.download(item, from: provider, to: localURL) { received, total in
            XCTAssertEqual(total, UInt64(payload.count))
            reports.append(received)
        }

        XCTAssertEqual(try Data(contentsOf: localURL), payload)
        XCTAssertEqual(reports.first, 0)
        XCTAssertEqual(reports.last, UInt64(payload.count))
        XCTAssertGreaterThan(reports.count, 2)
    }

    func testChunkedUploadReportsBytesAndNeverOverwrites() async throws {
        let provider = ChunkedMemoryProvider()
        let payload = Data((0..<2_500_000).map { UInt8($0 % 241) })
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesChunkedUpload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: localURL) }
        try payload.write(to: localURL)

        var reports: [UInt64] = []
        try await RemoteFileOperations.uploadNewFile(from: localURL, to: "/up.bin", provider: provider) {
            reports.append($0)
        }

        XCTAssertEqual(provider.base.storage.data("/up.bin"), payload)
        XCTAssertEqual(reports.last, UInt64(payload.count))
        XCTAssertGreaterThan(reports.count, 1)

        do {
            try await RemoteFileOperations.uploadNewFile(from: localURL, to: "/up.bin", provider: provider) { _ in }
            XCTFail("Expected an existing file to be a conflict")
        } catch {
            XCTAssertEqual(provider.base.storage.data("/up.bin"), payload)
        }
    }

    func testFailedChunkedUploadRemovesItsPartialFile() async throws {
        let provider = ChunkedMemoryProvider()
        provider.failWriteAtOffset = 1024 * 1024
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesChunkedUploadFailure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: localURL) }
        try Data(count: 2_500_000).write(to: localURL)

        do {
            try await RemoteFileOperations.uploadNewFile(from: localURL, to: "/up.bin", provider: provider) { _ in }
            XCTFail("Expected the injected write failure")
        } catch {
            XCTAssertFalse(provider.base.storage.exists("/up.bin"))
        }
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

/// A file store whose rename refuses an existing target, like SFTP v3 and SMB.
private final class NoReplaceRenameStore: @unchecked Sendable {
    private(set) var files: [String: String]
    var failingSource: String?

    init(_ files: [String: String]) {
        self.files = files
    }

    func rename(_ source: String, _ destination: String) throws {
        guard source != failingSource, files[destination] == nil, let value = files[source] else {
            throw RemoteProviderError.invalidResponse("rename \(source) to \(destination) failed")
        }
        files[source] = nil
        files[destination] = value
    }

    func remove(_ path: String) {
        files[path] = nil
    }
}

/// `MemoryRemoteProvider` with chunked reads and exclusive chunked writes.
private final class ChunkedMemoryProvider: RemoteFileProvider, RemoteChunkReadableProvider,
    RemoteChunkWritableProvider, @unchecked Sendable {
    let base = MemoryRemoteProvider()
    var failWriteAtOffset: UInt64?

    var profile: ConnectionProfile { base.profile }
    var capabilities: ProviderCapabilities { base.capabilities }

    func connect() async throws { }

    func list(path: String) async throws -> [RemoteItem] {
        try await base.list(path: path)
    }

    func attributes(path: String) async throws -> RemoteItem {
        try await base.attributes(path: path)
    }

    func download(path: String, to localURL: URL) async throws {
        XCTFail("A chunked provider should not use the native download")
        try await base.download(path: path, to: localURL)
    }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws {
        XCTFail("A chunked provider should not use the native upload")
        try await base.upload(from: localURL, to: path, overwrite: overwrite)
    }

    func remove(path: String, isDirectory: Bool) async throws {
        try await base.remove(path: path, isDirectory: isDirectory)
    }

    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data {
        guard let data = base.storage.data(path) else { throw RemoteProviderError.notFound("missing \(path)") }
        let start = Int(min(offset, UInt64(data.count)))
        return data.subdata(in: start..<min(data.count, start + length))
    }

    func prepareChunkedUpload(path: String, overwrite: Bool, resumeOffset: UInt64) async throws -> UInt64 {
        if !overwrite, base.storage.exists(path) {
            throw RemoteProviderError.conflict("exists \(path)")
        }
        base.storage.write(path, Data())
        return 0
    }

    func writeChunk(path: String, data: Data, offset: UInt64) async throws {
        if offset == failWriteAtOffset {
            throw RemoteProviderError.invalidResponse("injected write failure")
        }
        var current = base.storage.data(path) ?? Data()
        XCTAssertEqual(UInt64(current.count), offset)
        current.append(data)
        base.storage.write(path, current)
    }
}
