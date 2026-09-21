import Foundation
import XCTest
@testable import RemoteFiles

final class CacheManagerTests: XCTestCase {
    func testConcurrentMaterializeSharesOneDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesCacheManagerTests-\(UUID())", isDirectory: true)
        let cache = CacheManager(root: root)
        let provider = CountingCacheProvider()
        let item = RemoteItem(
            name: "shared.txt",
            path: "/shared.txt",
            kind: .file,
            size: 4,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            revision: RemoteRevision(
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                size: 4
            )
        )
        defer { try? FileManager.default.removeItem(at: root) }

        async let first = cache.materialize(provider: provider, item: item)
        async let second = cache.materialize(provider: provider, item: item)
        let (firstURL, secondURL) = try await (first, second)

        XCTAssertEqual(firstURL, secondURL)
        XCTAssertEqual(provider.downloadCount, 1)
        XCTAssertEqual(try Data(contentsOf: firstURL), Data("data".utf8))
    }

    func testChangedRevisionUsesDifferentCachedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesCacheManagerTests-\(UUID())", isDirectory: true)
        let cache = CacheManager(root: root)
        let provider = CountingCacheProvider()
        let oldItem = RemoteItem(
            name: "revision.txt",
            path: "/revision.txt",
            kind: .file,
            size: 4,
            revision: RemoteRevision(eTag: "old", size: 4)
        )
        let newItem = RemoteItem(
            name: "revision.txt",
            path: "/revision.txt",
            kind: .file,
            size: 4,
            revision: RemoteRevision(eTag: "new", size: 4)
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let oldURL = try await cache.materialize(provider: provider, item: oldItem)
        let newURL = try await cache.materialize(provider: provider, item: newItem)

        XCTAssertNotEqual(oldURL, newURL)
        XCTAssertEqual(provider.downloadCount, 2)
    }

    func testUnreliableRevisionDoesNotReuseDiskCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesCacheManagerTests-\(UUID())", isDirectory: true)
        let cache = CacheManager(root: root)
        let provider = CountingCacheProvider()
        let item = RemoteItem(
            name: "unknown.txt",
            path: "/unknown.txt",
            kind: .file,
            size: 4,
            revision: RemoteRevision(size: 4, opaqueIdentifier: "stable-id")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = try await cache.materialize(provider: provider, item: item)
        let secondURL = try await cache.materialize(provider: provider, item: item)

        XCTAssertEqual(firstURL, secondURL)
        XCTAssertEqual(provider.downloadCount, 2)
    }

    func testSmallCapacityEvictsLeastRecentlyUsedAndPreservesReservedFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesCacheManagerTests-\(UUID())", isDirectory: true)
        let cache = CacheManager(root: root, maximumBytes: 8)
        let provider = CountingCacheProvider()
        let firstItem = cacheItem(name: "first.txt")
        let secondItem = cacheItem(name: "second.txt")
        let thirdItem = cacheItem(name: "third.txt")
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = try await cache.materialize(provider: provider, item: firstItem)
        let secondURL = try await cache.materialize(provider: provider, item: secondItem)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: firstURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: secondURL.path
        )

        _ = try await cache.materialize(provider: provider, item: firstItem)
        let firstAccess = try XCTUnwrap(
            firstURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        let secondAccess = try XCTUnwrap(
            secondURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        XCTAssertGreaterThan(firstAccess, secondAccess)

        let thirdURL = try await cache.materialize(provider: provider, item: thirdItem)

        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thirdURL.path))
        let cacheSize = try await cache.cacheSize()
        XCTAssertEqual(cacheSize, 8)

        let transfersURL = root.appendingPathComponent("Transfers", isDirectory: true)
        let offlineExportsURL = root.appendingPathComponent("OfflineExports", isDirectory: true)
        let stagingURL = root
            .appendingPathComponent(provider.profile.id.uuidString, isDirectory: true)
            .appendingPathComponent(".in-progress.staging")
        try FileManager.default.createDirectory(at: transfersURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: offlineExportsURL, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: transfersURL.appendingPathComponent("active.bin"))
        try Data(repeating: 2, count: 32).write(to: offlineExportsURL.appendingPathComponent("export.bin"))
        try Data(repeating: 3, count: 32).write(to: stagingURL)

        try await cache.clear()

        XCTAssertTrue(FileManager.default.fileExists(atPath: transfersURL.appendingPathComponent("active.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: offlineExportsURL.appendingPathComponent("export.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURL.path))
        let clearedCacheSize = try await cache.cacheSize()
        XCTAssertEqual(clearedCacheSize, 0)
    }
}

private func cacheItem(name: String) -> RemoteItem {
    RemoteItem(
        name: name,
        path: "/\(name)",
        kind: .file,
        size: 4,
        revision: RemoteRevision(eTag: name, size: 4)
    )
}

private final class CountingCacheProvider: RemoteFileProvider, @unchecked Sendable {
    let profile = ConnectionProfile.empty(for: .sftp)
    let capabilities = ProviderCapabilities.basicReadWrite

    private let lock = NSLock()
    private var downloadCountStorage = 0

    var downloadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return downloadCountStorage
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }

    func download(path: String, to localURL: URL) async throws {
        incrementDownloadCount()
        try await Task.sleep(nanoseconds: 25_000_000)
        try Data("data".utf8).write(to: localURL)
    }

    private func incrementDownloadCount() {
        lock.lock()
        downloadCountStorage += 1
        lock.unlock()
    }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }
    func createDirectory(path: String) async throws { }
}
