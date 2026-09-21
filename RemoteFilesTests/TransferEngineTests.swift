import Foundation
import XCTest
@testable import RemoteFiles

@MainActor
final class TransferEngineTests: XCTestCase {
    func testLocalUploadAppearsInTransfers() async throws {
        let profile = ConnectionProfile.empty(for: .ftp)
        let provider = NoopTransferProvider(profile: profile)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesUploadTests-\(UUID())", isDirectory: true)
        let localURL = directory.appendingPathComponent("upload.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 4096).write(to: localURL)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        defer { try? FileManager.default.removeItem(at: directory) }

        try await engine.uploadFile(localURL: localURL, to: provider, destinationPath: "/upload.bin")

        let record = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(record.operationKind, .upload)
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.transferredBytes, 4096)
        XCTAssertEqual(record.totalBytes, 4096)
    }

    func testLocalDownloadAppearsInTransfers() async throws {
        let data = Data("offline contents".utf8)
        let profile = ConnectionProfile.empty(for: .ftp)
        let provider = StaticDownloadProvider(profile: profile, data: data)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesDownloadTests-\(UUID())", isDirectory: true)
        let localURL = directory.appendingPathComponent("offline.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        let item = RemoteItem(
            name: "offline.txt",
            path: "/offline.txt",
            kind: .file,
            size: Int64(data.count)
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try await engine.downloadFile(item: item, from: provider, to: localURL)

        XCTAssertEqual(try Data(contentsOf: localURL), data)
        let record = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(record.operationKind, .download)
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.transferredBytes, UInt64(data.count))
        XCTAssertEqual(record.totalBytes, Int64(data.count))
    }

    func testChunkedLocalDownloadUsesBoundedLargeReadsAndFlushesFinalProgress() async throws {
        let data = Data(repeating: 0x5A, count: 4 * 1024 * 1024 + 123)
        let profile = ConnectionProfile.empty(for: .ftp)
        let provider = ChunkedDownloadProvider(profile: profile, data: data)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesChunkedDownloadTests-\(UUID())", isDirectory: true)
        let localURL = directory.appendingPathComponent("download.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        let item = RemoteItem(
            name: "download.bin",
            path: "/download.bin",
            kind: .file,
            size: Int64(data.count)
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try await engine.downloadFile(item: item, from: provider, to: localURL)

        XCTAssertEqual(try Data(contentsOf: localURL), data)
        XCTAssertEqual(provider.maximumRequestedLength, 4 * 1024 * 1024)
        let record = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.transferredBytes, UInt64(data.count))
        XCTAssertEqual(record.progress, 1)
        let restored = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        let persistedRecord = try XCTUnwrap(restored.records.first)
        XCTAssertEqual(persistedRecord.state, .completed)
        XCTAssertEqual(persistedRecord.transferredBytes, UInt64(data.count))
        XCTAssertEqual(persistedRecord.progress, 1)
    }

    func testChunkedLocalUploadUsesBoundedReadsAndFlushesFinalProgress() async throws {
        let data = Data(repeating: 0xA5, count: 4 * 1024 * 1024 + 123)
        let profile = ConnectionProfile.empty(for: .ftp)
        let provider = ChunkedUploadProvider(profile: profile)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesChunkedUploadTests-\(UUID())", isDirectory: true)
        let localURL = directory.appendingPathComponent("upload.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: localURL)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        defer { try? FileManager.default.removeItem(at: directory) }

        try await engine.uploadFile(localURL: localURL, to: provider, destinationPath: "/upload.bin")

        XCTAssertEqual(provider.data, data)
        XCTAssertEqual(provider.maximumChunkLength, 4 * 1024 * 1024)
        let record = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.transferredBytes, UInt64(data.count))
        XCTAssertEqual(record.progress, 1)
    }

    func testResumeDoesNotTrustUnconfirmedRemotePartialBytes() async throws {
        let totalBytes = 2 * 1024 * 1024
        let revision = RemoteRevision(
            eTag: nil,
            modifiedAt: Date(timeIntervalSince1970: 1),
            size: Int64(totalBytes),
            opaqueIdentifier: nil
        )
        let item = RemoteItem(
            name: "resume.bin",
            path: "/resume.bin",
            kind: .file,
            size: Int64(totalBytes),
            revision: revision
        )
        let sourceProfile = ConnectionProfile.empty(for: .sftp)
        let destinationProfile = ConnectionProfile.empty(for: .sftp)
        let source = ResumeCheckpointSourceProvider(profile: sourceProfile, item: item)
        let destination = ResumeCheckpointDestinationProvider(
            profile: destinationProfile,
            totalBytes: totalBytes,
            unconfirmedPartialBytes: totalBytes / 2
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesResumeCheckpointTests-\(UUID())", isDirectory: true)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        defer { try? FileManager.default.removeItem(at: directory) }

        // copyFile persists a queued record with a confirmed checkpoint of zero.
        // The destination deliberately reports a larger, unconfirmed partial file.
        engine.copyFile(item: item, from: source, to: destination, destinationPath: "/resume.bin")
        try await waitUntil {
            engine.records.first?.state == .completed
        }

        XCTAssertEqual(destination.preparedResumeOffsets, [0])
        XCTAssertEqual(destination.preparedOverwriteFlags, [true])
        XCTAssertEqual(source.readOffsets, [0])
    }

    func testServerToServerFailsWhenFinalDestinationStatThrows() async throws {
        let totalBytes = 1024
        let item = verificationItem(size: totalBytes, name: "stat-error.bin")
        let source = ResumeCheckpointSourceProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            item: item
        )
        let destination = FinalVerificationDestinationProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            destinationPath: item.path,
            finalStat: .error("Injected final destination stat failure.")
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesFinalStatErrorTests-\(UUID())", isDirectory: true)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        defer { try? FileManager.default.removeItem(at: directory) }

        engine.copyFile(item: item, from: source, to: destination, destinationPath: item.path)
        try await waitUntil { engine.records.first?.state == .failed }

        let record = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(record.errorMessage, "Injected final destination stat failure.")
        XCTAssertTrue(record.commitPending == true)
        XCTAssertNotEqual(record.state, .completed)
    }

