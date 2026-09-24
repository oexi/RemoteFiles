import Foundation
import XCTest
@testable import RemoteFiles

@MainActor
final class BrowserViewModelTests: XCTestCase {
    func testSupersededListingDoesNotReplaceNewerFolder() async throws {
        let provider = GatedListProvider()
        let model = BrowserViewModel(profile: rootProfile(), makeProvider: { _ in provider })
        await model.start()
        XCTAssertEqual(model.items.map(\.path), ["/fast", "/slow"])

        provider.gate("/slow")
        let slowNavigation = Task {
            await model.enter(RemoteItem(name: "slow", path: "/slow", kind: .directory))
        }
        await provider.waitUntilListing("/slow")
        // The previous folder's rows must not remain visible under the new path.
        XCTAssertEqual(model.currentPath, "/slow")
        XCTAssertTrue(model.items.isEmpty)

        await model.enter(RemoteItem(name: "fast", path: "/fast", kind: .directory))
        XCTAssertEqual(model.items.map(\.path), ["/fast/file.txt"])

        provider.release("/slow")
        await slowNavigation.value

        XCTAssertEqual(model.currentPath, "/fast")
        XCTAssertEqual(model.items.map(\.path), ["/fast/file.txt"])
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.errorMessage)
    }

    func testStartPathOverridesInitialPath() async throws {
        let provider = GatedListProvider()
        let model = BrowserViewModel(profile: rootProfile(), startPath: "/fast/", makeProvider: { _ in provider })
        XCTAssertEqual(model.currentPath, "/fast")

        await model.start()
        XCTAssertEqual(model.items.map(\.path), ["/fast/file.txt"])
    }

    func testSupersededListingFailureIsNotReported() async throws {
        let provider = GatedListProvider()
        let model = BrowserViewModel(profile: rootProfile(), makeProvider: { _ in provider })
        await model.start()

        provider.gate("/slow", failing: true)
        let slowNavigation = Task {
            await model.enter(RemoteItem(name: "slow", path: "/slow", kind: .directory))
        }
        await provider.waitUntilListing("/slow")
        await model.enter(RemoteItem(name: "fast", path: "/fast", kind: .directory))
        provider.release("/slow")
        await slowNavigation.value

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.items.map(\.path), ["/fast/file.txt"])
    }

    func testRefreshReconnectsAfterInitialConnectionFailure() async throws {
        let provider = GatedListProvider(connectFailures: 1)
        let model = BrowserViewModel(profile: rootProfile(), makeProvider: { _ in provider })

        await model.start()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.provider)
        XCTAssertTrue(model.items.isEmpty)

        model.errorMessage = nil
        await model.refresh()

        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.provider)
        XCTAssertEqual(model.items.map(\.path), ["/fast", "/slow"])
        XCTAssertEqual(provider.connectAttempts, 2)
    }

    private func rootProfile() -> ConnectionProfile {
        var profile = ConnectionProfile.empty(for: .sftp)
        profile.initialPath = "/"
        return profile
    }
}

private enum GatedListError: Error {
    case connectFailed
    case listFailed
}

private final class GatedListProvider: RemoteFileProvider, @unchecked Sendable {
    let profile = ConnectionProfile.empty(for: .sftp)
    let capabilities = ProviderCapabilities.basicReadWrite

    private let lock = NSLock()
    private var remainingConnectFailures: Int
    private var attempts = 0
    private var gated: [String: Bool] = [:]
    private var started: Set<String> = []
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

    init(connectFailures: Int = 0) {
        remainingConnectFailures = connectFailures
    }

    var connectAttempts: Int { lock.withLock { attempts } }

    func gate(_ path: String, failing: Bool = false) {
        lock.withLock { gated[path] = failing }
    }

    func release(_ path: String) {
        let continuation = lock.withLock { waiting.removeValue(forKey: path) }
        continuation?.resume()
    }

    func waitUntilListing(_ path: String) async {
        for _ in 0..<2_000 {
            if lock.withLock({ started.contains(path) }) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for a listing of \(path)")
    }

    func connect() async throws {
        let shouldFail = lock.withLock {
            attempts += 1
            guard remainingConnectFailures > 0 else { return false }
            remainingConnectFailures -= 1
            return true
        }
        if shouldFail { throw GatedListError.connectFailed }
    }

    func list(path: String) async throws -> [RemoteItem] {
        if let failing = lock.withLock({ gated[path] }) {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    waiting[path] = continuation
                    started.insert(path)
                }
            }
            if failing { throw GatedListError.listFailed }
        }
        switch path {
        case "/":
            return [
                RemoteItem(name: "fast", path: "/fast", kind: .directory),
                RemoteItem(name: "slow", path: "/slow", kind: .directory)
            ]
        case "/fast":
            return [RemoteItem(name: "file.txt", path: "/fast/file.txt", kind: .file)]
        case "/slow":
            return [RemoteItem(name: "stale.txt", path: "/slow/stale.txt", kind: .file)]
        default:
            return []
        }
    }

    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }
}

