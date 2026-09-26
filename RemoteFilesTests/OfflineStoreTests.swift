import Foundation
import XCTest
@testable import RemoteFiles

@MainActor
final class OfflineStoreTests: XCTestCase {
    func testFailedRefreshKeepsPreviousOfflineCopyAndIndex() async throws {
        let fixture = try OfflineStoreFixture()
        defer { fixture.remove() }

        let profile = ConnectionProfile.empty(for: .ftp)
        let old = OfflineItem(
            id: UUID(),
            profileID: profile.id,
            profileName: profile.name,
            remotePath: "/document.txt",
            fileName: "document.txt",
            storedFileName: "old-document.txt",
            size: 3,
            pinnedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try fixture.seed([old], data: Data("old".utf8))

        let store = OfflineStore(root: fixture.root)
        let provider = OfflineTestProvider(
            profile: profile,
            downloadResult: .failure(Data("partial".utf8))
        )
        let engine = TransferEngine(fileURL: fixture.transferURL)
        let item = RemoteItem(
            name: "document.txt",
            path: old.remotePath,
            kind: .file,
            size: 7
        )

        do {
            try await store.pin(provider: provider, item: item, transfers: engine)
            XCTFail("Expected the refresh to fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The simulated download failed.")
        }

        XCTAssertEqual(store.items, [old])
        XCTAssertEqual(try Data(contentsOf: store.localURL(for: old)), Data("old".utf8))
        let persisted = try JSONDecoder().decode([OfflineItem].self, from: Data(contentsOf: fixture.indexURL))
        XCTAssertEqual(persisted, [old])
        XCTAssertEqual(try fixture.offlineEntries(), ["old-document.txt"])
    }

    func testSuccessfulRefreshCommitsNewIndexBeforeRemovingOldCopy() async throws {
        let fixture = try OfflineStoreFixture()
        defer { fixture.remove() }

        let profile = ConnectionProfile.empty(for: .ftp)
        let old = OfflineItem(
            id: UUID(),
            profileID: profile.id,
            profileName: profile.name,
            remotePath: "/document.txt",
            fileName: "document.txt",
            storedFileName: "old-document.txt",
            size: 3,
            pinnedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try fixture.seed([old], data: Data("old".utf8))

        let store = OfflineStore(root: fixture.root)
        let provider = OfflineTestProvider(
            profile: profile,
            downloadResult: .success(Data("new copy".utf8))
        )
        let engine = TransferEngine(fileURL: fixture.transferURL)
        let item = RemoteItem(
            name: "document.txt",
            path: old.remotePath,
            kind: .file,
            size: 8
        )

        try await store.pin(provider: provider, item: item, transfers: engine)

        let replacement = try XCTUnwrap(store.items.first)
        XCTAssertNotEqual(replacement.id, old.id)
        XCTAssertEqual(replacement.remotePath, old.remotePath)
        XCTAssertEqual(try Data(contentsOf: store.localURL(for: replacement)), Data("new copy".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.localURL(for: old).path))

        let persisted = try JSONDecoder().decode([OfflineItem].self, from: Data(contentsOf: fixture.indexURL))
        XCTAssertEqual(persisted, [replacement])
        XCTAssertEqual(try fixture.offlineEntries(), [replacement.storedFileName])
    }

    func testUnpinDuringRefreshInvalidatesPendingReplacement() async throws {
        let fixture = try OfflineStoreFixture()
        defer { fixture.remove() }

        let profile = ConnectionProfile.empty(for: .ftp)
        let old = OfflineItem(
            id: UUID(),
            profileID: profile.id,
            profileName: profile.name,
            remotePath: "/document.txt",
            fileName: "document.txt",
            storedFileName: "old-document.txt",
            size: 3,
            pinnedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try fixture.seed([old], data: Data("old".utf8))

        let store = OfflineStore(root: fixture.root)
        let gate = OfflinePinDownloadGate()
        let provider = OfflineBlockingProvider(profile: profile, gate: gate)
        let engine = TransferEngine(fileURL: fixture.transferURL)
        let item = RemoteItem(
            name: "document.txt",
            path: old.remotePath,
            kind: .file,
            size: 3
        )
        let pinTask = Task { @MainActor in
            try await store.pin(provider: provider, item: item, transfers: engine)
        }
        defer { gate.release() }

        try await waitUntil { gate.isWaiting }
        store.unpin(profileID: profile.id, path: item.path)
        gate.release()

        do {
            try await pinTask.value
            XCTFail("Expected the invalidated refresh to stop")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(try fixture.offlineEntries(), [])
    }

    func testDirectoryRefreshRejectsPathSeparatorsInChildNames() async throws {
        let fixture = try OfflineStoreFixture()
        defer { fixture.remove() }

        let profile = ConnectionProfile.empty(for: .ftp)
        let store = OfflineStore(root: fixture.root)
        let provider = OfflineTestProvider(
            profile: profile,
            downloadResult: .success(Data("should not download".utf8)),
            children: [RemoteItem(
                name: "../escaped.txt",
                path: "/Folder/../escaped.txt",
                kind: .file,
                size: 17
            )]
        )
        let engine = TransferEngine(fileURL: fixture.transferURL)
        let item = RemoteItem(name: "Folder", path: "/Folder", kind: .directory)

        do {
            try await store.pin(provider: provider, item: item, transfers: engine)
            XCTFail("Expected the invalid child name to be rejected")
        } catch let error as RemoteProviderError {
            guard case .invalidResponse(_) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("escaped.txt").path
        ))
        XCTAssertEqual(try fixture.offlineEntries(), [])
    }

    func testExtractArchiveIntoFolderKeepsTreeInOneOfflineFolder() async throws {
        let fixture = try OfflineStoreFixture()
        defer { fixture.remove() }
        let archive = try fixture.seedSevenZipArchive()

        let store = OfflineStore(root: fixture.root)
        let inserted = try await store.extractArchive(archive, intoFolder: true)

        XCTAssertEqual(inserted.map(\.fileName), ["sample"])
        XCTAssertEqual(inserted.map(\.directory), [true])
        let folder = store.localURL(for: inserted[0])
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("folder/a.txt"), encoding: .utf8),
            "hello 7z"
        )
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("b.txt"), encoding: .utf8),
            "top level"
        )
        XCTAssertEqual(inserted[0].size, 17)
        XCTAssertEqual(store.items.map(\.fileName), ["sample", "sample.7z"])