    func testServerToServerFailsWhenFinalDestinationSizeIsMissing() async throws {
        let totalBytes = 1024
        let item = verificationItem(size: totalBytes, name: "missing-size.bin")
        let source = ResumeCheckpointSourceProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            item: item
        )
        let destination = FinalVerificationDestinationProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            destinationPath: item.path,
            finalStat: .missingSize
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesFinalMissingSizeTests-\(UUID())", isDirectory: true)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        defer { try? FileManager.default.removeItem(at: directory) }

        engine.copyFile(item: item, from: source, to: destination, destinationPath: item.path)
        try await waitUntil { engine.records.first?.state == .failed }

        let record = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(
            record.errorMessage,
            "Transfer verification failed because the destination size is unavailable."
        )
        XCTAssertTrue(record.commitPending == true)
    }

    func testServerToServerFailsWhenFinalDestinationSizeDoesNotMatch() async throws {
        let totalBytes = 1024
        let item = verificationItem(size: totalBytes, name: "size-mismatch.bin")
        let source = ResumeCheckpointSourceProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            item: item
        )
        let destination = FinalVerificationDestinationProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            destinationPath: item.path,
            finalStat: .size(Int64(totalBytes - 1))
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesFinalSizeMismatchTests-\(UUID())", isDirectory: true)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        defer { try? FileManager.default.removeItem(at: directory) }

        engine.copyFile(item: item, from: source, to: destination, destinationPath: item.path)
        try await waitUntil { engine.records.first?.state == .failed }

        let record = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(
            record.errorMessage,
            "Transfer verification failed: expected \(totalBytes) bytes but destination reports \(totalBytes - 1) bytes."
        )
        XCTAssertTrue(record.commitPending == true)
    }

    func testServerToServerCompletesWhenFinalDestinationSizeMatches() async throws {
        let totalBytes = 1024
        let item = verificationItem(size: totalBytes, name: "verified.bin")
        let source = ResumeCheckpointSourceProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            item: item
        )
        let destination = FinalVerificationDestinationProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            destinationPath: item.path,
            finalStat: .size(Int64(totalBytes))
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesFinalStatSuccessTests-\(UUID())", isDirectory: true)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        defer { try? FileManager.default.removeItem(at: directory) }

        engine.copyFile(item: item, from: source, to: destination, destinationPath: item.path)
        try await waitUntil { engine.records.first?.state == .completed }

        let record = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.transferredBytes, UInt64(totalBytes))
        XCTAssertEqual(record.progress, 1)
        XCTAssertFalse(record.commitPending == true)
        XCTAssertEqual(destination.writtenBytes, totalBytes)
    }

    func testServerToServerUsesDownloadedSizeWhenSourceSizeIsMissing() async throws {
        let item = verificationItem(size: nil, name: "unknown-size.bin")
        let source = ResumeCheckpointSourceProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            item: item
        )
        let destination = FinalVerificationDestinationProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            destinationPath: item.path,
            finalStat: .size(0)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesMissingSourceSizeTests-\(UUID())", isDirectory: true)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        defer { try? FileManager.default.removeItem(at: directory) }

        engine.copyFile(item: item, from: source, to: destination, destinationPath: item.path)
        try await waitUntil { engine.records.first?.state == .completed }

        let record = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.totalBytes, 0)
        XCTAssertEqual(record.transferredBytes, 0)
        XCTAssertEqual(record.progress, 1)
        XCTAssertFalse(record.commitPending == true)
    }

    private func verificationItem(size: Int, name: String) -> RemoteItem {
        verificationItem(size: Int64(size), name: name)
    }

    private func verificationItem(size: Int64?, name: String) -> RemoteItem {
        RemoteItem(
            name: name,
            path: "/\(name)",
            kind: .file,
            size: size,
            revision: RemoteRevision(
                eTag: nil,
                modifiedAt: Date(timeIntervalSince1970: 1),
                size: size,
                opaqueIdentifier: nil
            )
        )
    }

    func testPauseAndCancelDuringFinalRenameCannotOverrideCommittedTransfer() async throws {
        let sourceGate = TransferDownloadGate()
        sourceGate.release()
        let moveGate = TransferDownloadGate()
        let totalBytes = 5 * 1024 * 1024
        let revision = RemoteRevision(
            eTag: nil,
            modifiedAt: Date(timeIntervalSince1970: 1),
            size: Int64(totalBytes),
            opaqueIdentifier: nil
        )
        let item = RemoteItem(
            name: "commit.bin",
            path: "/commit.bin",
            kind: .file,
            size: Int64(totalBytes),
            revision: revision
        )
        let source = PausableChunkSourceProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            item: item,
            gate: sourceGate
        )
        let destination = BlockingMoveDestinationProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            totalBytes: totalBytes,
            moveGate: moveGate
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesCommitBoundaryTests-\(UUID())", isDirectory: true)
        let fileURL = directory.appendingPathComponent("transfers.json")
        let engine = TransferEngine(fileURL: fileURL)
        defer {
            moveGate.release()
            try? FileManager.default.removeItem(at: directory)
        }

        engine.copyFile(item: item, from: source, to: destination, destinationPath: "/commit.bin")
        try await waitUntil { moveGate.isWaiting }
        let committing = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(committing.state, .running)
        engine.cancel(committing)
        engine.pause(committing)
        XCTAssertEqual(engine.records.first?.state, .running)
        let restored = TransferEngine(fileURL: fileURL)
        XCTAssertEqual(restored.records.first?.state, .queued)
        XCTAssertTrue(restored.records.first?.commitPending == true)

        moveGate.release()
        try await waitUntil { engine.records.first?.state == .completed }
        XCTAssertEqual(destination.writtenBytes, totalBytes)
        XCTAssertEqual(engine.records.first?.transferredBytes, UInt64(totalBytes))
    }

    func testLocalUploadCommitBoundaryIgnoresLatePauseAndCancel() async throws {
        let moveGate = TransferDownloadGate()
        let totalBytes = 5 * 1024 * 1024
        let data = Data(repeating: 0x3C, count: totalBytes)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesLocalCommitBoundaryTests-\(UUID())", isDirectory: true)
        let localURL = directory.appendingPathComponent("commit.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: localURL)
        let destination = BlockingMoveDestinationProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            totalBytes: totalBytes,
            moveGate: moveGate
        )
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        let upload = Task {
            try await engine.uploadFile(localURL: localURL, to: destination, destinationPath: "/commit.bin")
        }
        defer {
            moveGate.release()
            upload.cancel()
            try? FileManager.default.removeItem(at: directory)
        }

        try await waitUntil { moveGate.isWaiting }
        let committing = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(committing.state, .running)
        engine.pause(committing)
        engine.cancel(committing)
        XCTAssertEqual(engine.records.first?.state, .running)

        moveGate.release()
        try await upload.value
        XCTAssertEqual(engine.records.first?.state, .completed)
        XCTAssertEqual(destination.writtenBytes, totalBytes)
    }

    func testNativeUploadSuccessAfterCancelWinsWhileTaskStillOwnsSlot() async throws {
        let gate = TransferDownloadGate()
        let data = Data(repeating: 0x58, count: 1024)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesNativeCancelRaceTests-\(UUID())", isDirectory: true)
        let localURL = directory.appendingPathComponent("native.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: localURL)
        let destination = BlockingNativeUploadProvider(
            profile: ConnectionProfile.empty(for: .ftp),
            gate: gate
        )
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        let upload = Task {
            try await engine.uploadFile(localURL: localURL, to: destination, destinationPath: "/native.bin")
        }
        defer {
            gate.release()
            upload.cancel()
            try? FileManager.default.removeItem(at: directory)
        }

        try await waitUntil { gate.isWaiting }
        let running = try XCTUnwrap(engine.records.first)
        engine.cancel(running)
        XCTAssertEqual(engine.records.first?.state, .cancelled)

        gate.release()
        try await upload.value
        XCTAssertTrue(destination.didUpload)
        XCTAssertEqual(destination.uploadedPath, "/native.bin")
        XCTAssertEqual(engine.records.first?.state, .completed)
    }

    func testNativeMoveUploadCancellationRemovesOnlyPartialWithoutMovingFinal() async throws {
        let gate = TransferDownloadGate()
        let data = Data(repeating: 0x61, count: 1024)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesNativeStagingCancelTests-\(UUID())", isDirectory: true)
        let localURL = directory.appendingPathComponent("staged.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: localURL)
        let destination = StagedNativeUploadProvider(
            profile: ConnectionProfile.empty(for: .webdav),
            gate: gate
        )
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        let upload = Task {
            try await engine.uploadFile(localURL: localURL, to: destination, destinationPath: "/staged.bin")
        }
        defer {
            gate.release()
            upload.cancel()
            try? FileManager.default.removeItem(at: directory)
        }

        try await waitUntil { destination.isWaiting }
        let running = try XCTUnwrap(engine.records.first)
        engine.cancel(running)
        gate.release()

        do {
            try await upload.value
            XCTFail("Cancelling a staged native upload should throw cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let record = try XCTUnwrap(engine.records.first)
        let partialPath = RemotePath.join(
            RemotePath.parent(record.destinationPath),
            ".remotefiles-\(record.id.uuidString.lowercased()).partial"
        )
        XCTAssertEqual(record.state, .cancelled)
        XCTAssertEqual(destination.uploadedPaths, [partialPath])
        XCTAssertTrue(destination.movedPaths.isEmpty)
        XCTAssertEqual(destination.removedPaths, [partialPath])
        XCTAssertNil(destination.data(at: record.destinationPath))
    }

    func testNativeMoveUploadStagesThenMovesToFinalDestination() async throws {
        let data = Data(repeating: 0x62, count: 4096)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesNativeStagingSuccessTests-\(UUID())", isDirectory: true)
        let localURL = directory.appendingPathComponent("staged.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: localURL)
        let destination = StagedNativeUploadProvider(
            profile: ConnectionProfile.empty(for: .webdav)
        )
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        defer { try? FileManager.default.removeItem(at: directory) }

        try await engine.uploadFile(localURL: localURL, to: destination, destinationPath: "/staged.bin")

        let record = try XCTUnwrap(engine.records.first)
        let partialPath = RemotePath.join(
            RemotePath.parent(record.destinationPath),
            ".remotefiles-\(record.id.uuidString.lowercased()).partial"
        )
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(destination.uploadedPaths, [partialPath])
        XCTAssertEqual(destination.movedPaths, [[partialPath, "/staged.bin"]])
        XCTAssertTrue(destination.removedPaths.isEmpty)
        XCTAssertEqual(destination.data(at: "/staged.bin"), data)
        XCTAssertNil(destination.data(at: partialPath))
    }

    func testFailedLocalLegacyUploadAbortsAndRemovesOnlyOwnedPartial() async throws {
        let totalBytes = 5 * 1024 * 1024
        let data = Data(repeating: 0x4D, count: totalBytes)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesLegacyAbortTests-\(UUID())", isDirectory: true)
        let localURL = directory.appendingPathComponent("source.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: localURL)
        let destination = FailingLegacyUploadProvider(profile: ConnectionProfile.empty(for: .sftp))
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try await engine.uploadFile(localURL: localURL, to: destination, destinationPath: "/target.bin")
            XCTFail("The injected legacy writer failure should fail the upload")
        } catch {
            // Expected provider failure.
        }

        let record = try XCTUnwrap(engine.records.first)
        let ownedPartial = RemotePath.join(
            RemotePath.parent(record.destinationPath),
            ".remotefiles-\(record.id.uuidString.lowercased()).partial"
        )
        XCTAssertEqual(record.state, .failed)
        XCTAssertTrue(destination.didAbortChunkedUpload)
        XCTAssertEqual(destination.removedPaths, [ownedPartial])
        XCTAssertFalse(destination.removedPaths.contains(record.destinationPath))
    }

    func testPausableTransferStaysPausedUntilExplicitResume() async throws {
        let gate = TransferDownloadGate()
        let totalBytes = 5 * 1024 * 1024
        let revision = RemoteRevision(
            eTag: nil,
            modifiedAt: Date(timeIntervalSince1970: 1),
            size: Int64(totalBytes),
            opaqueIdentifier: nil
        )
        let item = RemoteItem(
            name: "pause.bin",
            path: "/pause.bin",
            kind: .file,
            size: Int64(totalBytes),
            revision: revision
        )
        let source = PausableChunkSourceProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            item: item,
            gate: gate
        )
        let destination = PausableChunkDestinationProvider(
            profile: ConnectionProfile.empty(for: .sftp)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesPauseResumeTests-\(UUID())", isDirectory: true)
        let fileURL = directory.appendingPathComponent("transfers.json")
        let engine = TransferEngine(fileURL: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { gate.release() }

        engine.copyFile(item: item, from: source, to: destination, destinationPath: "/pause.bin")
        try await waitUntil { gate.isWaiting }

        let running = try XCTUnwrap(engine.records.first)
        XCTAssertTrue(running.supportsResuming)
        engine.pause(running)

        let paused = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertNil(paused.bytesPerSecond)
        let restored = TransferEngine(fileURL: fileURL)
        XCTAssertEqual(restored.records.first?.state, .paused)
        XCTAssertTrue(restored.records.first?.supportsResuming == true)
        let connections = ConnectionStore()
        restored.resumePending(using: connections)
        XCTAssertEqual(restored.records.first?.state, .paused)

        gate.release()
        try await waitUntil { destination.didDisconnect }
        XCTAssertEqual(destination.writtenBytes, 4 * 1024 * 1024)
        XCTAssertEqual(engine.records.first?.state, .paused)
        XCTAssertEqual(engine.records.first?.transferredBytes, UInt64(4 * 1024 * 1024))
        let checkpointed = TransferEngine(fileURL: fileURL)
        XCTAssertEqual(checkpointed.records.first?.state, .paused)
        XCTAssertEqual(checkpointed.records.first?.transferredBytes, UInt64(4 * 1024 * 1024))

        engine.resume(paused, using: connections)
        try await waitUntil {
            engine.records.first?.errorMessage == "The source or destination connection no longer exists."
        }
        XCTAssertEqual(engine.records.first?.state, .failed)
    }

    func testResumeBeforePauseBoundaryKeepsCurrentExecution() async throws {
        let gate = TransferDownloadGate()
        let totalBytes = 1024
        let item = RemoteItem(
            name: "continue.bin",
            path: "/continue.bin",
            kind: .file,
            size: Int64(totalBytes),
            revision: RemoteRevision(
                eTag: nil,
                modifiedAt: Date(timeIntervalSince1970: 1),
                size: Int64(totalBytes),
                opaqueIdentifier: nil
            )
        )
        let source = PausableChunkSourceProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            item: item,
            gate: gate
        )
        let destination = PausableChunkDestinationProvider(
            profile: ConnectionProfile.empty(for: .sftp)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesImmediateResumeTests-\(UUID())", isDirectory: true)
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { gate.release() }

        engine.copyFile(item: item, from: source, to: destination, destinationPath: "/continue.bin")
        try await waitUntil { gate.isWaiting }
        let running = try XCTUnwrap(engine.records.first)
        engine.pause(running)
        let paused = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(paused.state, .paused)

        engine.resume(paused, using: ConnectionStore())
        XCTAssertEqual(engine.records.first?.state, .running)
        gate.release()
        try await waitUntil { engine.records.first?.state == .completed }
        XCTAssertEqual(destination.writtenBytes, totalBytes)
    }

    func testLocalUploadPausesAtChunkBoundaryAndContinuesInPlace() async throws {
        let gate = TransferDownloadGate()
        let data = Data(repeating: 0x6A, count: 5 * 1024 * 1024)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesLocalUploadPauseTests-\(UUID())", isDirectory: true)
        let localURL = directory.appendingPathComponent("upload.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: localURL)
        let provider = PausableLocalUploadProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            gate: gate
        )
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        let upload = Task {
            try await engine.uploadFile(localURL: localURL, to: provider, destinationPath: "/upload.bin")
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        defer {
            gate.release()
            if let record = engine.records.first {
                if record.state == .paused {
                    engine.remove(record)
                } else if record.state == .running || record.state == .queued {
                    engine.cancel(record)
                }
            }
            upload.cancel()
        }

        try await waitUntil { gate.isWaiting }
        let running = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(running.operationKind, .upload)
        XCTAssertTrue(running.supportsResuming)
        engine.pause(running)
        XCTAssertEqual(engine.records.first?.state, .paused)

        gate.release()
        try await waitUntil {
            engine.records.first?.transferredBytes == UInt64(4 * 1024 * 1024)
        }
        let paused = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(paused.state, .paused)

        engine.resume(paused, using: ConnectionStore())
        try await upload.value
        XCTAssertEqual(engine.records.first?.state, .completed)
        XCTAssertEqual(provider.data, data)
    }

    func testCancellingCallerWhileLocalTransferIsPausedCancelsEngineTask() async throws {
        let gate = TransferDownloadGate()
        let data = Data(repeating: 0x31, count: 5 * 1024 * 1024)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesLocalUploadCancellationTests-\(UUID())", isDirectory: true)
        let localURL = directory.appendingPathComponent("upload.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: localURL)
        let provider = PausableLocalUploadProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            gate: gate
        )
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        let upload = Task {
            try await engine.uploadFile(localURL: localURL, to: provider, destinationPath: "/upload.bin")
        }
        defer {
            gate.release()
            if let record = engine.records.first, record.state == .paused {
                engine.remove(record)
            }
            upload.cancel()
            try? FileManager.default.removeItem(at: directory)
        }

        try await waitUntil { gate.isWaiting }
        let running = try XCTUnwrap(engine.records.first)
        engine.pause(running)
        gate.release()
        try await waitUntil {
            engine.records.first?.state == .paused
                && engine.records.first?.transferredBytes == UInt64(4 * 1024 * 1024)
        }

        upload.cancel()
        do {
            try await upload.value
            XCTFail("Cancelling the caller should cancel the local transfer")
        } catch is CancellationError {
            // Expected: cancellation propagates through uploadFile after the
            // engine-owned operation has closed its session.
        }
        XCTAssertEqual(engine.records.first?.state, .cancelled)
    }

    func testLocalDownloadPausesAtChunkBoundaryAndContinuesInPlace() async throws {
        let gate = TransferDownloadGate()
        let totalBytes = 5 * 1024 * 1024
        let item = RemoteItem(
            name: "download.bin",
            path: "/download.bin",
            kind: .file,
            size: Int64(totalBytes),
            revision: RemoteRevision(
                eTag: nil,
                modifiedAt: Date(timeIntervalSince1970: 1),
                size: Int64(totalBytes),
                opaqueIdentifier: nil
            )
        )
        let source = PausableChunkSourceProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            item: item,
            gate: gate
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesLocalDownloadPauseTests-\(UUID())", isDirectory: true)
        let localURL = directory.appendingPathComponent("download.bin")
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        let download = Task {
            try await engine.downloadFile(item: item, from: source, to: localURL)
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        defer {
            gate.release()
            if let record = engine.records.first {
                if record.state == .paused {
                    engine.remove(record)
                } else if record.state == .running || record.state == .queued {
                    engine.cancel(record)
                }
            }
            download.cancel()
        }

        try await waitUntil { gate.isWaiting }
        let running = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(running.operationKind, .download)
        XCTAssertTrue(running.supportsResuming)
        engine.pause(running)
        gate.release()
        try await waitUntil {
            engine.records.first?.transferredBytes == UInt64(4 * 1024 * 1024)
        }
        let paused = try XCTUnwrap(engine.records.first)
        XCTAssertEqual(paused.state, .paused)

        engine.resume(paused, using: ConnectionStore())
        try await download.value
        XCTAssertEqual(engine.records.first?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: localURL), Data(repeating: 0x42, count: totalBytes))
    }

    func testRejectedChunkProbeClearsStalePauseWithoutLeavingUnresumableRecordPaused() async throws {
        let gate = TransferDownloadGate()
        let data = Data(repeating: 0x27, count: 1024)
        let item = RemoteItem(
            name: "probe.bin",
            path: "/probe.bin",
            kind: .file,
            size: Int64(data.count),
            revision: RemoteRevision(
                eTag: nil,
                modifiedAt: Date(timeIntervalSince1970: 1),
                size: Int64(data.count),
                opaqueIdentifier: nil
            )
        )
        let source = ProbeRejectingDownloadProvider(
            profile: ConnectionProfile.empty(for: .sftp),
            item: item,
            data: data,
            gate: gate
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesProbeFallbackTests-\(UUID())", isDirectory: true)
        let localURL = directory.appendingPathComponent("probe.bin")
        let engine = TransferEngine(fileURL: directory.appendingPathComponent("transfers.json"))
        let download = Task {
            try await engine.downloadFile(item: item, from: source, to: localURL)
        }
        defer {
            gate.release()
            download.cancel()
            try? FileManager.default.removeItem(at: directory)
        }

        try await waitUntil { gate.isWaiting }
        let waiting = try XCTUnwrap(engine.records.first)
        XCTAssertTrue(waiting.supportsResuming)
        engine.pause(waiting)
        XCTAssertEqual(engine.records.first?.state, .paused)

        gate.release()
        try await download.value
        XCTAssertEqual(engine.records.first?.state, .completed)
        XCTAssertFalse(engine.records.first?.supportsResuming == true)
        XCTAssertEqual(try Data(contentsOf: localURL), data)
    }

    func testInterruptedPausedLocalTransferDoesNotAdvertiseResumeAfterReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilesInterruptedLocalPauseTests-\(UUID())", isDirectory: true)
        let fileURL = directory.appendingPathComponent("transfers.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var record = TransferRecord(
            fileName: "upload.bin",
            sourceProfileID: UUID(),
            sourcePath: "/tmp/upload.bin",
            destinationProfileID: UUID(),
            destinationPath: "/upload.bin",
            overwrite: false,
            source: "On Device:upload.bin",
            destination: "Server:/upload.bin",
            totalBytes: 1024,
            kind: .upload,
            isResumable: true
        )
        record.state = .paused
        try JSONEncoder().encode([record]).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: directory) }

        let restored = TransferEngine(fileURL: fileURL)

        XCTAssertEqual(restored.records.first?.state, .failed)
        XCTAssertFalse(restored.records.first?.supportsResuming == true)
        XCTAssertEqual(
            restored.records.first?.errorMessage,
            "This local transfer was interrupted and cannot be resumed automatically."
        )
    }

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
        // Provider/session setup and the first 4 MiB checkpoint can take more
        // than a second on a simulator or a loaded CI worker. Keep polling
        // responsive while allowing enough time for the cooperative pause path.
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for transfer state after 10 seconds")
    }
}

private func withTestLock<T>(_ lock: NSLock, _ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
}

private final class StaticDownloadProvider: RemoteFileProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities.basicReadWrite
    private let data: Data

    init(profile: ConnectionProfile, data: Data) {
        self.profile = profile
        self.data = data
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func download(path: String, to localURL: URL) async throws {
        try data.write(to: localURL)
    }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }
}

private final class ChunkedDownloadProvider: RemoteFileProvider, RemoteChunkReadableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities.basicReadWrite
    private let data: Data
    private let lock = NSLock()
    private var requestedLengths: [Int] = []

    init(profile: ConnectionProfile, data: Data) {
        self.profile = profile
        self.data = data
    }

    var maximumRequestedLength: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestedLengths.max() ?? 0
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func download(path: String, to localURL: URL) async throws {
        try data.write(to: localURL)
    }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }

    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data {
        recordRequestedLength(length)
        let start = Int(offset)
        guard start < data.count else { return Data() }
        let returnedLength = min(length, 256 * 1024)
        return data.subdata(in: start..<min(data.count, start + returnedLength))
    }

    private func recordRequestedLength(_ length: Int) {
        lock.lock()
        requestedLengths.append(length)
        lock.unlock()
    }
}