@MainActor
final class BrowserUploadConflictTests: XCTestCase {
    func testKeepBothUploadsBesideExistingFile() async throws {
        let storage = MemoryRemoteProvider.Storage()
        storage.write("/report.txt", Data("old".utf8))
        var profile = ConnectionProfile.empty(for: .sftp)
        profile.initialPath = "/"
        let provider = MemoryRemoteProvider(profile: profile, storage: storage)
        let model = BrowserViewModel(profile: profile, makeProvider: { _ in provider })
        await model.start()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UploadConflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("report.txt")
        try Data("new".utf8).write(to: local)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))

        let upload = Task { await model.upload(localURLs: [local], transfers: engine) }
        for _ in 0..<500 where model.pendingUploadConflict == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.pendingUploadConflict?.name, "report.txt")
        model.resolveUploadConflict(.keepBoth, applyToAll: false)
        await upload.value

        XCTAssertEqual(storage.data("/report.txt"), Data("old".utf8))
        XCTAssertEqual(storage.data("/report copy.txt"), Data("new".utf8))
        XCTAssertNil(model.errorMessage)
    }

    func testSkipLeavesExistingFileUntouched() async throws {
        let storage = MemoryRemoteProvider.Storage()
        storage.write("/report.txt", Data("old".utf8))
        var profile = ConnectionProfile.empty(for: .sftp)
        profile.initialPath = "/"
        let provider = MemoryRemoteProvider(profile: profile, storage: storage)
        let model = BrowserViewModel(profile: profile, makeProvider: { _ in provider })
        await model.start()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UploadConflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("report.txt")
        try Data("new".utf8).write(to: local)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))

        let upload = Task { await model.upload(localURLs: [local], transfers: engine) }
        for _ in 0..<500 where model.pendingUploadConflict == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        model.resolveUploadConflict(.skip, applyToAll: false)
        await upload.value

        XCTAssertEqual(storage.allFiles, ["/report.txt"])
        XCTAssertEqual(storage.data("/report.txt"), Data("old".utf8))
        XCTAssertTrue(engine.records.isEmpty)
    }
}

@MainActor
final class BrowserSymbolicLinkTests: XCTestCase {
    func testLinkToFolderIsFolderLikeButStaysALink() {
        let link = RemoteItem(name: "var", path: "/var", kind: .symbolicLink, size: 3, linkTargetKind: .directory)
        XCTAssertTrue(link.isFolderLike)
        XCTAssertFalse(link.isDirectory)
        XCTAssertFalse(RemoteItem(name: "run", path: "/run", kind: .symbolicLink, linkTargetKind: .file).isFolderLike)
        XCTAssertFalse(RemoteItem(name: "lib64", path: "/lib64", kind: .symbolicLink).isFolderLike)
        XCTAssertTrue(RemoteItem(name: "tmp", path: "/tmp", kind: .directory).isFolderLike)
    }

    func testOpeningResolvedFolderLinkEntersWithoutStat() async throws {
        let storage = MemoryRemoteProvider.Storage()
        // The server resolves the link path, so listing it shows the target's contents.
        storage.makeDirectory("/var")
        storage.write("/var/log.txt", Data("x".utf8))
        var profile = ConnectionProfile.empty(for: .sftp)
        profile.initialPath = "/"
        let provider = MemoryRemoteProvider(profile: profile, storage: storage)
        let model = BrowserViewModel(profile: profile, makeProvider: { _ in provider })
        await model.start()

        let link = RemoteItem(name: "var", path: "/var", kind: .symbolicLink, size: 3, linkTargetKind: .directory)
        let file = await model.openLink(link)

        XCTAssertNil(file)
        XCTAssertEqual(model.currentPath, "/var")
        XCTAssertEqual(model.items.map(\.name), ["log.txt"])
        XCTAssertFalse(storage.operations.contains("stat:/var"))
    }
}