        let second = try await store.extractArchive(archive, intoFolder: true)
        XCTAssertEqual(second.map(\.fileName), ["sample 2"])
    }

    func testExtractArchiveIntoCurrentFolderAddsEachTopLevelItem() async throws {
        let fixture = try OfflineStoreFixture()
        defer { fixture.remove() }
        let archive = try fixture.seedSevenZipArchive()

        let store = OfflineStore(root: fixture.root)
        let inserted = try await store.extractArchive(archive)

        XCTAssertEqual(inserted.map(\.fileName), ["b.txt", "folder"])
        XCTAssertEqual(inserted.map(\.directory), [false, true])
        XCTAssertEqual(
            try String(contentsOf: store.localURL(for: inserted[1]).appendingPathComponent("a.txt"), encoding: .utf8),
            "hello 7z"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.localURL(for: inserted[1]).appendingPathComponent("empty.txt").path
        ))
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for the download to start")
    }
}

private struct OfflineStoreFixture {
    let base: URL
    let root: URL
    let indexURL: URL
    let transferURL: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesOfflineStoreTests-\(UUID())", isDirectory: true)
        root = base.appendingPathComponent("Offline", isDirectory: true)
        indexURL = base.appendingPathComponent("offline.json")
        transferURL = base.appendingPathComponent("transfers.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func seed(_ items: [OfflineItem], data: Data) throws {
        try data.write(to: root.appendingPathComponent(items[0].storedFileName))
        try JSONEncoder().encode(items).write(to: indexURL)
    }

    func seedSevenZipArchive() throws -> OfflineItem {
        let profile = ConnectionProfile.empty(for: .sftp)
        let item = OfflineItem(
            id: UUID(),
            profileID: profile.id,
            profileName: profile.name,
            remotePath: "/sample.7z",
            fileName: "sample.7z",
            storedFileName: "archive-sample.7z",
            size: Int64(SevenZipFixtures.lzma2.count),
            pinnedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try seed([item], data: SevenZipFixtures.lzma2)
        return item
    }

    func offlineEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .sorted()
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}

private final class OfflineTestProvider: RemoteFileProvider, @unchecked Sendable {
    enum DownloadResult {
        case success(Data)
        case failure(Data)
    }

    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities.basicReadWrite
    private let downloadResult: DownloadResult
    private let children: [RemoteItem]

    init(
        profile: ConnectionProfile,
        downloadResult: DownloadResult,
        children: [RemoteItem] = []
    ) {
        self.profile = profile
        self.downloadResult = downloadResult
        self.children = children
    }

    func connect() async throws { }

    func list(path: String) async throws -> [RemoteItem] {
        children
    }

    func download(path: String, to localURL: URL) async throws {
        switch downloadResult {
        case .success(let data):
            try data.write(to: localURL)
        case .failure(let partialData):
            try partialData.write(to: localURL)
            throw RemoteProviderError.invalidResponse("The simulated download failed.")
        }
    }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }
    func createDirectory(path: String) async throws { }
}

private final class OfflinePinDownloadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waitingStorage = false
    private var releasedStorage = false
    private var continuationStorage: CheckedContinuation<Void, Never>?

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waitingStorage && !releasedStorage
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if releasedStorage {
                lock.unlock()
                continuation.resume()
            } else {
                waitingStorage = true
                continuationStorage = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        releasedStorage = true
        let continuation = continuationStorage
        continuationStorage = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class OfflineBlockingProvider: RemoteFileProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities.basicReadWrite
    private let gate: OfflinePinDownloadGate

    init(profile: ConnectionProfile, gate: OfflinePinDownloadGate) {
        self.profile = profile
        self.gate = gate
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }

    func download(path: String, to localURL: URL) async throws {
        await gate.wait()
        try Data("new".utf8).write(to: localURL)
    }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }
    func createDirectory(path: String) async throws { }
}