private final class ChunkedUploadProvider: RemoteFileProvider, RemoteChunkWritableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write])
    private(set) var data = Data()
    private(set) var maximumChunkLength = 0

    init(profile: ConnectionProfile) {
        self.profile = profile
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }

    func prepareChunkedUpload(path: String, overwrite: Bool, resumeOffset: UInt64) async throws -> UInt64 {
        data = Data()
        maximumChunkLength = 0
        return 0
    }

    func writeChunk(path: String, data chunk: Data, offset: UInt64) async throws {
        maximumChunkLength = max(maximumChunkLength, chunk.count)
        let start = Int(offset)
        if self.data.count < start + chunk.count {
            self.data.append(Data(repeating: 0, count: start + chunk.count - self.data.count))
        }
        self.data.replaceSubrange(start..<(start + chunk.count), with: chunk)
    }
}

private final class ResumeCheckpointSourceProvider: RemoteFileProvider, RemoteChunkReadableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read])
    private let item: RemoteItem
    private let data: Data
    private let lock = NSLock()
    private var readOffsetsStorage: [UInt64] = []

    init(profile: ConnectionProfile, item: RemoteItem) {
        self.profile = profile
        self.item = item
        data = Data(repeating: 0x7F, count: Int(item.size ?? 0))
    }

    var readOffsets: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return readOffsetsStorage
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func attributes(path: String) async throws -> RemoteItem { item }
    func download(path: String, to localURL: URL) async throws {
        try data.write(to: localURL)
    }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }

    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data {
        recordReadOffset(offset)
        let start = Int(offset)
        guard start < data.count else { return Data() }
        return data.subdata(in: start..<min(data.count, start + length))
    }

    private func recordReadOffset(_ offset: UInt64) {
        lock.lock()
        readOffsetsStorage.append(offset)
        lock.unlock()
    }
}

