import Foundation
import XCTest
@testable import RemoteFiles

@MainActor
final class TransferQueueFeatureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferQueueFeatureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOldestCompletedRecordsArePrunedBeyondTheLimit() async throws {
        let profile = ConnectionProfile.empty(for: .sftp)
        let history: [TransferRecord] = (0..<TransferEngine.maxCompletedRecords).map { index in
            var record = TransferRecord(
                fileName: "old-\(index).txt",
                sourceProfileID: profile.id,
                sourcePath: "/old-\(index).txt",
                destinationProfileID: profile.id,
                destinationPath: "/old-\(index).txt",
                overwrite: false,
                source: "source",
                destination: "destination",
                kind: .upload
            )
            record.state = .completed
            return record
        }
        let transfersURL = directory.appendingPathComponent("transfers.json")
        try JSONEncoder().encode(history).write(to: transfersURL)
        let engine = TransferEngine(fileURL: transfersURL)
        XCTAssertEqual(engine.records.count, TransferEngine.maxCompletedRecords)

        let storage = MemoryRemoteProvider.Storage()
        let provider = MemoryRemoteProvider(profile: profile, storage: storage)
        let local = directory.appendingPathComponent("new.txt")
        try Data("new".utf8).write(to: local)
        try await engine.uploadFile(localURL: local, to: provider, destinationPath: "/new.txt")

        XCTAssertEqual(engine.records.count, TransferEngine.maxCompletedRecords)
        XCTAssertEqual(engine.records.first?.fileName, "new.txt")
        XCTAssertFalse(engine.records.contains { $0.id == history.last?.id })
        let restored = TransferEngine(fileURL: transfersURL)
        XCTAssertEqual(restored.records.count, TransferEngine.maxCompletedRecords)
        XCTAssertEqual(restored.records.first?.state, .completed)
    }

    func testRemovingUnfinishedServerTransferDeletesItsPartial() async throws {
        let storage = MemoryRemoteProvider.Storage()
        let destinationProfile = ConnectionProfile.empty(for: .sftp)
        var record = TransferRecord(
            fileName: "a.bin",
            sourceProfileID: UUID(),
            sourcePath: "/a.bin",
            destinationProfileID: destinationProfile.id,
            destinationPath: "/dest/a.bin",
            overwrite: false,
            source: "source",
            destination: "destination"
        )
        record.state = .failed
        let partial = "/dest/.remotefiles-\(record.id.uuidString.lowercased()).partial"
        storage.makeDirectory("/dest")
        storage.write(partial, Data([1, 2, 3]))
        let transfersURL = directory.appendingPathComponent("transfers.json")
        try JSONEncoder().encode([record]).write(to: transfersURL)

        let engine = TransferEngine(fileURL: transfersURL) { profile in
            MemoryRemoteProvider(profile: profile, storage: storage)
        }
        engine.remove(record, profiles: [destinationProfile])

        XCTAssertTrue(engine.records.isEmpty)
        try await waitUntil { !storage.exists(partial) }
    }

    func testFailedUploadIsRetainedAndRetrySucceeds() async throws {
        let storage = MemoryRemoteProvider.Storage()
        storage.makeDirectory("/up")
        let profile = ConnectionProfile.empty(for: .sftp)
        let failing = MemoryRemoteProvider(profile: profile, storage: storage)
        failing.failure = { operation in
            operation.hasPrefix("upload:") ? MemoryRemoteProvider.Failure.injected(operation) : nil
        }
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json")) { profile in
            MemoryRemoteProvider(profile: profile, storage: storage)
        }
        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let local = staging.appendingPathComponent("report.txt")
        try Data("hello".utf8).write(to: local)

        do {
            try await engine.uploadFile(
                localURL: local,
                to: failing,
                destinationPath: "/up/report.txt",
                retainForRetry: true
            )
            XCTFail("Expected the injected upload failure")
        } catch { }

        let failed = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(failed.state, .failed)
        let retained = try XCTUnwrap(failed.retainedLocalPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained))
        XCTAssertTrue(engine.canRetry(failed))

        engine.retryUpload(failed, profiles: [profile])
        try await waitUntil {
            engine.records.first?.state == .completed && engine.records.first?.retainedLocalPath == nil
        }

        XCTAssertEqual(storage.data("/up/report.txt"), Data("hello".utf8))
        XCTAssertNil(engine.records.first?.retainedLocalPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained))
        XCTAssertEqual(storage.allFiles, ["/up/report.txt"])
    }

    func testCopyItemsCopiesFolderTreeAndMovesWhenRequested() async throws {
        let source = MemoryRemoteProvider.Storage()
        source.makeDirectory("/docs")
        source.makeDirectory("/docs/sub")
        source.write("/docs/a.txt", Data("A".utf8))
        source.write("/docs/sub/b.txt", Data("B".utf8))
        let destination = MemoryRemoteProvider.Storage()
        destination.makeDirectory("/backup")
        destination.makeDirectory("/backup/docs")

        let sourceProfile = ConnectionProfile.empty(for: .sftp)
        let destinationProfile = ConnectionProfile.empty(for: .smb)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json")) { profile in
            MemoryRemoteProvider(profile: profile, storage: profile.id == sourceProfile.id ? source : destination)
        }

        let completed = try await engine.copyItems(
            [RemoteItem(name: "docs", path: "/docs", kind: .directory)],
            from: sourceProfile,
            to: destinationProfile,
            destinationDirectory: "/backup",
            removeSources: true
        )

        XCTAssertTrue(completed)
        // "/backup/docs" already existed, so the copy is placed beside it.
        XCTAssertEqual(destination.data("/backup/docs copy/a.txt"), Data("A".utf8))
        XCTAssertEqual(destination.data("/backup/docs copy/sub/b.txt"), Data("B".utf8))
        XCTAssertEqual(engine.records.count, 2)
        XCTAssertTrue(engine.records.allSatisfy { $0.state == .completed })
        XCTAssertFalse(source.exists("/docs"))
        XCTAssertFalse(source.exists("/docs/a.txt"))
    }

    func testCopyItemsKeepsSourcesWhenAFileFails() async throws {
        let source = MemoryRemoteProvider.Storage()
        source.makeDirectory("/docs")
        source.write("/docs/a.txt", Data("A".utf8))
        let destination = MemoryRemoteProvider.Storage()
        let sourceProfile = ConnectionProfile.empty(for: .sftp)
        let destinationProfile = ConnectionProfile.empty(for: .smb)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json")) { profile in
            let provider = MemoryRemoteProvider(profile: profile, storage: profile.id == sourceProfile.id ? source : destination)
            if profile.id == destinationProfile.id {
                provider.failure = { operation in
                    operation.hasPrefix("upload:") ? MemoryRemoteProvider.Failure.injected(operation) : nil
                }
            }
            return provider
        }

        let completed = try await engine.copyItems(
            [RemoteItem(name: "docs", path: "/docs", kind: .directory)],
            from: sourceProfile,
            to: destinationProfile,
            destinationDirectory: "/",
            removeSources: true
        )

        XCTAssertFalse(completed)
        XCTAssertEqual(engine.records.first?.state, .failed)
        XCTAssertEqual(source.data("/docs/a.txt"), Data("A".utf8))
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
