import Foundation
import XCTest
@testable import RemoteFiles

@MainActor
final class TransferEngineTests: XCTestCase {
    func testRetryWaitsForCancelledExecutionBeforeStartingReplacement() async throws {
        let downloadGate = TransferDownloadGate()
        let sourceProfile = ConnectionProfile.empty(for: .sftp)
        let destinationProfile = ConnectionProfile.empty(for: .sftp)
        let source = BlockingDownloadProvider(profile: sourceProfile, gate: downloadGate)
        let destination = NoopTransferProvider(profile: destinationProfile)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesTransferEngineTests-\(UUID())", isDirectory: true)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        let item = RemoteItem(name: "race.txt", path: "/race.txt", kind: .file)

        defer { try? FileManager.default.removeItem(at: directory) }
        defer { downloadGate.release() }
        engine.copyFile(item: item, from: source, to: destination, destinationPath: "/race.txt")

        try await waitUntil { downloadGate.isWaiting }
        let running = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(running.state, .running)

        engine.cancel(running)
        let cancelled = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(cancelled.state, .cancelled)

        let connections = ConnectionStore()
        engine.retry(cancelled, using: connections)

        let queued = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(queued.id, running.id)
        XCTAssertEqual(queued.state, .queued)
        XCTAssertNil(queued.errorMessage)
        XCTAssertTrue(downloadGate.isWaiting)

        downloadGate.release()
        try await waitUntil {
            guard let record = engine.records.first(where: { $0.id == running.id }) else { return false }
            return record.state == .failed
                && record.errorMessage == "The source or destination connection no longer exists."
        }

        if let record = engine.records.first(where: { $0.id == running.id }) {
            engine.remove(record)
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for transfer state")
    }
}

private final class TransferDownloadGate: @unchecked Sendable {
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

private final class BlockingDownloadProvider: RemoteFileProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities.basicReadWrite
    private let gate: TransferDownloadGate

    init(profile: ConnectionProfile, gate: TransferDownloadGate) {
        self.profile = profile
        self.gate = gate
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func attributes(path: String) async throws -> RemoteItem {
        RemoteItem(name: "race.txt", path: path, kind: .file)
    }
    func download(path: String, to localURL: URL) async throws {
        await gate.wait()
    }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }
    func createDirectory(path: String) async throws { }
}

private final class NoopTransferProvider: RemoteFileProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities.basicReadWrite

    init(profile: ConnectionProfile) {
        self.profile = profile
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }
    func createDirectory(path: String) async throws { }
}