private final class ResumeCheckpointDestinationProvider: RemoteFileProvider, RemoteChunkWritableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .move])
    private let totalBytes: Int
    private let unconfirmedPartialBytes: Int
    private let lock = NSLock()
    private var preparedResumeOffsetsStorage: [UInt64] = []
    private var preparedOverwriteFlagsStorage: [Bool] = []

    init(profile: ConnectionProfile, totalBytes: Int, unconfirmedPartialBytes: Int) {
        self.profile = profile
        self.totalBytes = totalBytes
        self.unconfirmedPartialBytes = unconfirmedPartialBytes
    }

    var preparedResumeOffsets: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return preparedResumeOffsetsStorage
    }

    var preparedOverwriteFlags: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return preparedOverwriteFlagsStorage
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }

    func attributes(path: String) async throws -> RemoteItem {
        let size = path.hasSuffix(".partial") ? unconfirmedPartialBytes : totalBytes
        return RemoteItem(name: "resume.bin", path: path, kind: .file, size: Int64(size))
    }

    func prepareChunkedUpload(path: String, overwrite: Bool, resumeOffset: UInt64) async throws -> UInt64 {
        recordPrepared(resumeOffset: resumeOffset, overwrite: overwrite)
        return resumeOffset
    }

    private func recordPrepared(resumeOffset: UInt64, overwrite: Bool) {
        lock.lock()
        preparedResumeOffsetsStorage.append(resumeOffset)
        preparedOverwriteFlagsStorage.append(overwrite)
        lock.unlock()
    }

    func writeChunk(path: String, data: Data, offset: UInt64) async throws { }
    func finishChunkedUpload(path: String) async throws { }
    func move(from: String, to: String, overwrite: Bool) async throws { }
}

