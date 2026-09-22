import Foundation

enum TransferState: String, Codable, Sendable {
    case queued, running, paused, completed, failed, cancelled
}

enum TransferKind: String, Codable, Sendable {
    case serverToServer
    case upload
    case download
}

enum TransferResumeDecision: Equatable, Sendable {
    case resume(UInt64)
    case restart

    var offset: UInt64 {
        switch self {
        case .resume(let offset): offset
        case .restart: 0
        }
    }
}

enum TransferResumePolicy {
    private static func strongETag(from revision: RemoteRevision) -> String? {
        guard let raw = revision.eTag?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !raw.uppercased().hasPrefix("W/") else {
            return nil
        }
        return raw
    }

    static func decision(
        transferredBytes: UInt64?,
        persistedRevision: RemoteRevision?,
        currentRevision: RemoteRevision
    ) -> TransferResumeDecision {
        guard let persistedRevision else {
            return .restart
        }

        let persistedETag = strongETag(from: persistedRevision)
        let currentETag = strongETag(from: currentRevision)

        if persistedETag != nil || currentETag != nil {
            guard let persistedETag,
                  let currentETag,
                  persistedETag == currentETag else {
                return .restart
            }
            return .resume(transferredBytes ?? 0)
        }

        guard let persistedModifiedAt = persistedRevision.modifiedAt,
              let currentModifiedAt = currentRevision.modifiedAt,
              let persistedSize = persistedRevision.size,
              let currentSize = currentRevision.size,
              persistedModifiedAt == currentModifiedAt,
              persistedSize == currentSize else {
            return .restart
        }

        return .resume(transferredBytes ?? 0)
    }
}

enum TransferCommitDecision: Equatable, Sendable {
    case completed
    case resume
    case uncertain
}

enum TransferCommitPolicy {
    static func decision(
        finalItem: RemoteItem?,
        partialItem: RemoteItem?,
        expectedBytes: UInt64,
        destinationExistedBeforeCommit: Bool?
    ) -> TransferCommitDecision {
        guard let finalItem,
              !finalItem.isDirectory,
              let finalSize = finalItem.size,
              finalSize == Int64(clamping: expectedBytes),
              partialItem == nil else {
            return .resume
        }
        return destinationExistedBeforeCommit == false ? .completed : .uncertain
    }
}

struct TransferRecord: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let fileName: String
    let sourceProfileID: UUID
    let sourcePath: String
    let destinationProfileID: UUID
    let destinationPath: String
    let overwrite: Bool
    let source: String
    let destination: String
    var state: TransferState
    var progress: Double
    var transferredBytes: UInt64?
    var totalBytes: Int64?
    var errorMessage: String?
    var sourceRevision: RemoteRevision?
    var kind: TransferKind?
    var bytesPerSecond: Double?
    var startedAt: Date?
    var isResumable: Bool?
    /// True after a complete payload has been written to the private partial
    /// path and before the final rename is durably reflected in the record.
    /// This lets a new engine reconcile a crash in that small commit window.
    var commitPending: Bool?
    /// Best-effort preflight fact used to avoid treating an unrelated existing
    /// destination of the same size as a completed transfer after a crash.
    var commitDestinationExisted: Bool?
    /// App-owned copy of a failed upload's local file. Present only while the
    /// upload can still be retried from the transfer list.
    var retainedLocalPath: String?

    var operationKind: TransferKind { kind ?? .serverToServer }
    var supportsResuming: Bool { isResumable ?? false }

    init(
        fileName: String,
        sourceProfileID: UUID,
        sourcePath: String,
        destinationProfileID: UUID,
        destinationPath: String,
        overwrite: Bool,
        source: String,
        destination: String,
        totalBytes: Int64? = nil,
        sourceRevision: RemoteRevision? = nil,
        kind: TransferKind = .serverToServer,
        isResumable: Bool = false,
        commitPending: Bool = false,
        commitDestinationExisted: Bool? = nil
    ) {
        id = UUID()
        self.fileName = fileName
        self.sourceProfileID = sourceProfileID
        self.sourcePath = sourcePath
        self.destinationProfileID = destinationProfileID
        self.destinationPath = destinationPath
        self.overwrite = overwrite
        self.source = source
        self.destination = destination
        state = .queued
        progress = 0
        transferredBytes = 0
        self.totalBytes = totalBytes
        self.sourceRevision = sourceRevision
        self.kind = kind
        bytesPerSecond = nil
        startedAt = nil
        self.isResumable = isResumable
        self.commitPending = commitPending
        self.commitDestinationExisted = commitDestinationExisted
    }
}