private enum FinalVerificationStat: Sendable {
    case error(String)
    case missingSize
    case size(Int64)
}

private final class FinalVerificationDestinationProvider: RemoteFileProvider, RemoteChunkWritableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .move, .randomWrite])
    private let destinationPath: String
    private let finalStat: FinalVerificationStat
    private let lock = NSLock()
    private var dataStorage = Data()
    private var movedStorage = false

    init(
        profile: ConnectionProfile,
        destinationPath: String,
        finalStat: FinalVerificationStat
    ) {
        self.profile = profile
        self.destinationPath = destinationPath
        self.finalStat = finalStat
    }

    var writtenBytes: Int {
        withTestLock(lock) { dataStorage.count }
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws {
        let data = try Data(contentsOf: localURL)
        withTestLock(lock) {
            dataStorage = data
            movedStorage = true
        }
    }

    func attributes(path: String) async throws -> RemoteItem {
        if path.hasSuffix(".partial") {
            let partialSize = withTestLock(lock) { dataStorage.count }
            return RemoteItem(
                name: ".partial",
                path: path,
                kind: .file,
                size: Int64(partialSize)
            )
        }

        let moved = withTestLock(lock) { movedStorage }
        guard path == destinationPath, moved else {
            throw RemoteProviderError.invalidResponse("The destination item was not found.")
        }
        switch finalStat {
        case .error(let message):
            throw RemoteProviderError.invalidResponse(message)
        case .missingSize:
            return RemoteItem(name: "verified", path: path, kind: .file, size: nil)
        case .size(let size):
            return RemoteItem(name: "verified", path: path, kind: .file, size: size)
        }
    }

    func prepareChunkedUpload(path: String, overwrite: Bool, resumeOffset: UInt64) async throws -> UInt64 {
        withTestLock(lock) {
            dataStorage = Data()
            movedStorage = false
        }
        return 0
    }

    func writeChunk(path: String, data: Data, offset: UInt64) async throws {
        withTestLock(lock) {
            let start = Int(offset)
            if dataStorage.count < start + data.count {
                dataStorage.append(Data(repeating: 0, count: start + data.count - dataStorage.count))
            }
            dataStorage.replaceSubrange(start..<(start + data.count), with: data)
        }
    }

    func finishChunkedUpload(path: String) async throws { }

    func move(from: String, to: String, overwrite: Bool) async throws {
        guard to == destinationPath else {
            throw RemoteProviderError.invalidResponse("The destination move path was unexpected.")
        }
        withTestLock(lock) { movedStorage = true }
    }
}

private final class BlockingMoveDestinationProvider: RemoteFileProvider, RemoteChunkWritableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .move, .randomWrite])
    private let totalBytes: Int
    private let moveGate: TransferDownloadGate
    private let lock = NSLock()
    private var dataStorage = Data()
    private var movedStorage = false

    init(profile: ConnectionProfile, totalBytes: Int, moveGate: TransferDownloadGate) {
        self.profile = profile
        self.totalBytes = totalBytes
        self.moveGate = moveGate
    }

    var writtenBytes: Int {
        withTestLock(lock) { dataStorage.count }
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }

    func attributes(path: String) async throws -> RemoteItem {
        let state = withTestLock(lock) { (movedStorage, dataStorage.count) }
        let moved = state.0
        let size = state.1
        if path == "/commit.bin", moved {
            return RemoteItem(name: "commit.bin", path: path, kind: .file, size: Int64(totalBytes))
        }
        if path.hasSuffix(".partial") {
            return RemoteItem(name: ".partial", path: path, kind: .file, size: Int64(size))
        }
        throw RemoteProviderError.invalidResponse("The destination item was not found.")
    }

    func prepareChunkedUpload(path: String, overwrite: Bool, resumeOffset: UInt64) async throws -> UInt64 {
        withTestLock(lock) { dataStorage = Data() }
        return 0
    }

    func writeChunk(path: String, data chunk: Data, offset: UInt64) async throws {
        withTestLock(lock) {
            let start = Int(offset)
            if dataStorage.count < start + chunk.count {
                dataStorage.append(Data(repeating: 0, count: start + chunk.count - dataStorage.count))
            }
            dataStorage.replaceSubrange(start..<(start + chunk.count), with: chunk)
        }
    }

    func finishChunkedUpload(path: String) async throws { }

    func move(from: String, to: String, overwrite: Bool) async throws {
        await moveGate.wait()
        withTestLock(lock) { movedStorage = true }
    }
}

private final class FailingLegacyUploadProvider: RemoteFileProvider, RemoteChunkWritableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .move, .randomWrite])
    private let lock = NSLock()
    private var didAbortStorage = false
    private var removedPathsStorage: [String] = []
    private var writeCount = 0

    init(profile: ConnectionProfile) {
        self.profile = profile
    }

    var didAbortChunkedUpload: Bool {
        withTestLock(lock) { didAbortStorage }
    }

    var removedPaths: [String] {
        withTestLock(lock) { removedPathsStorage }
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }

    func prepareChunkedUpload(path: String, overwrite: Bool, resumeOffset: UInt64) async throws -> UInt64 {
        writeCount = 0
        return 0
    }

    func writeChunk(path: String, data: Data, offset: UInt64) async throws {
        writeCount += 1
        if writeCount > 1 {
            throw RemoteProviderError.invalidResponse("Injected legacy writer failure.")
        }
    }

    func finishChunkedUpload(path: String) async throws { }

    func abortChunkedUpload(path: String) async {
        withTestLock(lock) { didAbortStorage = true }
    }

    func remove(path: String, isDirectory: Bool) async throws {
        withTestLock(lock) { removedPathsStorage.append(path) }
    }
}

private final class BlockingNativeUploadProvider: RemoteFileProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write])
    private let gate: TransferDownloadGate
    private let lock = NSLock()
    private var didUploadStorage = false
    private var uploadedPathStorage: String?

    init(profile: ConnectionProfile, gate: TransferDownloadGate) {
        self.profile = profile
        self.gate = gate
    }

    var didUpload: Bool {
        withTestLock(lock) { didUploadStorage }
    }

    var uploadedPath: String? {
        withTestLock(lock) { uploadedPathStorage }
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws {
        await gate.wait()
        withTestLock(lock) {
            didUploadStorage = true
            uploadedPathStorage = path
        }
    }
}

private final class StagedNativeUploadProvider: RemoteFileProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .move])
    private let gate: TransferDownloadGate?
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var uploadedPathsStorage: [String] = []
    private var movedPathsStorage: [[String]] = []
    private var removedPathsStorage: [String] = []

    init(profile: ConnectionProfile, gate: TransferDownloadGate? = nil) {
        self.profile = profile
        self.gate = gate
    }

    var isWaiting: Bool {
        gate?.isWaiting == true
    }

    var uploadedPaths: [String] {
        withTestLock(lock) { uploadedPathsStorage }
    }

    var movedPaths: [[String]] {
        withTestLock(lock) { movedPathsStorage }
    }

    var removedPaths: [String] {
        withTestLock(lock) { removedPathsStorage }
    }

    func data(at path: String) -> Data? {
        withTestLock(lock) { storage[path] }
    }

    func connect() async throws { }

    func list(path: String) async throws -> [RemoteItem] {
        withTestLock(lock) {
            storage.compactMap { itemPath, data in
                guard RemotePath.parent(itemPath) == RemotePath.normalize(path) else { return nil }
                return RemoteItem(
                    name: (itemPath as NSString).lastPathComponent,
                    path: itemPath,
                    kind: .file,
                    size: Int64(data.count)
                )
            }
        }
    }

    func download(path: String, to localURL: URL) async throws { }

    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws {
        await gate?.wait()
        let data = try Data(contentsOf: localURL)
        withTestLock(lock) {
            uploadedPathsStorage.append(path)
            storage[path] = data
        }
    }

    func move(from: String, to: String, overwrite: Bool) async throws {
        let data = withTestLock(lock) { storage[from] }
        guard let data else {
            throw RemoteProviderError.notFound("The staged upload was not found.")
        }
        if !overwrite, withTestLock(lock, { storage[to] != nil }) {
            throw RemoteProviderError.conflict("An item already exists at \(to).")
        }
        withTestLock(lock) {
            storage.removeValue(forKey: from)
            storage[to] = data
            movedPathsStorage.append([from, to])
        }
    }

    func remove(path: String, isDirectory: Bool) async throws {
        withTestLock(lock) {
            storage.removeValue(forKey: path)
            removedPathsStorage.append(path)
        }
    }
}

private final class PausableChunkSourceProvider: RemoteFileProvider, RemoteChunkReadableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .randomRead])
    private let item: RemoteItem
    private let data: Data
    private let gate: TransferDownloadGate

    init(profile: ConnectionProfile, item: RemoteItem, gate: TransferDownloadGate) {
        self.profile = profile
        self.item = item
        self.data = Data(repeating: 0x42, count: Int(item.size ?? 0))
        self.gate = gate
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func attributes(path: String) async throws -> RemoteItem { item }
    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }

    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data {
        await gate.wait()
        try Task.checkCancellation()
        let start = Int(offset)
        guard start < data.count else { return Data() }
        return data.subdata(in: start..<min(data.count, start + length))
    }
}

private final class ProbeRejectingDownloadProvider: RemoteFileProvider, RemoteChunkReadableProvider, RemoteChunkReadSupportProbing, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .randomRead])
    private let item: RemoteItem
    private let data: Data
    private let gate: TransferDownloadGate

    init(profile: ConnectionProfile, item: RemoteItem, data: Data, gate: TransferDownloadGate) {
        self.profile = profile
        self.item = item
        self.data = data
        self.gate = gate
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func attributes(path: String) async throws -> RemoteItem { item }
    func download(path: String, to localURL: URL) async throws {
        try data.write(to: localURL)
    }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }
    func readChunk(path: String, offset: UInt64, length: Int) async throws -> Data { Data() }

    func supportsChunkedReads(path: String) async throws -> Bool {
        await gate.wait()
        return false
    }
}

private final class PausableChunkDestinationProvider: RemoteFileProvider, RemoteChunkWritableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .move, .randomWrite])
    private let lock = NSLock()
    private var writtenBytesStorage = 0
    private var didDisconnectStorage = false

    init(profile: ConnectionProfile) {
        self.profile = profile
    }

    func connect() async throws { }
    func disconnect() async { recordDisconnect() }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }
    func prepareChunkedUpload(path: String, overwrite: Bool, resumeOffset: UInt64) async throws -> UInt64 { resumeOffset }
    func writeChunk(path: String, data: Data, offset: UInt64) async throws {
        recordWrite(data.count)
    }
    func move(from: String, to: String, overwrite: Bool) async throws { }

    var writtenBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return writtenBytesStorage
    }

    var didDisconnect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didDisconnectStorage
    }

    private func recordWrite(_ count: Int) {
        lock.lock()
        writtenBytesStorage += count
        lock.unlock()
    }

    private func recordDisconnect() {
        lock.lock()
        didDisconnectStorage = true
        lock.unlock()
    }
}

private final class PausableLocalUploadProvider: RemoteFileProvider, RemoteChunkWritableProvider, @unchecked Sendable {
    let profile: ConnectionProfile
    let capabilities = ProviderCapabilities([.list, .read, .write, .randomWrite])
    private let gate: TransferDownloadGate
    private let lock = NSLock()
    private var dataStorage = Data()

    init(profile: ConnectionProfile, gate: TransferDownloadGate) {
        self.profile = profile
        self.gate = gate
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return dataStorage
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }

    func prepareChunkedUpload(path: String, overwrite: Bool, resumeOffset: UInt64) async throws -> UInt64 {
        resetData()
        return 0
    }

    func writeChunk(path: String, data: Data, offset: UInt64) async throws {
        await gate.wait()
        write(data, at: offset)
    }

    private func resetData() {
        lock.lock()
        dataStorage = Data()
        lock.unlock()
    }

    private func write(_ chunk: Data, at offset: UInt64) {
        lock.lock()
        let start = Int(offset)
        if dataStorage.count < start + chunk.count {
            dataStorage.append(Data(repeating: 0, count: start + chunk.count - dataStorage.count))
        }
        dataStorage.replaceSubrange(start..<(start + chunk.count), with: chunk)
        lock.unlock()
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
            let shouldResume = withTestLock(lock) {
                if releasedStorage {
                    return true
                }
                waitingStorage = true
                continuationStorage = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
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
    let capabilities = ProviderCapabilities([.list, .read, .write])

    init(profile: ConnectionProfile) {
        self.profile = profile
    }

    func connect() async throws { }
    func list(path: String) async throws -> [RemoteItem] { [] }
    func download(path: String, to localURL: URL) async throws { }
    func upload(from localURL: URL, to path: String, overwrite: Bool) async throws { }
    func createDirectory(path: String) async throws { }
}
